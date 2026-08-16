# Evidencia: rollback automático ante inyección de un fallo sintético

Prueba de resiliencia ejecutada en **producción** sobre el servicio `intake`, el 16 de
agosto de 2026. Demuestra que un despliegue defectuoso se revierte solo, sin intervención
humana, antes de afectar a la mayoría del tráfico.

## Cómo se provoca el fallo

El fallo se inyecta **en el código**, no en la configuración:

```bash
npm run build:caos --workspace @emergencias/intake
# esbuild ... --define:__CAOS__=true
```

`esbuild` sustituye la constante `__CAOS__` en tiempo de compilación, de modo que el
bundle cambia realmente y con él su hash. La función lanza una excepción no controlada en
cada invocación.

> Se intentó primero con una variable de entorno y no funciona: `AutoPublishAlias` publica
> una versión nueva solo cuando cambia el **código**. Un cambio de configuración actualiza
> `$LATEST`, el alias sigue apuntando a la versión anterior y CodeDeploy ni se entera.
> `AutoPublishCodeSha256` serviría para forzarlo, pero exige una cadena literal y no acepta
> `!Sub` ni `!Ref`, así que no se puede atar a un parámetro de la plantilla.

Reproducir la prueba:

```powershell
.\scripts\desplegar-servicio.ps1 intake -Caos          # despliega la version defectuosa
node scripts/traffic_test.js --n 200 --intervalo 1500  # genera trafico durante el canary
```

## Cronología

| Hora (COT) | Suceso |
|---|---|
| 11:56:15 | CodeDeploy inicia el canary `LambdaCanary10Percent5Minutes` con la versión 3 |
| ~11:57 | El 10 % del tráfico empieza a recibir 502; el resto sigue en la versión 2 sana |
| 11:58:45 | La alarma `emergencias-intake-errores` pasa de `OK` a `ALARM` |
| 11:58:56 | El canary se detiene: `ALARM_ACTIVE` |
| 11:58:57 | Arranca el despliegue de reversión `d-4WXUV98WJ` |
| 11:58:59 | Reversión completada. El alias vuelve al 100 % de la versión 2 |
| 12:00:45 | Las alarmas regresan a `OK` |

**De despliegue defectuoso a servicio recuperado: 2 minutos y 44 segundos, sin que nadie
tocara nada.**

## Salida del generador de tráfico

200 peticiones, una cada 1,5 s. Los errores aparecen cuando el canary empieza a repartir y
**se detienen en 4** en cuanto ocurre la reversión:

```
    40/200   v2:40
    50/200   v2:48  ERROR 502:2      <- arranca el reparto del canary
    60/200   v2:57  ERROR 502:3
    80/200   v2:76  ERROR 502:4
   100/200   v2:96  ERROR 502:4      <- rollback hecho: no vuelve a fallar
   200/200   v2:196 ERROR 502:4

=== Reparto de trafico (394.6 s) ===
  v2             ############################  196   98.0%
  ERROR 502      #...........................    4    2.0%

=== Codigos de estado ===
  200: 196
  502: 4
```

Que los errores se estabilicen en 4 y no sigan creciendo es la firma del rollback: si no
existiera, el 10 % habría seguido fallando durante los cinco minutos de la ventana y
después el 100 %.

## Confirmación desde CodeDeploy

Despliegue detenido por alarma:

```json
{
  "Id": "d-LZZTEC8WJ",
  "Estado": "Stopped",
  "Config": "CodeDeployDefault.LambdaCanary10Percent5Minutes",
  "Inicio": "2026-08-16T11:56:15.830000-05:00",
  "Fin": "2026-08-16T11:58:56.665000-05:00",
  "Causa": {
    "code": "ALARM_ACTIVE",
    "message": "Activated alarms: <emergencias-intake-api-5xx> <emergencias-intake-errores>"
  }
}
```

Despliegue de reversión, creado automáticamente:

```json
{
  "Id": "d-4WXUV98WJ",
  "Estado": "Succeeded",
  "RollbackInfo": {
    "rollbackTriggeringDeploymentId": "d-LZZTEC8WJ",
    "rollbackMessage": "Deployment d-4WXUV98WJ is triggered to roll back deployment d-LZZTEC8WJ."
  }
}
```

## Estado final

```
Alias prod -> version 2   (sin pesos de reparto)
Versiones publicadas: 1, 2, 3   <- la 3 existe pero no recibe trafico

GET /v1/health -> HTTP 200
{"servicio":"intake","estado":"ok","version":"2","baseDatos":{"ok":true,"latencyMs":197}}
```

## Por qué hacen falta las dos alarmas

Dispararon **ambas**: `emergencias-intake-api-5xx` y `emergencias-intake-errores`. No es
redundancia, y la diferencia es sutil pero importante.

El manejador de errores del servicio captura los fallos y devuelve un 500 en lugar de
relanzarlos, para no exponer trazas al cliente. El efecto secundario es que un fallo
interno **no incrementa la métrica `AWS/Lambda Errors`**: para CloudWatch, la función
terminó correctamente y devolvió una respuesta.

En esta prueba la excepción se lanza fuera del manejador, así que sí cuenta como error de
Lambda. Pero un fallo real —la base de datos caída, por ejemplo— solo se vería como 5xx en
el gateway. Sin la segunda alarma, ese servicio roto habría pasado el canary sin que nadie
lo revirtiera.

Las tres alarmas llevan `TreatMissingData: notBreaching`. Es el detalle que más veces
rompe esta configuración en la práctica: una alarma que se queda en `INSUFFICIENT_DATA`
nunca dispara la reversión.
