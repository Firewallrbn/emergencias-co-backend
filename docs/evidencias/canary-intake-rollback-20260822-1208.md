# Evidencia: despliegue canary de `intake` (rollback)

Generado por `scripts/probar-canary.ps1` el 2026-08-22 12:08.

| Dato | Valor |
|---|---|
| Servicio | `intake` |
| Modo | despliegue sano |
| Veredicto | **REVERTIDO AUTOMATICAMENTE** |
| Esperado | PROMOVIDO |
| Coincide | NO |
| Alias | v5 -> v5 |
| Configuracion | Canary10Percent5Minutes |
| Despliegue canary | `d-9Y84SF70K` |
| Despliegue de reversion | `d-KSA62M70K` |
| Duracion observada | 1.6 min |
| Peticiones | 20 (0 con error, 0 %) |

## Cronologia observada

Plano de datos (que version contesta) y plano de control (pesos del alias) a la vez.

| Hora | Reparto observado | Alias | Alarmas | CodeDeploy |
|---|---|---|---|---|
| 12:07:36 | `v5 x5` | `v5` | ALARM x2 | `esperando (previo: d-SLZF8P70K)` |
| 12:07:51 | `v5 x5` | `v5` | ALARM x2 | `esperando (previo: d-SLZF8P70K)` |
| 12:08:07 | `v5 x5` | `v5` | ALARM x2 | `d-9Y84SF70K Stopped` |
| 12:08:24 | `v5 x5` | `v5` | ALARM x1 | `d-KSA62M70K Succeeded` |

## Reparto acumulado

```
  v5               20    100 %
```

## Despliegue canary (salida cruda de CodeDeploy)

```json
{
    "Id": "d-9Y84SF70K",
    "Estado": "Stopped",
    "Config": "CodeDeployDefault.LambdaCanary10Percent5Minutes",
    "Inicio": "2026-08-22T12:08:04.846000-05:00",
    "Fin": "2026-08-22T12:08:05.580000-05:00",
    "Causa": {
        "code": "ALARM_ACTIVE",
        "message": "One or more alarms have been activated according to the Amazon CloudWatch metrics you selected, and the affected deployments have been stopped. Activated alarms: <emergencias-intake-api-5xx> <emergencias-intake-errores>"
    }
}
```

## Despliegue de reversion (salida cruda de CodeDeploy)

```json
{
    "Id": "d-KSA62M70K",
    "Estado": "Succeeded",
    "RollbackInfo": {
        "rollbackTriggeringDeploymentId": "d-9Y84SF70K",
        "rollbackMessage": "Deployment d-KSA62M70K is triggered to roll back deployment d-9Y84SF70K."
    }
}
```
