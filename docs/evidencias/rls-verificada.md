# Evidencia: Row Level Security verificada

La misma consulta, contra la misma vista, cambiando únicamente quién la ejecuta.

```
GET /rest/v1/v_emergencias?select=id,ciudad,prioridad

SIN sesión (anónimo)                 -> HTTP 401, acceso denegado
CIUDADANO (app_role = ciudadano)     -> HTTP 200,  0 filas visibles
OPERADOR  (app_role = operador)      -> HTTP 200, 19 filas visibles
```

Las 19 filas son la totalidad de las emergencias sembradas. El ciudadano ve cero porque no
ha reportado ninguna: su política solo le devuelve aquellas donde `reportado_por` coincide
con su propio `auth.uid()`.

**Nadie filtró nada en el código.** La consulta es idéntica en los tres casos; quien decide
qué filas salen es Postgres, aplicando las políticas de la tabla.

## Por qué el rol va en `app_metadata`

El rol de aplicación viaja en el JWT dentro de `app_metadata`, no de `user_metadata`. La
diferencia es de seguridad: `user_metadata` lo puede editar la propia persona desde el
cliente, así que cualquiera se ascendería a operador con una llamada. `app_metadata` solo
se modifica desde el servidor.

Aun así, el frontend usa ese valor únicamente para decidir qué dibujar. Si alguien
falseara el rol en su navegador, seguiría sin recibir una sola fila de más: la
autorización real ocurre en la base.

## Por qué hay vistas en `public`

Supabase solo sirve por su API REST los schemas declarados como expuestos, y por defecto
son `public` y `graphql_public`. Una consulta directa a `intake.emergencias` devuelve:

```json
{"code":"PGRST106","message":"Invalid schema: intake",
 "hint":"Only the following schemas are exposed: public, graphql_public"}
```

Se resolvió con vistas en `public` (migración `009`) en lugar de exponer los cuatro
schemas completos. La diferencia importa: exponer un schema publica **todas** sus tablas,
presentes y futuras; una vista declara exactamente qué columnas salen. Si mañana se añade
una tabla interna a `intake`, no queda publicada por accidente.

Todas las vistas llevan `security_invoker = true`. Sin eso se evaluarían con los permisos
de su dueño y **saltarían la RLS de la tabla subyacente**, que es justo lo que se está
protegiendo. Con el invocador, la vista hereda los permisos de quien pregunta.

## Cuentas de demostración

Creadas para la sustentación. Contraseñas públicas a propósito: son cuentas de prueba sin
ningún dato real detrás.

| Correo | Contraseña | Rol |
|---|---|---|
| `operador@example.com` | `Operador-Demo-2026` | operador |
| `ciudadano@example.com` | `Ciudadano-Demo-2026` | ciudadano |

Se crearon por SQL, no por el flujo de registro, porque el envío de correos del plan
gratuito de Supabase está limitado por cuota y estas cuentas no necesitan confirmación.

> Detalle que costó un rato: insertar en `auth.users` a mano deja en `NULL` las columnas
> de tokens (`confirmation_token`, `recovery_token`, `email_change`…). GoTrue las lee en
> variables de tipo `string` de Go, que no admiten nulos, y el login falla con un
> `500 Database error querying schema` que no dice nada de la causa. El valor correcto
> para "sin token pendiente" es la cadena vacía.

## Reproducir

```powershell
$url = '<url-del-proyecto-supabase>'
$key = '<clave-publicable>'

# 1. Sin sesión
Invoke-WebRequest "$url/rest/v1/v_emergencias?select=id" `
  -Headers @{ apikey = $key; Authorization = "Bearer $key" } -SkipHttpErrorCheck

# 2. Con sesión: obtener token y repetir la MISMA consulta
$b = @{ email = 'operador@example.com'; password = 'Operador-Demo-2026' } | ConvertTo-Json
$t = (Invoke-WebRequest "$url/auth/v1/token?grant_type=password" -Method POST -Body $b `
      -ContentType 'application/json' -Headers @{ apikey = $key }).Content |
      ConvertFrom-Json | Select-Object -ExpandProperty access_token

Invoke-WebRequest "$url/rest/v1/v_emergencias?select=id" `
  -Headers @{ apikey = $key; Authorization = "Bearer $t" }
```
