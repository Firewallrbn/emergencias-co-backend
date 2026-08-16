<#
.SYNOPSIS
  Valida las migraciones contra un PostGIS limpio en Docker, sin tocar Supabase.

.DESCRIPTION
  Levanta un contenedor postgis/postgis:17-3.5, replica el layout de Supabase (PostGIS en
  el schema `extensions`, schema `auth`, roles `anon` y `authenticated`) y aplica en orden
  los stubs, las migraciones y el seed.

  Sirve para no gastar el proyecto de Supabase en ensayo y error: un error de sintaxis, un
  grant que falta o una política mal escrita se detectan aquí en segundos.

.PARAMETER Conservar
  No elimina el contenedor al terminar, para poder inspeccionarlo con psql.

.EXAMPLE
  .\scripts\validar-migraciones.ps1
  .\scripts\validar-migraciones.ps1 -Conservar
#>
[CmdletBinding()]
param(
  [switch]$Conservar,
  [string]$Contenedor = 'emergencias-pg-test',
  [int]$Puerto = 55432
)

$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot
$db = Join-Path $raiz 'db'

$archivos = @(
  'local-test/000_stubs_supabase.sql'
  'migrations/001_extensiones_y_schemas.sql'
  'migrations/002_roles_y_permisos.sql'
  'migrations/003_intake.sql'
  'migrations/004_dispatch.sql'
  'migrations/005_geo.sql'
  'migrations/006_notify.sql'
  'migrations/007_realtime.sql'
  'migrations/008_endurecer_rls_auto_enable.sql'
  'migrations/009_vistas_publicas_para_api.sql'
  'seed/001_unidades.sql'
  'seed/002_emergencias_demo.sql'
)

function Invoke-Psql {
  param([string]$Sql)
  $Sql | docker exec -i $Contenedor psql -U postgres -v ON_ERROR_STOP=1 -q 2>&1
}

Write-Host "Recreando contenedor $Contenedor..." -ForegroundColor Cyan
docker rm -f $Contenedor 2>&1 | Out-Null
docker run -d --name $Contenedor -e POSTGRES_PASSWORD=pruebalocal -p "${Puerto}:5432" postgis/postgis:17-3.5 2>&1 | Out-Null

# Esperar bien es la parte delicada. Durante la inicialización, la imagen arranca un
# Postgres TEMPORAL en un socket local que ya responde a `pg_isready` e incluso a consultas
# reales — y acto seguido lo apaga para reiniciar con la configuración definitiva. Conectarse
# a ese servidor temporal da falsos verdes y luego "container is not running".
#
# El único marcador fiable es la línea que la imagen imprime al terminar el init; solo
# después de verla tiene sentido probar una consulta.
$intentos = 0
$initListo = $false
while (-not $initListo -and $intentos -lt 60) {
  Start-Sleep -Seconds 2
  $intentos++
  $logs = docker logs $Contenedor 2>&1 | Out-String
  $initListo = $logs -match 'PostgreSQL init process complete'
}

if (-not $initListo) {
  docker logs $Contenedor 2>&1 | Select-Object -Last 20
  throw "La inicializacion de Postgres no termino tras $intentos intentos."
}

$listo = $false
while (-not $listo -and $intentos -lt 90) {
  Start-Sleep -Seconds 2
  $intentos++
  docker exec $Contenedor psql -U postgres -tAc 'select 1' 2>&1 | Out-Null
  $listo = ($LASTEXITCODE -eq 0)
}

if (-not $listo) {
  throw "El contenedor no acepto consultas tras $intentos intentos."
}
Write-Host "Postgres listo tras $intentos intentos." -ForegroundColor DarkGray

$fallos = 0
foreach ($archivo in $archivos) {
  $ruta = Join-Path $db $archivo
  $salida = Get-Content $ruta -Raw | docker exec -i $Contenedor psql -U postgres -v ON_ERROR_STOP=1 -q 2>&1

  if ($LASTEXITCODE -ne 0) {
    Write-Host "FALLO  $archivo" -ForegroundColor Red
    $salida | Select-Object -First 10 | ForEach-Object { Write-Host "       $_" -ForegroundColor Red }
    $fallos++
    break
  }

  # Los NOTICE de "already exists, skipping" son la prueba de que es idempotente, no ruido a reportar.
  $relevante = $salida | Where-Object { $_ -notmatch 'already exists, skipping' -and $_ -notmatch '^\s*$' }
  $sufijo = if ($relevante) { "  | $($relevante -join ' ')" } else { '' }
  Write-Host "OK     $archivo$sufijo" -ForegroundColor Green
}

if ($fallos -eq 0) {
  Write-Host "`n--- Verificaciones de contenido ---" -ForegroundColor Cyan

  Write-Host "`nCobertura tipo x ciudad (la rubrica exige 16):"
  Invoke-Psql "select count(distinct (tipo, ciudad)) as combinaciones from intake.emergencias;"

  Write-Host "`nEmergencias por ciudad:"
  Invoke-Psql "select ciudad, count(*) from intake.emergencias group by ciudad order by ciudad;"

  # `pg_tables` expone rowsecurity pero no el flag FORCE; ese vive en pg_class.
  Write-Host "`nRLS activa y forzada en todas las tablas (ambas deben ser t):"
  Invoke-Psql @"
select n.nspname || '.' || c.relname as tabla,
       c.relrowsecurity as rls,
       c.relforcerowsecurity as forzada
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname in ('intake','dispatch','geo','notify')
  and c.relkind = 'r'
order by 1;
"@

  Write-Host "`nPoliticas RLS definidas:"
  Invoke-Psql "select schemaname || '.' || tablename as tabla, policyname, cmd from pg_policies where schemaname in ('intake','dispatch','geo','notify') order by 1, 2;"

  Write-Host "`nNingun rol de servicio puede saltarse RLS (bypassrls debe ser false):"
  Invoke-Psql "select rolname, rolbypassrls, rolsuper from pg_roles where rolname like 'svc\_%' order by rolname;"

  Write-Host "`nProximidad: unidad mas cercana a un reporte P1 de Cali"
  Invoke-Psql @"
select u.codigo, u.organismo, d.distancia_m
from intake.emergencias e
cross join lateral dispatch.unidad_mas_cercana(e.geom, e.ciudad) d
join dispatch.unidades u on u.id = d.unidad_id
where e.idempotency_key = 'seed-cal-usar-1';
"@

  Write-Host "`nClustering DBSCAN en Cali (debe detectar el racimo P1):"
  Invoke-Psql "select densidad, prioridad_max, radio_m from geo.calcular_clusters('cali');"

  Write-Host "`nTablas publicadas en Realtime:"
  Invoke-Psql "select schemaname || '.' || tablename from pg_publication_tables where pubname = 'supabase_realtime' order by 1;"
}

if (-not $Conservar) {
  docker rm -f $Contenedor 2>&1 | Out-Null
  Write-Host "`nContenedor eliminado." -ForegroundColor DarkGray
} else {
  Write-Host "`nContenedor conservado. Conecta con:" -ForegroundColor DarkGray
  Write-Host "  docker exec -it $Contenedor psql -U postgres" -ForegroundColor DarkGray
}

if ($fallos -gt 0) { exit 1 }
Write-Host "`n=== VALIDACION COMPLETA ===" -ForegroundColor Green
