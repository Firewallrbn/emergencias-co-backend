# Manual de despliegue

Cómo levantar el sistema completo desde cero, en una cuenta de AWS y un proyecto de
Supabase nuevos. Cada paso indica cómo comprobar que funcionó, porque un despliegue que no
se verifica no está hecho.

Si solo quieres **verlo funcionando sin desplegar nada**, salta a
[demostración local](#demostración-local-sin-aws-ni-supabase): un `docker compose up` y
listo.

---

## 0. Herramientas

| Herramienta | Versión probada | Para qué |
|---|---|---|
| Node.js | 22+ | Empaquetar los servicios |
| Docker | 29+ | Demostración local |
| AWS CLI | v2.36+ | Credenciales y consultas |
| AWS SAM CLI | 1.165+ | Desplegar los stacks |
| gitleaks | 8.30+ | Guarda anti-secretos |
| psql | 17+ | Asignar contraseñas de los roles |
| Supabase CLI | 2.114+ | Opcional, para migraciones desde consola |

```bash
git clone https://github.com/Firewallrbn/emergencias-co-backend
cd emergencias-co-backend
npm ci
git config core.hooksPath .githooks   # activa el hook anti-secretos
```

> En Windows, `sam` y `psql` se añaden al PATH al instalarse, pero una terminal abierta
> desde antes no los ve. Los scripts del repositorio recurren a la ruta de instalación
> conocida si no los encuentran.

---

## 1. Credenciales de AWS

```bash
aws login              # credenciales temporales desde el navegador, sin access keys
aws configure set region us-east-2
aws sts get-caller-identity
```

`aws login` entrega credenciales que **caducan en unas horas**. Cuando un comando falle
con `Your session has expired`, se vuelve a ejecutar. Se prefiere a crear un usuario IAM
con access keys porque no deja ninguna credencial de larga vida en el disco.

---

## 2. Presupuesto, antes que nada

Se despliega primero, no al final. Cuesta un minuto y protege el resto del trabajo.

```bash
aws cloudformation deploy \
  --template-file infra/budgets.yaml \
  --stack-name emergencias-budgets \
  --parameter-overrides EmailAlertas=tu@correo.com LimiteMensualUsd=10 \
  --region us-east-2
```

**Comprobar:**

```bash
aws budgets describe-notifications-for-budget \
  --account-id "$(aws sts get-caller-identity --query Account --output text)" \
  --budget-name emergencias-presupuesto-mensual --output table
```

Deben aparecer dos: `ACTUAL > 50 %` y `FORECASTED > 85 %`.

---

## 3. Configuración de cuenta de API Gateway

API Gateway escribe sus logs con un rol definido **a nivel de cuenta**. Sin él, crear un
stage con `LoggingLevel` falla con *"CloudWatch Logs role ARN must be set in account
settings"*.

```bash
aws cloudformation deploy \
  --template-file infra/bootstrap-cuenta.yaml \
  --stack-name emergencias-bootstrap \
  --capabilities CAPABILITY_IAM --region us-east-2

aws apigateway get-account --region us-east-2 --query cloudwatchRoleArn
```

Va en un stack aparte a propósito: es un ajuste global, y borrar el stack de la aplicación
dejaría la cuenta sin capacidad de registrar logs.

---

## 4. Base de datos

Crear un proyecto en Supabase y aplicar todo lo que hay en `db/migrations/`, en orden.

**Antes de tocar Supabase**, validarlas contra un PostGIS limpio:

```powershell
.\scripts\validar-migraciones.ps1
```

Levanta un contenedor, replica el layout de Supabase y comprueba cobertura del dominio,
RLS forzada, ausencia de `BYPASSRLS`, proximidad y clustering. Detectó tres errores reales
antes de que llegaran al proyecto.

Ya validadas, se aplican:

```powershell
.\scripts\aplicar-migraciones-supabase.ps1 -ConSeed        # la primera vez
.\scripts\aplicar-migraciones-supabase.ps1                 # tras anadir una migracion
.\scripts\aplicar-migraciones-supabase.ps1 -SoloVerificar  # solo comprobar
```

Recorre `db/migrations/*.sql` en orden y las aplica todas por el pooler en modo **sesión**
(puerto 5432; el de transacción no admite todas las sentencias de una migración). Son
idempotentes por diseño, así que se corre entero cada vez y las ya aplicadas no cambian
nada. `-ConSeed` añade `db/seed/*.sql`, que se pide explícitamente para no sembrar datos de
demostración por accidente sobre datos reales.

`db/local-test/` no se aplica nunca en Supabase: son stubs que replican en un Postgres
pelado lo que Supabase ya provisiona por su cuenta.

Correrlo entero cada vez es lo que evita el fallo silencioso de siempre: alguien añade una
migración, se olvida de aplicarla, y el síntoma aparece mucho después en el frontend como
una columna que no existe.

**Comprobar** — el script termina verificando por su cuenta los schemas del dominio, la
vista pública, las columnas de la última migración, los cuatro roles de servicio, la
ausencia de `BYPASSRLS` y las **16 combinaciones** tipo × ciudad que exige la rúbrica. A
mano sería:

```sql
select count(distinct (tipo, ciudad)) from intake.emergencias;  -- 16
select count(*) from pg_policies where schemaname in ('intake','dispatch','geo','notify');
```

---

## 5. Contraseñas de los roles de servicio

Las migraciones crean los roles `svc_*` **sin contraseña y sin login**. Es deliberado: una
contraseña en una migración acabaría en el repositorio.

```powershell
.\scripts\configurar-credenciales.ps1
```

Genera cuatro contraseñas con el RNG criptográfico del sistema, las asigna, comprueba que
cada rol conecta **por el pooler en modo transacción** —el mismo camino que usará la
Lambda— y publica las cadenas en Parameter Store cifradas.

**Comprobar** (metadatos, sin descifrar):

```bash
aws ssm describe-parameters \
  --parameter-filters "Key=Name,Option=BeginsWith,Values=/emergencias/prod" \
  --query "Parameters[].{Nombre:Name,Tipo:Type}" --output table --region us-east-2
```

Los cuatro deben aparecer como `SecureString`.

---

## 6. Microservicios

**El orden importa:** `dispatch` primero, porque es dueño de la cola que `intake` importa.

```powershell
.\scripts\desplegar-servicio.ps1 dispatch
.\scripts\desplegar-servicio.ps1 intake
.\scripts\desplegar-servicio.ps1 geo
.\scripts\desplegar-servicio.ps1 notify
```

Cada uno construye su bundle con esbuild (~700 KB, sin `node_modules`) y despliega su
stack. En actualizaciones posteriores, CodeDeploy ejecuta el canary y el comando tarda
unos seis minutos.

**Comprobar:**

```bash
aws lambda invoke --function-name 'emergencias-intake:prod' \
  --payload '{"httpMethod":"GET","resource":"/v1/health"}' --cli-binary-format raw-in-base64-out \
  --region us-east-2 /dev/stdout
```

Debe responder `"estado":"ok"` con la base alcanzable.

---

## 7. API Gateway

Se despliega después de los servicios: importa el ARN del alias de cada uno.

```bash
cd infra
sam deploy --template-file gateway.yaml --stack-name emergencias-gateway \
  --capabilities CAPABILITY_IAM --resolve-s3 --no-confirm-changeset --region us-east-2
```

**Comprobar el endpoint y que la validación rechaza en el borde:**

```bash
API=$(aws cloudformation describe-stacks --stack-name emergencias-gateway --region us-east-2 \
  --query "Stacks[0].Outputs[?OutputKey=='UrlBase'].OutputValue" --output text)

curl "$API/v1/health"
curl -i -X POST "$API/v1/emergencias" -H 'Idempotency-Key: prueba-001' \
  -H 'Content-Type: application/json' -d '{"tipo":"inexistente"}'   # espera 400
```

Un 400 con `{"message": "Invalid request body"}` viene del **gateway**, no del handler:
prueba de que el payload inválido no llegó a gastar una invocación.

---

## 8. CI/CD

```bash
aws cloudformation deploy --template-file infra/oidc-github.yaml \
  --stack-name emergencias-oidc --capabilities CAPABILITY_NAMED_IAM --region us-east-2 \
  --parameter-overrides PatronSujeto='repo:PROPIETARIO@ID/REPO@ID:ref:refs/heads/main'

gh secret set AWS_ROLE_ARN --body "$(aws cloudformation describe-stacks \
  --stack-name emergencias-oidc --region us-east-2 \
  --query 'Stacks[0].Outputs[0].OutputValue' --output text)"
```

> **El patrón del sujeto no es el que aparece en la mayoría de guías.** GitHub emite hoy
> identificadores numéricos inmutables pegados al propietario y al repositorio:
> `repo:Usuario@161855153/repositorio@1335528421:ref:refs/heads/main`. Con el formato
> clásico `repo:usuario/repositorio:ref:...` el rol **nunca** se puede asumir, y AWS solo
> responde `Not authorized to perform sts:AssumeRoleWithWebIdentity` sin decir por qué.
>
> Para averiguar el valor real, lanzar el workflow y leer la salida del paso
> **"Mostrar el sujeto del token OIDC"**, que decodifica el token e imprime su `sub`.

**Comprobar:** lanzar un despliegue manual y verificar que termina en verde.

```bash
gh workflow run Desplegar -f servicio=geo
gh run watch "$(gh run list --workflow Desplegar --limit 1 --json databaseId --jq '.[0].databaseId')"
```

---

## 9. Frontend

En el proyecto de Vercel, tres variables (Project Settings → Environment Variables):

| Variable | Valor |
|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | URL del proyecto de Supabase |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | Clave publicable (`sb_publishable_…`) |
| `NEXT_PUBLIC_API_BASE` | Endpoint del API Gateway, stage `prod` |

Las tres son públicas por diseño: viajan en el bundle de cualquier visitante. Lo que
protege los datos no es la clave, es RLS. La `service_role` key **no existe** en este
sistema.

El origen autorizado por CORS debe coincidir en tres sitios: el parámetro
`OrigenPermitido` del gateway, el de cada servicio, y el dominio real de Vercel.

```bash
cd ../emergencias-co-frontend
vercel deploy --prod
```

---

## Verificación completa

```powershell
.\scripts\probar-flujo-completo.ps1
```

Recorre el camino real de una solicitud —ciudadano → gateway → intake → cola → dispatch →
unidad asignada— y comprueba trece cosas, incluida la idempotencia y los rechazos del
validador. Al terminar indica qué datos creó.

Verificación manual de RLS, que es la que no se puede automatizar del todo:

1. Abrir el panel sin sesión → debe pedir iniciar sesión.
2. Entrar como `ciudadano@example.com` → **0** emergencias.
3. Salir y entrar como `operador@example.com` → **19** emergencias.

La misma consulta, distinto resultado, sin una línea de filtrado en el código.

---

## Demostración local

Los contenedores se levantan igual en los dos modos; lo único que cambia es contra qué
base hablan.

### Modo por defecto — contra Supabase

```powershell
.\scripts\preparar-env-local.ps1      # una vez por clon
docker compose up --build
curl http://localhost:8080/v1/health
```

La fuente de la verdad es el mismo Postgres gestionado que usan las Lambdas de producción,
alcanzado por el pooler en modo transacción (6543) y con TLS. Lo que se escriba aquí queda
escrito de verdad y lo que se lea es el estado real del sistema, así que el frontend
desplegado en Vercel y estos contenedores ven exactamente los mismos datos.

`preparar-env-local.ps1` descarga las cuatro cadenas de conexión de Parameter Store y las
escribe en un `.env` que `.gitignore` excluye. Exige AWS CLI autenticada; no hay ninguna
credencial en el repositorio.

### Modo autocontenido — sin AWS ni Supabase

```bash
docker compose -f docker-compose.yml -f docker-compose.local.yml up --build
curl http://localhost:8080/v1/health
```

Añade un PostGIS efímero con migraciones y seed ya aplicados. **No hace falta ninguna
credencial**, así que cualquiera puede clonar el repositorio y levantarlo. A cambio, los
datos son los del seed y mueren con `docker compose down`.

Las imágenes son exactamente las que se desplegarían; no hay variante de desarrollo.

Dos diferencias con producción, ambas visibles en la respuesta:

- No hay SQS, así que las emergencias no se encolan: `"despacho_encolado": false`.
- En el modo autocontenido la contraseña de la base está a la vista en
  `docker-compose.local.yml`. Protege un contenedor efímero sin un dato real dentro.

---

## Deshacer

En orden inverso a las dependencias:

```bash
for s in gateway intake geo notify dispatch oidc budgets bootstrap; do
  aws cloudformation delete-stack --stack-name "emergencias-$s" --region us-east-2
  aws cloudformation wait stack-delete-complete --stack-name "emergencias-$s" --region us-east-2
done
```

`gateway` va primero porque importa los alias de los servicios, y `dispatch` último porque
`intake` importa su cola. CloudFormation se niega a borrar un stack cuyas exportaciones
están en uso, así que un orden equivocado se detecta solo.

---

## Problemas conocidos

| Síntoma | Causa | Solución |
|---|---|---|
| `Your session has expired` | Las credenciales de `aws login` caducan | Volver a ejecutar `aws login` |
| `cannot import name 'Sentinel'` al usar `sam` | El Python de SAM carga el `site-packages` del usuario | `PYTHONNOUSERSITE=1` (los scripts ya lo hacen) |
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | El patrón del sujeto no lleva los identificadores numéricos | Ver el paso 8 |
| `ReservedConcurrentExecutions ... below its minimum value of [10]` | Cuenta nueva, límite de 10 ejecuciones concurrentes | Dejar `ConcurrenciaReservada` en 0 |
| `PGRST106 Invalid schema` | Supabase solo expone `public` | Leer por las vistas de la migración 009 |
| `Failed to fetch` en el panel | Falta CORS en la respuesta real | La cabecera la pone la función, no el gateway |
| Mapa en blanco con marcadores visibles | Falta el CSS de MapLibre o falla el worker de teselas vectoriales | CSS en `globals.css` y teselas ráster |
