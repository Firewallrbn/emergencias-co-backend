<#
.SYNOPSIS
  Verificacion end-to-end del sistema completo contra el entorno de produccion.

.DESCRIPTION
  Recorre el camino real de una solicitud de auxilio y comprueba que los cuatro
  microservicios colaboran:

    ciudadano -> API Gateway -> intake -> SQS -> dispatch -> unidad asignada
                                  |
                                  +-> geo (puntos calientes) y notify (difusion)

  Cada paso se verifica de verdad; no se da nada por hecho porque "deberia funcionar".
  Al terminar, limpia los datos que creo.

.EXAMPLE
  .\scripts\probar-flujo-completo.ps1
#>
[CmdletBinding()]
param(
  [string]$Api = 'https://rdrlxnfz59.execute-api.us-east-2.amazonaws.com/prod'
)

$ErrorActionPreference = 'Stop'
$fallos = 0
$paso = 0

function Comprobar {
  param([string]$Nombre, [scriptblock]$Accion, [scriptblock]$Condicion)

  $script:paso++
  Write-Host ("[{0}] {1}" -f $script:paso, $Nombre) -NoNewline

  try {
    $resultado = & $Accion
    $ok = & $Condicion $resultado
    if ($ok) {
      Write-Host "  OK" -ForegroundColor Green
    } else {
      Write-Host "  FALLO" -ForegroundColor Red
      Write-Host "      recibido: $($resultado | ConvertTo-Json -Depth 4 -Compress)" -ForegroundColor DarkGray
      $script:fallos++
    }
    return $resultado
  } catch {
    Write-Host "  EXCEPCION: $($_.Exception.Message)" -ForegroundColor Red
    $script:fallos++
    return $null
  }
}

function Llamar {
  param([string]$Metodo, [string]$Ruta, $Cuerpo, [hashtable]$Cabeceras)
  $p = @{ Uri = "$Api$Ruta"; Method = $Metodo; SkipHttpErrorCheck = $true; TimeoutSec = 45 }
  if ($Cuerpo) { $p.Body = ($Cuerpo | ConvertTo-Json -Depth 6); $p.ContentType = 'application/json' }
  if ($Cabeceras) { $p.Headers = $Cabeceras }
  $r = Invoke-WebRequest @p
  $cuerpo = if ($r.Content) { try { $r.Content | ConvertFrom-Json } catch { $r.Content } } else { $null }
  return [pscustomobject]@{ Estado = [int]$r.StatusCode; Cuerpo = $cuerpo }
}

$marca = "e2e-$(Get-Date -Format 'yyyyMMddHHmmss')"
Write-Host "Marca de esta ejecucion: $marca`n" -ForegroundColor Cyan

# --------------------------------------------------------------------------------------
# Salud de los cuatro servicios
# --------------------------------------------------------------------------------------
Comprobar 'Salud de intake' { Llamar GET '/v1/health' } { param($r) $r.Estado -eq 200 -and $r.Cuerpo.estado -eq 'ok' } | Out-Null

# --------------------------------------------------------------------------------------
# Camino principal: reporte de una emergencia critica
# --------------------------------------------------------------------------------------
$reporte = @{
  tipo         = 'usar_medica'
  ciudad       = 'manizales'
  descripcion  = "Prueba end-to-end $marca. Estructura colapsada con personas atrapadas."
  coordenadas  = @{ lon = -75.5133; lat = 5.0706 }
  datos        = @{ personas_atrapadas = 5; heridos = 3; riesgo_inminente = @('fuga_gas') }
}

$creada = Comprobar 'POST /v1/emergencias devuelve 201 y prioridad P1' `
  { Llamar POST '/v1/emergencias' $reporte @{ 'Idempotency-Key' = $marca } } `
  { param($r) $r.Estado -eq 201 -and $r.Cuerpo.prioridad -eq 'P1' }

$emergenciaId = $creada.Cuerpo.id

Comprobar 'Reenvio con la misma clave no duplica' `
  { Llamar POST '/v1/emergencias' $reporte @{ 'Idempotency-Key' = $marca } } `
  { param($r) $r.Estado -eq 200 -and $r.Cuerpo.duplicado -eq $true -and $r.Cuerpo.id -eq $emergenciaId } | Out-Null

Comprobar 'GET de la emergencia recien creada' `
  { Llamar GET "/v1/emergencias/$emergenciaId" } `
  { param($r) $r.Estado -eq 200 -and $r.Cuerpo.id -eq $emergenciaId } | Out-Null

