# Plan de Ejecución — Parcial 1: Arquitectura Serverless Resiliente para Gestión de Emergencias

## Contexto

El enunciado (`1-Parcial/docs/enunciado-parcial-1.md`) pide un sistema de grado de producción: 4 microservicios Dockerizados en AWS Lambda, API Gateway, Supabase con PostGIS/RLS/Realtime, frontend en Vercel, despliegue Canary con rollback automático, cero secretos en repo y gobernanza de costos — evaluado con una rúbrica de 6 criterios ponderados.

**Punto de partida real (verificado):**

| Hecho | Impacto |
|---|---|
| `1-Parcial/` contiene **solo** el enunciado. No hay código, ni git. | Se construye desde cero. |
| **No existe cuenta AWS configurada**: `~/.aws` no existe, 0 perfiles, `sts get-caller-identity` → `NoCredentials`. | **Bloqueador crítico.** Todo el 55 % de la rúbrica depende de esto. |
| Docker Desktop 4.65 instalado, **daemon detenido**. | Arrancar, sin fricción. |
| Sin SAM, Terraform, CDK, Serverless, Vercel CLI, Supabase CLI. | Instalar en Día 0. |
| Node v23.9, npm 10.9, Python 3.13, git 2.44, `gh` 2.95 **autenticado como `Firewallrbn`** (scopes `repo`, `workflow`). | Listo para GitHub Actions. |
| PostgreSQL 17.5 + **PostGIS 3.5.3** instalados localmente (no en PATH). | Permite probar migraciones/consultas geoespaciales offline. |
| `Patrones/Lambda/traffic_test.js` — script que golpea un API Gateway y cuenta el header `x-handled-by` para medir split 90/10. | **Reutilizar** como verificador del canary. |
| `data-harvest-api/.agents/skills/` tiene `supabase` y `supabase-postgres-best-practices`; `.claude/agents/docker-expert.md`. | **Copiar** al repo nuevo. Cubren el 35 % de la rúbrica (Supabase + Docker). |

**Decisiones tomadas:** Opción A (Canary + CodeDeploy) · GitHub Actions · plazo **1 semana o menos** · **equipo de 2**.

> Nota: elegir GitHub renuncia a los puntos extra que el enunciado da por GitLab. Mitigación barata en el Día 6 si sobra tiempo: `git push` a un mirror en GitLab con un `.gitlab-ci.yml` equivalente (§10.3).

**Próxima acción:** ejecutar el §2 (Día 0). Nada más del plan avanza hasta que `aws sts get-caller-identity` responda.

---

## 1. Decisiones de arquitectura

| Decisión | Elección | Por qué |
|---|---|---|
| IaC | **AWS SAM** | `AutoPublishAlias` + `DeploymentPreference: Canary10Percent5Minutes` + `Alarms` cablean CodeDeploy en ~6 líneas. Es la palanca más alta para el criterio de despliegue (20 %). |
| Lenguaje backend | **Node 22 + TypeScript**, bundle con esbuild | El usuario ya escribe Node/Express. El paso `tsc/esbuild` **justifica el multi-stage build** que exige la rúbrica y produce una imagen sin `node_modules`. |
| Imagen base | `public.ecr.aws/lambda/nodejs:22` | Runtime Interface Client incluido. Alpine + RIC manual es riesgo innecesario en 7 días. |
| API Gateway | **REST API** (no HTTP API) | Único que soporta **request validators + Models JSON Schema** ("validación de esquemas", 15 %) y **Usage Plans** para throttling por token. |
| Acceso Lambda→BD | **`pg` (node-postgres)** con un **rol Postgres por servicio** vía pooler Supavisor | Evita meter `service_role` (que *bypassea* RLS) en las Lambdas. Da least-privilege real a nivel BD. Fallback si el pooler da guerra: `supabase-js` + `service_role`. |
| Acceso Frontend→BD | `supabase-js` con **anon key** | Ejerce RLS de verdad y habilita Realtime. La anon key es pública por diseño y el enunciado autoriza inyectarla desde Vercel. |
| Secretos | **SSM Parameter Store (SecureString)** | Secrets Manager cuesta $0.40/secreto/mes — con presupuesto de $10 y 4 servicios, Parameter Store estándar es gratis. |
| Credenciales CI | **GitHub OIDC → rol IAM** | Cero llaves estáticas en GitHub Secrets. Evidencia directa del criterio "cero variables de entorno". |
| Mapa | **MapLibre GL JS** + tiles OSM/CARTO | Sin API token → nada que filtrar. Mapbox exigiría un secreto en el cliente. |
| Desacople intake→dispatch | **SQS + DLQ** | El enunciado describe "picos masivos de tráfico concurrente" y "solicitudes duplicadas": Queue-Based Load Leveling es la respuesta canónica. |
| Red | Lambdas **fuera de VPC** | Supabase es público. Meterlas en VPC obligaría NAT Gateway (~$32/mes) y reventaría el presupuesto de $10. |

