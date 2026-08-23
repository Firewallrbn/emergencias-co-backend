# Evidencia: despliegue canary de `intake` (rollback)

Generado por `scripts/probar-canary.ps1` el 2026-08-22 12:01.

| Dato | Valor |
|---|---|
| Servicio | `intake` |
| Modo | caos (fallo sintetico inyectado) |
| Veredicto | **REVERTIDO AUTOMATICAMENTE** |
| Esperado | REVERTIDO AUTOMATICAMENTE |
| Coincide | si |
| Alias | v5 -> v5 |
| Configuracion | Canary10Percent5Minutes |
| Despliegue canary | `` |
| Despliegue de reversion | `d-NV7KPB60K` |
| Duracion observada | 0.8 min |
| Peticiones | 5 (0 con error, 0 %) |

## Cronologia observada

Plano de datos (que version contesta) y plano de control (pesos del alias) a la vez.

| Hora | Reparto observado | Alias | Alarmas | CodeDeploy |
|---|---|---|---|---|
| 12:00:46 | `v5 x5` | `v5` | OK | `d-NV7KPB60K Succeeded` |

## Reparto acumulado

```
  v5                5    100 %
```

## Despliegue de reversion (salida cruda de CodeDeploy)

```json
{
    "Id": "d-NV7KPB60K",
    "Estado": "Succeeded",
    "RollbackInfo": {
        "rollbackTriggeringDeploymentId": "d-JCUUEM60K",
        "rollbackMessage": "Deployment d-NV7KPB60K is triggered to roll back deployment d-JCUUEM60K."
    }
}
```
