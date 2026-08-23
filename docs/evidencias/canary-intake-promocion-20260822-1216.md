# Evidencia: despliegue canary de `intake` (promocion)

Generado por `scripts/probar-canary.ps1` el 2026-08-22 12:16.

| Dato | Valor |
|---|---|
| Servicio | `intake` |
| Modo | despliegue sano |
| Veredicto | **PROMOVIDO** |
| Esperado | PROMOVIDO |
| Coincide | si |
| Alias | v5 -> v9 |
| Configuracion | Canary10Percent5Minutes |
| Despliegue canary | `d-TU7CZL70K` |
| Despliegue de reversion | ninguno |
| Duracion observada | 5.9 min |
| Peticiones | 105 (0 con error, 0 %) |

## Cronologia observada

Plano de datos (que version contesta) y plano de control (pesos del alias) a la vez.

| Hora | Reparto observado | Alias | Alarmas | CodeDeploy |
|---|---|---|---|---|
| 12:10:49 | `v5 x5` | `v5` | OK | `esperando (previo: d-KSA62M70K)` |
| 12:11:03 | `v5 x5` | `v5` | OK | `esperando (previo: d-KSA62M70K)` |
| 12:11:20 | `v5 x5` | `v5` | OK | `d-TU7CZL70K InProgress` |
| 12:11:35 | `v5 x5` | `v5 v9=10%` | OK | `d-TU7CZL70K InProgress` |
| 12:11:53 | `v5 x4  v9 x1` | `v5 v9=10%` | OK | `d-TU7CZL70K InProgress` |
| 12:12:10 | `v5 x5` | `v5 v9=10%` | OK | `d-TU7CZL70K InProgress` |
| 12:12:27 | `v5 x5` | `v5 v9=10%` | OK | `d-TU7CZL70K InProgress` |
| 12:12:45 | `v5 x4  v9 x1` | `v5 v9=10%` | OK | `d-TU7CZL70K InProgress` |
| 12:13:02 | `v5 x5` | `v5 v9=10%` | OK | `d-TU7CZL70K InProgress` |
| 12:13:19 | `v5 x5` | `v5 v9=10%` | OK | `d-TU7CZL70K InProgress` |
| 12:13:36 | `v5 x5` | `v5 v9=10%` | OK | `d-TU7CZL70K InProgress` |
| 12:13:53 | `v5 x5` | `v5 v9=10%` | OK | `d-TU7CZL70K InProgress` |
| 12:14:10 | `v5 x5` | `v5 v9=10%` | OK | `d-TU7CZL70K InProgress` |
| 12:14:27 | `v5 x5` | `v5 v9=10%` | OK | `d-TU7CZL70K InProgress` |
| 12:14:44 | `v5 x3  v9 x2` | `v5 v9=10%` | OK | `d-TU7CZL70K InProgress` |
| 12:15:01 | `v5 x5` | `v5 v9=10%` | OK | `d-TU7CZL70K InProgress` |
| 12:15:18 | `v5 x5` | `v5 v9=10%` | OK | `d-TU7CZL70K InProgress` |
| 12:15:36 | `v5 x3  v9 x2` | `v5 v9=10%` | OK | `d-TU7CZL70K InProgress` |
| 12:15:53 | `v5 x3  v9 x2` | `v5 v9=10%` | OK | `d-TU7CZL70K InProgress` |
| 12:16:09 | `v5 x4  v9 x1` | `v5 v9=10%` | OK | `d-TU7CZL70K InProgress` |
| 12:16:26 | `v9 x5` | `v9` | OK | `d-TU7CZL70K Succeeded` |

## Reparto acumulado

```
  v5               91   86.7 %
  v9               14   13.3 %
```

## Despliegue canary (salida cruda de CodeDeploy)

```json
{
    "Id": "d-TU7CZL70K",
    "Estado": "Succeeded",
    "Config": "CodeDeployDefault.LambdaCanary10Percent5Minutes",
    "Inicio": "2026-08-22T12:11:17.191000-05:00",
    "Fin": "2026-08-22T12:16:19.499000-05:00",
    "Causa": null
}
```