### 1.1 Patrones arquitectónicos a implementar (criterio explícito de la rúbrica)

El curso es *Patrones Arquitectónicos Avanzados*; "patrones aplicados con rigor técnico" es parte del 20 %. Cada patrón debe quedar **nombrado en el código y en el informe**:

| Patrón | Dónde se implementa |
|---|---|
| API Gateway | REST API como único punto de entrada |
| Database per Service (lógico) | Un schema Postgres por microservicio |
| Anti-Corruption Layer | Vistas read-only cross-schema (`dispatch.v_emergencias_pendientes`) |
| Queue-Based Load Leveling | SQS entre Intake y Dispatch |
| Competing Consumers + DLQ | Event source mapping de SQS con `maxReceiveCount: 3` |
| Idempotency Key | Header `Idempotency-Key` + índice único en `intake.emergencias` |
| Circuit Breaker | Cliente HTTP/BD compartido en `packages/shared` |
| Retry con backoff exponencial + jitter | Mismo cliente compartido |
| Bulkhead | `ReservedConcurrentExecutions` distinto por función |
| Cache-Aside | Secretos SSM cacheados a nivel de módulo (una lectura por cold start) |
| Health Endpoint Monitoring | `GET /v1/health` por servicio + alarmas CloudWatch |
| Canary Release | CodeDeploy + alias `prod` |
| Strangler Fig *(opcional)* | Solo si sobra tiempo; no comprometer |

---

## 2. Día 0 — Bloqueadores (hacer HOY, antes de escribir código)

Nada de lo demás avanza sin esto. **Persona A** lo ejecuta completo; **Persona B** hace los pasos 4–5 en paralelo.

1. **Crear cuenta AWS** (o conseguir credenciales de una existente). Activar MFA en root, crear un usuario IAM administrador para el día a día.
2. `aws configure` con región **`us-east-2`** (la que ya usaste en `traffic_test.js`) → verificar con `aws sts get-caller-identity`.
3. **AWS Budgets primero, no al final**: presupuesto de $10 con alertas al 50 % real y 85 % forecast (§11). Se hace en 5 minutos y protege toda la semana.
4. Crear proyecto **Supabase** (región cercana, ej. `us-east-1`) y proyecto **Vercel** vinculado a GitHub.
5. Instalar tooling faltante:
   - AWS SAM CLI (instalador MSI de AWS)
   - `npm i -g vercel supabase`
   - Arrancar Docker Desktop y confirmar `docker info`
   - Añadir `C:\Program Files\PostgreSQL\17\bin` al PATH (para `psql`)
6. Crear los repos con `gh repo create`:
   - `Firewallrbn/emergencias-co-backend` (privado)
   - `Firewallrbn/emergencias-co-frontend` (privado)
7. **Antes del primer commit**: `.gitignore` con `.env*`, y instalar `gitleaks` como pre-commit hook. El enunciado prohíbe secretos *incluso en commits históricos* — un solo descuido cuesta el 15 %.

> Riesgo conocido: `data-harvest-api/api/.env` existe en disco. **No copiar nada de ese repo sin revisar.** Solo se copian `.agents/skills/` y `.claude/agents/docker-expert.md`.

