# CLAUDE.md — emergencias-co-backend

Backend serverless del Parcial 1 de *Patrones Arquitectónicos Avanzados*. Antes de tocar nada, lee
`docs/enunciado-parcial-1.md` (los requisitos que se califican) y `docs/plan-de-ejecucion.md`
(las decisiones ya tomadas y el cronograma). **No re-decidas lo que ya está decidido ahí.**

## Reglas duras — violarlas cuesta nota directamente

1. **Cero secretos en el repositorio, jamás, tampoco en el historial.** No crees `.env`, no
   hardcodees llaves, no pongas URLs de Supabase en el código. Todo valor sensible vive en
   AWS Parameter Store bajo `/emergencias/prod/<servicio>/` y se lee en el cold start.
   El hook de pre-commit (`gitleaks`) aborta el commit si detecta algo.
2. **Nunca uses la `service_role` key de Supabase en una Lambda.** Bypassea RLS y anula el
   criterio que se está evaluando. Cada servicio se conecta con su propio rol Postgres.
3. **Las Lambdas se despliegan como paquete zip, no como imagen.** Decisión explícita del
   equipo por costo, aunque el enunciado pide ECR: queda documentada como desviación en el
   informe, no como olvido. Los `Dockerfile` y el `docker-compose.yml` siguen vivos para la
   demostración local. El zip lo produce esbuild y pesa ~700 KB, sin `node_modules`.
4. **Toda integración de API Gateway apunta al alias `prod`**, nunca a `$LATEST`. Si apunta a
   `$LATEST`, el canary no divide tráfico y se pierde el 20 % de la rúbrica.
5. **Las alarmas de CloudWatch llevan `TreatMissingData: notBreaching`.** Si quedan en
   `INSUFFICIENT_DATA`, CodeDeploy nunca revierte y la demo de rollback no funciona.
6. **Cobertura obligatoria del dominio**: 4 tipos de solicitud (P1 USAR/médica, P2 albergue,
   P3 suministros, P4 daños estructurales) × 4 ciudades (Chocó, Pereira, Cali, Manizales).
   Cualquier código, seed o prueba que cubra menos, está incompleto.

## Arquitectura en una pantalla

```
Vercel (Next.js PWA) ──► API Gateway REST (stage prod, validators + CORS + throttling)
                              │
              ┌───────────────┼───────────────┬──────────────┐
              ▼               ▼               ▼              ▼
           intake ──SQS──► dispatch          geo           notify
              │               │               │              │
              └───────────────┴───────┬───────┴──────────────┘
                                      ▼
                        Supabase Postgres + PostGIS
                     (un schema y un rol por servicio, RLS activa)
```

Cada servicio: imagen OCI multi-stage → ECR → Lambda con alias `prod` → CodeDeploy Canary
10 % / 5 min vigilado por alarmas, con rollback automático.

## Convenciones

- **TypeScript**, bundle con esbuild. La etapa final del Dockerfile no lleva `node_modules`.
- Utilidades transversales en `packages/shared` — **reúsalas, no las dupliques**: cargador de
  config SSM (cache-aside), logger estructurado, retry con backoff+jitter, circuit breaker, pool `pg`.
- Un `template.yaml` por servicio. No hay stack monolítico.
- Logs en JSON con `requestId`, `service`, `ciudad`, `tipo`, `latencyMs`.
- Migraciones en `db/migrations/NNN_*.sql`, **idempotentes** (deben poder correrse dos veces).
- Español en documentación, comentarios y mensajes de commit. Identificadores de código en inglés.

## Patrones que se están evaluando

El curso es de patrones: cuando implementes uno, **nómbralo en un comentario** para que sea
rastreable en el informe. Los comprometidos son Queue-Based Load Leveling (SQS intake→dispatch),
Idempotency Key, Circuit Breaker, Retry con backoff, Bulkhead (concurrencia reservada por función),
Cache-Aside (secretos), Database per Service (schema por servicio), Anti-Corruption Layer (vistas
read-only cross-schema), Health Endpoint Monitoring y Canary Release.

## Región y nombres

Región AWS: **us-east-2**. Prefijo de recursos: `emergencias-`. Stage: `prod`.

## Comandos

```bash
git config core.hooksPath .githooks              # una vez por clon
gitleaks detect --source . --log-opts="--all"    # auditar todo el historial
sam build && sam deploy                          # desde services/<svc>/
node scripts/traffic_test.js                     # verificar el split del canary
```

> Nota de entorno: en esta máquina el credential helper de git es un alias de `gh` que no
> arranca desde el shell POSIX del sandbox. **Los comandos git que tocan la red (push, pull,
> fetch) hay que correrlos desde PowerShell**, no desde bash.
