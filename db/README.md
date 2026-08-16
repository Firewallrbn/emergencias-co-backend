# Base de datos

PostgreSQL gestionado en Supabase, con PostGIS para las consultas de proximidad y RLS
activa en todas las tablas.

## Diseño

**Un schema por microservicio** (Database per Service en su variante lógica). Ningún
servicio escribe en el schema de otro; la lectura entre servicios pasa por vistas
explícitas que actúan de Anti-Corruption Layer.

| Schema | Dueño | Contenido |
|---|---|---|
| `extensions` | — | PostGIS |
| `comun` | — | Tipos del dominio (enums) y helpers de RLS |
| `intake` | `svc_intake` | `emergencias` |
| `dispatch` | `svc_dispatch` | `unidades`, `despachos`, `v_emergencias_pendientes` |
| `geo` | `svc_geo` | `clusters` |
| `notify` | `svc_notify` | `notificaciones`, `webhooks` |

**Los servicios no usan la `service_role` key de Supabase.** Cada uno se conecta con su
propio rol Postgres, que no es superusuario ni tiene `BYPASSRLS`, así que las políticas de
RLS también se aplican al backend. Ese es justamente el punto que se pierde al usar
`service_role`, que se salta RLS por completo.

## Orden de aplicación

```
migrations/001_extensiones_y_schemas.sql
migrations/002_roles_y_permisos.sql
migrations/003_intake.sql
migrations/004_dispatch.sql
migrations/005_geo.sql
migrations/006_notify.sql
migrations/007_realtime.sql
seed/001_unidades.sql
seed/002_emergencias_demo.sql
```

Todas son idempotentes: volver a ejecutarlas no cambia nada. El seed verifica al final que
existan las **16 combinaciones tipo × ciudad** que exige la rúbrica y falla si faltan.

## Validación local antes de tocar Supabase

```powershell
.\scripts\validar-migraciones.ps1            # levanta PostGIS en Docker y aplica todo
.\scripts\validar-migraciones.ps1 -Conservar # deja el contenedor vivo para inspeccionarlo
```

Levanta `postgis/postgis:17-3.5`, replica el layout de Supabase mediante
`db/local-test/000_stubs_supabase.sql` (PostGIS en `extensions`, schema `auth`, roles `anon`
y `authenticated`), aplica migraciones y seed, y comprueba cobertura del dominio, RLS
forzada, ausencia de `BYPASSRLS`, proximidad con `ST_DWithin` y clustering DBSCAN.

`db/local-test/` es **solo para pruebas**: nunca se aplica en Supabase, que ya provisiona
esos objetos por su cuenta.

Al aplicar `007_realtime.sql` en el contenedor local aparece
`WARNING: "wal_level" is insufficient to publish logical changes`. Es esperado y no indica
un problema: Postgres a secas arranca con `wal_level=replica`, mientras que Supabase ya
viene configurado en `logical`.

## Contraseñas de los roles de servicio — paso manual, una sola vez

Las migraciones crean los roles `svc_*` **sin contraseña y sin capacidad de login**. Es
deliberado: una contraseña escrita aquí acabaría en el repositorio, que es exactamente lo
que el enunciado prohíbe.

Por cada servicio, con una contraseña generada al azar y **fuera de todo archivo del repo**:

```sql
-- En el SQL Editor de Supabase, una vez por rol
alter role svc_intake login password '<contrasena-generada>';
```

Y acto seguido, la cadena de conexión va directo a Parameter Store:

```powershell
aws ssm put-parameter `
  --name /emergencias/prod/intake/database_url `
  --type SecureString `
  --value "postgresql://svc_intake:<contrasena>@<host>:6543/postgres" `
  --region us-east-2
```

Usa el **puerto 6543** (pooler Supavisor en modo transacción), no el 5432. El código de
`packages/shared/src/db.ts` está escrito para ese modo: `max: 1` por contenedor y sentencias
preparadas sin nombre.

Genera las contraseñas con algo como
`[Convert]::ToBase64String((1..24 | ForEach-Object { Get-Random -Max 256 }))` y no las
guardes en ningún archivo: una vez en Parameter Store, se leen desde ahí.

## Roles de aplicación y RLS

El rol de la persona usuaria viaja en el JWT de Supabase dentro de
`app_metadata.app_role`, que el cliente no puede modificar (a diferencia de
`user_metadata`). Valores: `ciudadano` (por defecto) y `operador`. Un operador puede llevar
además `app_metadata.ciudad` para limitar su alcance a un nodo.

| Quién | Puede |
|---|---|
| Ciudadano | Leer únicamente los reportes que él creó |
| Operador | Leer las emergencias de su ciudad (o todas si no tiene ciudad asignada), unidades, despachos, clusters y notificaciones |
| `svc_intake` | Todo sobre `intake.emergencias` |
| `svc_dispatch` | Todo sobre su schema; solo lectura de `intake` |
| `svc_geo` | Todo sobre su schema; solo lectura de `intake` |
| `svc_notify` | Todo sobre su schema |

Todas las tablas llevan `FORCE ROW LEVEL SECURITY`. Sin `FORCE`, el dueño de la tabla se
salta las políticas y las pruebas de RLS darían un falso verde.