---

## 3. Topología de repositorios

Dos repos. El backend es un monorepo con **4 stacks SAM independientes**, cada uno con su propio workflow disparado por `paths:` — esto satisface "cada microservicio posee su propio ciclo de vida de CI/CD" sin el costo de mantener 4 repos en una semana.

```
emergencias-co-backend/
├─ .github/workflows/
│  ├─ deploy-intake.yml        # on: push paths: services/intake/**
│  ├─ deploy-dispatch.yml
│  ├─ deploy-geo.yml
│  └─ deploy-notify.yml
├─ packages/shared/            # circuit breaker, retry, cliente SSM, logger, pool pg
├─ services/
│  ├─ intake/    { src/, Dockerfile, template.yaml, package.json }
│  ├─ dispatch/  { ... }
│  ├─ geo/       { ... }
│  └─ notify/    { ... }
├─ infra/
│  ├─ gateway.yaml             # REST API + models + validators + usage plan
│  ├─ budgets.yaml             # AWS::Budgets::Budget
│  └─ oidc-role.yaml           # proveedor OIDC + rol de despliegue
├─ db/migrations/              # SQL versionado, idempotente
├─ scripts/traffic_test.js     # adaptado del que ya tienes
└─ docs/                       # C4, manual de despliegue, evidencias

emergencias-co-frontend/       # Next.js 15 App Router → Vercel
```

---

## 4. Modelo de datos (Supabase)

**Un schema por servicio** + `extensions` para PostGIS. Cada servicio recibe un **rol Postgres propio** con grants únicamente sobre su schema y sobre las vistas ACL que necesite leer.

| Schema | Dueño | Tablas principales |
|---|---|---|
| `intake` | `svc_intake` | `emergencias` (tipo P1–P4, ciudad, `geom geography(Point,4326)`, payload JSONB, `idempotency_key` UNIQUE, `triage_score`) |
| `dispatch` | `svc_dispatch` | `unidades` (organismo, ciudad, `geom`, disponible), `despachos` (FK lógica a emergencia, estado, unidad) |
| `geo` | `svc_geo` | `clusters` (ciudad, `centroide geography`, densidad, ventana) |
| `notify` | `svc_notify` | `notificaciones` (destinatario, canal, estado), `webhooks` |

**Puntos que la rúbrica revisa explícitamente:**

- **PostGIS**: `CREATE EXTENSION postgis SCHEMA extensions;` Índices GiST sobre cada columna `geom`. Consultas reales de proximidad con `ST_DWithin` (asignar la unidad disponible más cercana) y clustering con `ST_ClusterDBSCAN`.
- **RLS**: activada en **todas** las tablas. Dos roles de aplicación vía claim JWT `app_role`:
  - *Ciudadano*: `INSERT` en `intake.emergencias`; `SELECT` solo de las propias (`auth.uid() = reportado_por`).
  - *Operador*: `SELECT` de todo en su ciudad; `UPDATE` sobre `dispatch.despachos`.
  - Ninguno de los roles `svc_*` lleva `BYPASSRLS`.
- **Realtime**: `intake.emergencias` y `dispatch.despachos` añadidas a la publicación `supabase_realtime`; exponer los schemas en Dashboard → API → Exposed schemas.
- **Cobertura obligatoria**: seed con datos en **las 4 ciudades × los 4 tipos** (16 combinaciones mínimo) + unidades de Cruz Roja, Bomberos, Defensa Civil y UNGRD.

Migraciones en `db/migrations/NNN_*.sql`, idempotentes y reproducibles vía `supabase db push`.

> Cargar la skill `supabase-postgres-best-practices` antes de escribir el schema (índices, RLS performance, `conn-pooling.md`, `conn-limits.md` — crítico con Lambda).

---

## 5. Los cuatro microservicios

