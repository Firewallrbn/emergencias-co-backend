# Evidencia: despliegue canary de `intake` (rollback)

Generado por `scripts/probar-canary.ps1` el 2026-08-22 12:06.

| Dato | Valor |
|---|---|
| Servicio | `intake` |
| Modo | despliegue sano |
| Veredicto | **REVERTIDO AUTOMATICAMENTE** |
| Esperado | PROMOVIDO |
| Coincide | NO |
| Alias | v5 -> v5 |
| Configuracion | Canary10Percent5Minutes |
| Despliegue canary | `d-UPQ98180K` |
| Despliegue de reversion | `d-SLZF8P70K` |
| Duracion observada | 1.9 min |
| Peticiones | 25 (6 con error, 24 %) |

## Cronologia observada

Plano de datos (que version contesta) y plano de control (pesos del alias) a la vez.

| Hora | Reparto observado | Alias | Alarmas | CodeDeploy |
|---|---|---|---|---|
| 12:04:30 | `v5 x3  ERROR 502 x2` | `v5 v7=10%` | OK | `d-UPQ98180K InProgress` |
| 12:04:47 | `ERROR 502 x3  v5 x2` | `v5 v7=10%` | OK | `d-UPQ98180K InProgress` |
| 12:05:04 | `v5 x5` | `v5 v7=10%` | OK | `d-UPQ98180K InProgress` |
| 12:05:21 | `v5 x5` | `v5 v7=10%` | ALARM x1 | `d-UPQ98180K InProgress` |
| 12:05:39 | `v5 x4  ERROR 502 x1` | `v5 v7=10%` | ALARM x1 | `d-SLZF8P70K Succeeded` |

## Reparto acumulado

```
  v5               19     76 %
  ERROR 502         6     24 %
```

## Despliegue canary (salida cruda de CodeDeploy)

```json
{
    "Id": "d-UPQ98180K",
    "Estado": "Stopped",
    "Config": "CodeDeployDefault.LambdaCanary10Percent5Minutes",
    "Inicio": "2026-08-22T12:01:12.834000-05:00",
    "Fin": "2026-08-22T12:05:33.816000-05:00",
    "Causa": {
        "code": "ALARM_ACTIVE",
        "message": "One or more alarms have been activated according to the Amazon CloudWatch metrics you selected, and the affected deployments have been stopped. Activated alarms: <emergencias-intake-errores>"
    }
}
```

## Despliegue de reversion (salida cruda de CodeDeploy)

```json
{
    "Id": "d-SLZF8P70K",
    "Estado": "Succeeded",
    "RollbackInfo": {
        "rollbackTriggeringDeploymentId": "d-UPQ98180K",
        "rollbackMessage": "Deployment d-SLZF8P70K is triggered to roll back deployment d-UPQ98180K."
    }
}
```