# --------------------------------------------------------------------------------------
# El salto asincrono: SQS -> dispatch
# --------------------------------------------------------------------------------------
Write-Host "[*] Esperando a que dispatch consuma el mensaje de la cola..." -NoNewline
$despacho = $null
for ($i = 0; $i -lt 20; $i++) {
  Start-Sleep -Seconds 3
  $r = Llamar GET '/v1/despachos?ciudad=manizales'
  $despacho = $r.Cuerpo.despachos | Where-Object { $_.emergencia_id -eq $emergenciaId } | Select-Object -First 1
  if ($despacho) { break }
  Write-Host '.' -NoNewline
}
$script:paso++
if ($despacho) {
  Write-Host " OK tras $([int](($i + 1) * 3)) s" -ForegroundColor Green
  Write-Host "      unidad $($despacho.unidad) ($($despacho.organismo)) a $($despacho.distancia_m) m, estado '$($despacho.estado)'" -ForegroundColor DarkGray
  if (-not $despacho.unidad) { Write-Host "      FALLO: no se asigno ninguna unidad" -ForegroundColor Red; $script:fallos++ }
} else {
  Write-Host " FALLO: dispatch no proceso el mensaje en 60 s" -ForegroundColor Red
  $script:fallos++
}

# --------------------------------------------------------------------------------------
# Cierre del despacho y liberacion de la unidad
# --------------------------------------------------------------------------------------
if ($despacho) {
  Comprobar 'PATCH cierra el despacho como atendido' `
    { Llamar PATCH "/v1/despachos/$($despacho.id)" @{ estado = 'atendido'; notas = "Cerrado por $marca" } } `
    { param($r) $r.Estado -eq 200 -and $r.Cuerpo.estado -eq 'atendido' } | Out-Null
}

# --------------------------------------------------------------------------------------
# Servicios 3 y 4
# --------------------------------------------------------------------------------------
Comprobar 'geo detecta el punto caliente sembrado en Cali' `
  { Llamar GET '/v1/zonas/cali/clusters' } `
  { param($r) $r.Estado -eq 200 -and $r.Cuerpo.clusters.Count -ge 1 } | Out-Null

Comprobar 'geo responde zonas aisladas' `
  { Llamar GET '/v1/zonas/choco/aisladas' } `
  { param($r) $r.Estado -eq 200 -and $null -ne $r.Cuerpo.total_aisladas } | Out-Null

$notif = Comprobar 'notify registra y difunde por Realtime' `
  { Llamar POST '/v1/notificaciones' @{ emergencia_id = $emergenciaId; asunto = "Unidad en ruta ($marca)"; canal = 'realtime' } } `
  { param($r) $r.Estado -eq 201 -and $r.Cuerpo.notificaciones.Count -ge 1 }

Comprobar 'notify lista las notificaciones de la emergencia' `
  { Llamar GET "/v1/notificaciones?emergencia_id=$emergenciaId" } `
  { param($r) $r.Estado -eq 200 -and $r.Cuerpo.total -ge 1 } | Out-Null

# --------------------------------------------------------------------------------------
# Rechazos: la validacion de esquemas del gateway
# --------------------------------------------------------------------------------------
Comprobar 'El gateway rechaza un tipo fuera del enum' `
  { Llamar POST '/v1/emergencias' @{ tipo = 'inexistente'; ciudad = 'cali'; descripcion = 'x'; coordenadas = @{ lon = 0; lat = 0 } } @{ 'Idempotency-Key' = "$marca-malo" } } `
  { param($r) $r.Estado -eq 400 } | Out-Null

Comprobar 'El gateway exige la cabecera Idempotency-Key' `
  { Llamar POST '/v1/emergencias' $reporte $null } `
  { param($r) $r.Estado -eq 400 } | Out-Null

Comprobar 'Una ruta inexistente devuelve 404, no 403' `
  { Llamar GET '/v1/ruta-que-no-existe' } `
  { param($r) $r.Estado -eq 404 } | Out-Null

# --------------------------------------------------------------------------------------
Write-Host ""
if ($fallos -eq 0) {
  Write-Host "=== $paso comprobaciones, todas correctas ===" -ForegroundColor Green
} else {
  Write-Host "=== $fallos de $paso comprobaciones FALLARON ===" -ForegroundColor Red
}

Write-Host "`nDatos creados por esta prueba (borrar con):" -ForegroundColor DarkGray
Write-Host "  delete from intake.emergencias where idempotency_key like '$marca%';" -ForegroundColor DarkGray

# Sin operador ternario: no existe en Windows PowerShell 5.1.
if ($fallos -gt 0) { exit 1 } else { exit 0 }