| Servicio | Trigger | Endpoints / responsabilidad |
|---|---|---|
| **intake** | API GW | `POST /v1/emergencias` (valida, calcula triage determinístico P1–P4, deduplica por `Idempotency-Key`, publica en SQS), `GET /v1/emergencias/{id}`, `GET /v1/health` |
| **dispatch** | SQS + API GW | Consume la cola, asigna unidad por `ST_DWithin` + disponibilidad. `PATCH /v1/despachos/{id}`, `GET /v1/despachos?ciudad=` |
| **geo** | API GW | `GET /v1/zonas/{ciudad}/clusters` — `ST_ClusterDBSCAN` para puntos calientes y zonas aisladas |
| **notify** | Postgres/HTTP | `POST /v1/webhooks`, emite notificaciones; el dashboard recibe por Realtime (no polling) |

**Reglas de triage** (determinísticas y documentadas en el informe): tipo base P1–P4, escalado por personas atrapadas, riesgo inminente (gas/fuego), presencia de menores/tercera edad. Determinístico = mismo input, mismo score, testeable.

**Dockerfile — patrón común a los 4** (multi-stage, el criterio vale 20 %):

```dockerfile
FROM public.ecr.aws/lambda/nodejs:22 AS builder
WORKDIR /build
COPY package*.json ./
RUN npm ci
COPY . .
RUN npx esbuild src/index.ts --bundle --platform=node --target=node22 \
    --outfile=dist/index.js --minify

FROM public.ecr.aws/lambda/nodejs:22
COPY --from=builder /build/dist/index.js ${LAMBDA_TASK_ROOT}/
CMD ["index.handler"]
```

La etapa final no lleva `node_modules` ni fuentes. Registrar `docker images` en el informe como evidencia de tamaño.

**Logs estructurados**: JSON con `requestId`, `service`, `ciudad`, `tipo`, `latencyMs`. Retención CloudWatch a **7 días** (control de costo + lo pide el criterio).

---

## 6. API Gateway (`infra/gateway.yaml`)

- **REST API**, stage nombrado literalmente **`prod`**.
- Rutas: `POST /v1/emergencias`, `GET /v1/emergencias/zona/{ciudad}`, `PATCH /v1/despachos/{id}`, `GET /v1/zonas/{ciudad}/clusters`, `GET /v1/health`.
- **Request validators + Models JSON Schema** por método (rechazo 400 antes de invocar Lambda → también ahorra costo).
- **CORS restrictivo**: `Access-Control-Allow-Origin` fijado al dominio exacto de Vercel. Nada de `*`.
- **Throttling**: límites a nivel de stage (ej. 50 rps / burst 100) + **Usage Plan con API Key** para los organismos de socorro.
  - Honestidad técnica para el informe: API Gateway no hace rate limiting **por IP** de forma nativa — eso es AWS WAF (rate-based rule), que cuesta ~$5/mes de piso. Se documenta como la opción de producción **deliberadamente no habilitada por la política de presupuesto de $10**. Es una respuesta más madura que fingir que el usage plan es per-IP.
- Cada integración apunta al **alias `prod`** de la Lambda, no a `$LATEST` — requisito para que el canary funcione.

---

## 7. Canary + rollback automático (el 20 % más visible)

En el `template.yaml` de cada servicio:

```yaml
AutoPublishAlias: prod
DeploymentPreference:
  Type: Canary10Percent5Minutes
  Alarms:
    - !Ref ErrorsAlarm
    - !Ref LatencyAlarm
    - !Ref Api5xxAlarm
```

**Alarmas CloudWatch** (las tres con `TreatMissingData: notBreaching` — si quedan en `INSUFFICIENT_DATA` el rollback nunca dispara):

| Alarma | Métrica | Umbral |
|---|---|---|
| `ErrorsAlarm` | `AWS/Lambda Errors` (alias `prod`) | ≥ 1 en 1 min |
| `LatencyAlarm` | `AWS/Lambda Duration` p95 | > 1500 ms |
| `Api5xxAlarm` | `AWS/ApiGateway 5XXError` | ≥ 1 en 1 min |

