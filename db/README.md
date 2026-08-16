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

## Contraseñas de los roles de servicio

Las migraciones crean los roles `svc_*` **sin contraseña y sin capacidad de login**. Es
deliberado: una contraseña escrita en una migración acabaría en el repositorio, que es
exactamente lo que el enunciado prohíbe.

Para asignarlas hay un script que lo hace todo de una vez:

```powershell
.\scripts\configurar-credenciales.ps1
```

El host del pooler ya viene por defecto: `aws-0-ca-central-1.pooler.supabase.com`. Si algún
día cambia, se copia del botón **Connect** de la barra superior del dashboard (pestaña
*Transaction pooler*) y se pasa con `-PoolerHost`.

> **El proyecto de Supabase está en `ca-central-1`, mientras que las Lambdas corren en
> `us-east-2`.** Cada consulta cruza regiones y suma unos 20-30 ms de ida y vuelta. Es
> asumible para este sistema, pero conviene tenerlo presente al leer las latencias en
> CloudWatch: parte del tiempo no es cómputo, es distancia.

Qué hace, por cada uno de los cuatro servicios:

1. Genera una contraseña de 40 caracteres con el RNG criptográfico del sistema.
2. Ejecuta `alter role svc_<x> with login password ...` en Supabase.
3. Comprueba que ese rol puede conectarse **por el pooler en modo transacción** (6543),
   que es exactamente como lo hará la Lambda.
4. Publica la cadena de conexión en Parameter Store como `SecureString`.

Detalles que importan:

- **Las contraseñas nunca se imprimen, ni se guardan en disco, ni quedan en el historial
  del shell.** El SQL entra a `psql` por stdin y el valor de SSM por un archivo temporal
  que se sobrescribe antes de borrarse — ambas cosas para que la contraseña no aparezca en
  la línea de comandos, que es visible en la lista de procesos.
- Solo se generan caracteres alfanuméricos: la contraseña se embebe en una URL de conexión
  y un `@` o un `/` obligarían a codificarla en porcentaje. Se compensa con longitud.
- Una vez ejecutado, **la única copia está en Parameter Store**. Para consultarla:
  `aws ssm get-parameter --name /emergencias/prod/intake/database_url --with-decryption`
- Para rotar las contraseñas, basta con volver a ejecutar el script.

El puerto es el **6543** (Supavisor en modo transacción), no el 5432. El código de
`packages/shared/src/db.ts` está escrito para ese modo: `max: 1` por contenedor y sentencias
preparadas sin nombre.

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
