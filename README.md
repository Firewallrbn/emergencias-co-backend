# emergencias-co-backend

Backend serverless para gestión de emergencias tras el sismo de 2026 en Chocó, Pereira, Cali y Manizales.
Parcial 1 — Patrones Arquitectónicos Avanzados.

Cuatro microservicios autónomos, empaquetados como imágenes OCI y desplegados en AWS Lambda detrás de un
API Gateway REST, con despliegue progresivo Canary y rollback automático.

## Estructura

```
packages/shared/     Utilidades transversales: config desde SSM (cache-aside),
                     logger estructurado, retry con backoff+jitter, circuit breaker, pool pg
services/intake/     Recepción de reportes, triage determinístico P1-P4, idempotencia, publica en SQS
services/dispatch/   Consume SQS, asigna unidades por proximidad (ST_DWithin)
services/geo/        Clustering geoespacial de puntos calientes y zonas aisladas
services/notify/     Notificaciones y broadcast de estado
infra/               API Gateway REST, AWS Budgets, rol OIDC de despliegue
db/migrations/       SQL versionado e idempotente (schemas, PostGIS, RLS)
scripts/             Verificadores de tráfico y del canary
docs/                Diagramas C4, manual de despliegue, evidencias
```

Cada servicio tiene su propio `template.yaml` (stack SAM independiente) y su propio workflow en
`.github/workflows/`, disparado por `paths:` — ciclo de vida de CI/CD por microservicio.

## Política de secretos

**No existe ningún `.env` en este repositorio, ni debe existir jamás — tampoco en el historial.**

- Los servicios leen su configuración de **AWS Systems Manager Parameter Store** (`SecureString`) en el
  cold start, bajo el prefijo `/emergencias/prod/<servicio>/`.
- Cada función Lambda tiene un rol IAM que solo puede leer **su propio** prefijo de parámetros.
- El CI se autentica con **GitHub OIDC** contra un rol IAM: cero llaves estáticas en GitHub Secrets.
- Las Lambdas **no usan la `service_role` key de Supabase**. Cada servicio se conecta con su propio rol
  Postgres, de modo que RLS sigue aplicando también al backend.

Guarda activa: `gitleaks` corre como hook de pre-commit y como job de CI.

```bash
git config core.hooksPath .githooks   # una vez por clon
```

## Requisitos locales

| Herramienta | Versión usada |
|---|---|
| Node.js | 22+ |
| Docker | 29+ (daemon corriendo) |
| AWS CLI | v2 |
| AWS SAM CLI | 1.165+ |
| gitleaks | 8.30+ |
| psql | 17+ |

## Demostración local

```bash
docker compose up --build
curl http://localhost:8080/v1/health
```

Levanta los cuatro microservicios como contenedores OCI, un API Gateway local que traduce
HTTP corriente al evento que esperan las funciones, y una base PostGIS con las migraciones
y el seed ya aplicados.

**Es autocontenido**: no hace falta cuenta de AWS, ni proyecto de Supabase, ni credenciales
de ningún tipo. Cualquiera puede clonar el repositorio y levantarlo. Una primera versión
leía los secretos de Parameter Store montando las credenciales locales —más fiel a
producción— pero solo funcionaba en la máquina del autor, lo que la inutilizaba como
demostración.

Las imágenes son **exactamente** las que se desplegarían: no hay variante "de desarrollo".

```bash
# Un reporte completo
curl -X POST http://localhost:8080/v1/emergencias \
  -H 'Content-Type: application/json' \
  -H 'Idempotency-Key: demo-001' \
  -d '{"tipo":"usar_medica","ciudad":"cali",
       "descripcion":"Estructura colapsada con personas atrapadas",
       "coordenadas":{"lon":-76.523,"lat":3.452},
       "datos":{"personas_atrapadas":3,"riesgo_inminente":["fuego"]}}'

# Repetir con la misma clave: devuelve el mismo id y duplicado:true
# Puntos calientes detectados por DBSCAN
curl http://localhost:8080/v1/zonas/cali/clusters

# Inspeccionar la base
psql -h localhost -p 55433 -U postgres
```

Dos diferencias con producción, ambas visibles en la respuesta y en los logs:

- **No hay SQS**, así que las emergencias se registran pero no se encolan para despacho.
  La respuesta lo dice: `"despacho_encolado": false`.
- **La contraseña de la base está a la vista** en `docker-compose.yml`. Es correcto:
  protege un contenedor efímero que se destruye con `docker compose down`, sin un solo
  dato real dentro. Los secretos de verdad viven en Parameter Store y se generan con
  `scripts/configurar-credenciales.ps1`.

## Despliegue

El despliegue es automático: un push a `main` que toque `services/<svc>/**` construye la imagen, la
publica en ECR etiquetada con el SHA del commit y ejecuta `sam deploy`, que dispara un despliegue
Canary (10 % durante 5 minutos) vigilado por alarmas de CloudWatch. Si alguna alarma se activa,
CodeDeploy revierte al 100 % de la versión anterior sin intervención manual.

El manual reproducible desde cero está en `docs/manual-despliegue.md`.