**Detalle que rompe el canary si se ignora:** con `PackageType: Image`, SAM solo publica una versión nueva cuando **cambia el URI de la imagen**. Por eso el CI etiqueta cada imagen con el **SHA del commit**, nunca `latest`.

**Guion de la prueba de resiliencia (para el video):**
1. Desplegar v1 sana. Confirmar 100 % de tráfico en el alias.
2. Commit de v2 con un fallo sintético (`throw` condicionado por parámetro SSM, no por `.env`).
3. CI despliega → CodeDeploy empieza a mover el 10 %.
4. Correr `scripts/traffic_test.js` (adaptado del tuyo, contando `x-handled-by` / versión) → se ven los errores del 10 %.
5. La alarma pasa a ALARM → **CodeDeploy revierte solo al 100 % de v1**, sin tocar nada.
6. Captura de la consola de CodeDeploy con el estado `Rollback successful` + gráfica de CloudWatch.

Este clip es la evidencia más contundente de toda la entrega. **Grabarlo antes del Día 6**, no el último día.

---

## 8. Secretos e IAM

- Parámetros en `/emergencias/prod/<servicio>/*` como **SecureString**: host/usuario/clave del rol Postgres, URL de Supabase, anon key.
- Lectura en **cold start**, cacheada a nivel de módulo (Cache-Aside):

```ts
let cfgPromise: Promise<Config> | undefined;
export const getConfig = () => (cfgPromise ??= loadFromSSM());
```

- Bundlear `@aws-sdk/client-ssm` con esbuild (con imágenes de contenedor no se puede asumir el SDK del runtime, y las layers no aplican).
- **IAM mínimo privilegio** por función: `ssm:GetParameters` restringido a `arn:aws:ssm:us-east-2:<acct>:parameter/emergencias/prod/<servicio>/*` + `kms:Decrypt` sobre la clave usada. Nada de `ssm:*` ni `Resource: "*"`.
- **Rol OIDC de CI**: confianza limitada a `repo:Firewallrbn/emergencias-co-backend:*`; permisos solo para ECR push, CloudFormation, Lambda y CodeDeploy.
- **Frontend**: únicamente `NEXT_PUBLIC_SUPABASE_URL` y `NEXT_PUBLIC_SUPABASE_ANON_KEY` en Vercel Project Settings. La `service_role` key **no existe** en ninguna parte del sistema (los servicios usan roles Postgres) — argumento fuerte para el informe.
- `gitleaks` en pre-commit **y** como job de CI.

---

## 9. Frontend (Vercel)

**Next.js 15 App Router**, dos vistas diferenciadas:

- **Ciudadano** (`/reportar`): formulario por tipo de solicitud con los campos críticos que exige la tabla del §3 del enunciado, captura de GPS, subida de foto para daños estructurales.
  - **Offline-first**: service worker cachea el app shell; los reportes sin conexión van a una cola en IndexedDB y se vacían al evento `online`. Manifest PWA + indicador visible de estado offline y de reportes pendientes.
- **Operador** (`/comando`): mapa MapLibre con las 4 ciudades, marcadores por color de prioridad P1–P4, capa de clusters del servicio `geo`, tabla de despachos que se actualiza por **suscripción Realtime** (demostrar en el video que no hay polling: pestaña de red en silencio).
- Login Supabase Auth con los dos roles → sirve simultáneamente como **demostración de RLS** (el ciudadano no puede ver reportes ajenos).
- Diseñado para redes degradadas: sin fuentes externas pesadas, skeletons, reintentos con backoff.

---

## 10. CI/CD

### 10.1 Workflow por servicio (×4)
`on: push` a `main` con `paths: services/<svc>/**` + `packages/shared/**`:
1. `gitleaks detect`
2. lint + tests unitarios de triage
3. `configure-aws-credentials@v4` con **OIDC** (`role-to-assume`, sin llaves)
4. `docker build` → tag `<ecr>/emergencias-<svc>:${{ github.sha }}` → push a ECR
5. `sam deploy` → CodeDeploy ejecuta el canary

### 10.2 Frontend
Integración nativa de Vercel con GitHub: preview por PR, producción en `main`.

### 10.3 Mirror GitLab (opcional, Día 6 si sobra tiempo)
`git remote add gitlab …` + `.gitlab-ci.yml` con las mismas etapas, para recuperar los puntos extra sin mover el desarrollo.

---

## 11. Gobernanza de costos

`infra/budgets.yaml` con `AWS::Budgets::Budget`: límite **$10.00 USD mensual**, notificación 1 = `ACTUAL > 50 %`, notificación 2 = `FORECASTED > 85 %`, ambas por email. Desplegar el Día 0 y **capturar pantalla de la configuración y del correo de alerta recibido** (la rúbrica pide alertas *comprobadas*, no solo configuradas).

Palancas de costo aplicadas y documentadas: sin VPC/NAT, retención de logs 7 días, memoria Lambda 512 MB, Parameter Store estándar en vez de Secrets Manager, política de lifecycle en ECR (conservar 10 imágenes), validación de esquema en el gateway para no invocar Lambdas con payloads inválidos.

---

## 12. Cronograma — 7 días × 2 personas

**Persona A — Plataforma/Backend**: AWS, SAM, Docker, CI/CD, canary, secretos, budgets.
**Persona B — Datos/Frontend**: Supabase, migraciones, RLS, PostGIS, Next.js, Vercel.

| Día | Persona A | Persona B | Hito verificable |
|---|---|---|---|
| **0** | Cuenta AWS + budgets + tooling + repos | Proyectos Supabase y Vercel | `aws sts get-caller-identity` responde |
| **1** | **Vertical slice**: `intake` hello-world → Docker → ECR → Lambda → API GW → alias `prod` | Schema completo, PostGIS, RLS, seed 4 ciudades × 4 tipos | `curl` al endpoint `prod` devuelve 200 |
| **2** | Lógica real de `intake` (triage, idempotencia) + SQS + `dispatch` | Frontend en Vercel + formulario de radicación funcionando | Un reporte real viaja del navegador a la BD |
| **3** | `geo` (clustering) + `notify` | Mapa MapLibre + dashboard Realtime | Los 4 servicios responden; el mapa pinta datos vivos |
| **4** | Secretos SSM + IAM mínimo + validators/CORS/throttling + OIDC en Actions | PWA offline + vistas ciudadano/operador + verificación de RLS | Push a `main` despliega solo; cero `.env` en el repo |
| **5** | **Canary + alarmas + grabar la prueba de rollback** | Pulido de UI, estados de error, datos de demo | Video del rollback automático en la mano |
| **6** | Diagramas C4, manual de despliegue, evidencias, auditoría `gitleaks` del historial | Guion y grabación del video ≤ 5 min | Informe completo |
| **7** | Colchón: mirror GitLab, revisión de rúbrica punto por punto | Colchón | Entrega |

**Regla de sincronía**: el contrato de API (rutas + JSON Schemas) se congela al final del Día 1 para que ambos carriles avancen sin bloquearse.

---

## 13. Mapa rúbrica → evidencia

Esta tabla es la lista de verificación de la entrega. Nada se da por terminado sin su evidencia.

| Criterio | Peso | Evidencia que lo prueba |
|---|---|---|
| Microservicios y Dominio | 20 % | 4 stacks SAM independientes, 4 schemas, 4 workflows. Seed y demo cubriendo 4 tipos × 4 ciudades. Tabla de patrones del §1.1 en el informe. |
| Dockerización y Serverless | 20 % | 4 Dockerfiles multi-stage, salida de `docker images` con tamaños, logs JSON en CloudWatch, tiempos de cold start medidos. |
| API Gateway y Secretos | 15 % | Stage `prod`, models/validators (mostrar un 400 por payload inválido), CORS restringido, capturas de SSM, políticas IAM con ARN específico, `gitleaks` limpio sobre todo el historial. |
| Estrategia de Despliegue | 20 % | Video del canary al 10 % + alarma + **rollback automático**, consola de CodeDeploy, gráfica de CloudWatch, salida de `traffic_test.js`. |
| Frontend Vercel + Supabase | 15 % | URL en producción, Realtime sin polling (pestaña de red), consulta `ST_DWithin` funcionando, prueba de RLS: ciudadano bloqueado / operador autorizado. |
| Costos y Documentación | 10 % | Capturas de AWS Budgets **y del email de alerta**, C4 en 3 niveles (Contexto/Contenedores/Componentes), manual de despliegue, video ≤ 5 min. |

Diagramas C4 en **Mermaid** dentro de `docs/` — se renderizan en GitHub y se editan como texto (sin herramientas externas).

---

## 14. Recortes autorizados si vamos tarde

Sacrificar **en este orden exacto**, siempre de menor a mayor peso en la rúbrica. Ningún recorte toca los criterios de 20 %:

1. Background Sync de la PWA → botón manual "reintentar envíos" (misma demo, menos código).
2. `ST_ClusterDBSCAN` → agregación por grilla con `ST_SnapToGrid` (más simple, sigue siendo geoespacial real).
3. Webhooks salientes de `notify` → registrar en tabla + Realtime (el enunciado acepta "eventos reactivos").
4. Usage Plan con API Keys → solo throttling a nivel de stage.
5. Tests unitarios → conservar **únicamente** los del triage determinístico (son los que sostienen el argumento de determinismo).
6. Mirror GitLab.

**Nunca recortar**: los 4 microservicios, el canary con rollback, la ausencia de `.env`, las 4 ciudades, AWS Budgets, el video.

---

## 15. Verificación end-to-end

Ejecutar completo antes de entregar; cada paso genera una captura para el informe.

```bash
# 1. Cero secretos en TODO el historial
gitleaks detect --source . --log-opts="--all"

# 2. Las imágenes son ligeras y multi-stage
docker images | grep emergencias

# 3. El gateway rechaza payloads inválidos (validación de esquemas)
curl -i -X POST $API/v1/emergencias -d '{"basura":true}'        # espera 400

# 4. Flujo feliz con idempotencia: dos veces la misma key → un solo registro
curl -X POST $API/v1/emergencias -H "Idempotency-Key: demo-1" -d @fixtures/p1-cali.json
curl -X POST $API/v1/emergencias -H "Idempotency-Key: demo-1" -d @fixtures/p1-cali.json

# 5. Cobertura de dominio: 4 ciudades × 4 tipos
for c in choco pereira cali manizales; do curl -s $API/v1/emergencias/zona/$c | jq length; done

# 6. Geoespacial
curl -s $API/v1/zonas/manizales/clusters | jq

# 7. Throttling: ráfaga por encima del límite → aparecen 429
node scripts/traffic_test.js --burst 200

# 8. Canary + rollback (el clip del video)
git push   # dispara CI con la v2 defectuosa; observar CodeDeploy revertir solo
```

**Verificaciones manuales:**
- Realtime: abrir `/comando`, crear un reporte desde otro navegador → aparece sin recargar y con la pestaña de red en silencio.
- RLS: iniciar sesión como ciudadano → intentar leer un reporte ajeno → denegado. Como operador → permitido.
- Offline: activar modo avión en DevTools, enviar un reporte, reconectar → se sincroniza.
- Presupuesto: confirmar que llegó el correo de alerta de AWS Budgets.

---

## 16. Checklist de entrega final

- [ ] URL del repo backend (GitHub, commits limpios, CI verde, sin secretos en el historial)
- [ ] URL del repo frontend
- [ ] URL de producción en Vercel
- [ ] Endpoint base del API Gateway, stage `prod`
- [ ] Informe técnico: C4 (3 niveles) + flujo de despliegue canary
- [ ] Evidencia de lectura de secretos desde Parameter Store
- [ ] Capturas de AWS Budgets + email de alerta recibido
- [ ] Evidencia de rollback automático ante fallo inyectado en producción
- [ ] Video ≤ 5 min: 4 ciudades, 4 tipos de solicitud, despliegue progresivo en vivo
- [ ] Manual de despliegue reproducible desde cero
