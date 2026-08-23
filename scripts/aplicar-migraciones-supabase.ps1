<#
.SYNOPSIS
  Aplica todas las migraciones y (opcionalmente) el seed contra el proyecto de Supabase.

.DESCRIPTION
  Hasta ahora esto se hacia a mano, archivo por archivo, pegando SQL en el editor de
  Supabase. Funciona hasta que alguien anade una migracion nueva y se olvida de aplicarla:
  el repositorio y la base se desincronizan en silencio, y el sintoma aparece mucho
  despues, en el frontend, como una columna que no existe.

  Este script recorre db/migrations/*.sql en orden y las aplica todas. Son idempotentes por
  diseno, asi que volver a ejecutarlo es seguro y es justamente como se usa: se corre
  entero cada vez y las ya aplicadas no cambian nada.

  Se conecta por el pooler en modo SESION (puerto 5432), no por el de transaccion. El modo
  transaccion es para la aplicacion y no admite todas las sentencias que necesita una
  migracion.

  db/local-test/ NO se aplica nunca aqui: son stubs que replican en un Postgres pelado lo
  que Supabase ya provisiona por su cuenta. Aplicarlos en Supabase pisaria objetos reales.

.PARAMETER ConSeed
  Aplica tambien db/seed/*.sql. El seed es idempotente pero inserta datos de demostracion:
  se pide explicitamente para no sembrarlos por accidente sobre datos reales.

.PARAMETER SoloVerificar
  No aplica nada; solo ejecuta las comprobaciones finales contra el estado actual.

.PARAMETER PoolerHost
  Host del pooler de Supabase. Project Settings -> Database -> Connection string ->
  pestana "Session pooler".

.PARAMETER ProjectRef
  Referencia del proyecto de Supabase (el subdominio de la URL del proyecto).

.EXAMPLE
  .\scripts\aplicar-migraciones-supabase.ps1
  .\scripts\aplicar-migraciones-supabase.ps1 -ConSeed
  .\scripts\aplicar-migraciones-supabase.ps1 -SoloVerificar

.NOTES
  Requiere psql (PostgreSQL 17). Pide la contrasena del rol postgres de Supabase, que no
  se guarda en ningun sitio: se lee como SecureString y solo se convierte a texto el
  instante en que psql la necesita.

  Antes de tocar Supabase conviene validar contra un PostGIS limpio:
    .\scripts\validar-migraciones.ps1
#>
[CmdletBinding()]
param(
  [switch]$ConSeed,
  [switch]$SoloVerificar,

  # El proyecto vive en ca-central-1, no en la region de AWS donde corren las Lambdas.
  [string]$PoolerHost = 'aws-0-ca-central-1.pooler.supabase.com',
  [string]$ProjectRef = 'vapnqzhttqcjxdvfpblk',
  [int]$Puerto = 5432
)

$ErrorActionPreference = 'Stop'

$raiz = Split-Path -Parent $PSScriptRoot
$db = Join-Path $raiz 'db'

# --------------------------------------------------------------------------------------
# psql
#
# Se anadio al PATH de usuario despues de instalarlo, asi que una terminal abierta desde
# antes no lo ve. En vez de fallar por algo tan tonto, se recurre a la ruta conocida.
# --------------------------------------------------------------------------------------
$cmdPsql = Get-Command 'psql' -ErrorAction SilentlyContinue
$psql = if ($cmdPsql) { $cmdPsql.Source } else { $null }
if (-not $psql) {
  $rutaConocida = 'C:\Program Files\PostgreSQL\17\bin\psql.exe'
  if (Test-Path $rutaConocida) {
    $psql = $rutaConocida
    Write-Host "psql no esta en el PATH de esta terminal; usando $rutaConocida" -ForegroundColor DarkYellow
  } else {
    throw "No se encontro psql. Viene con PostgreSQL 17; anade su carpeta bin al PATH."
  }
}

$usuario = "postgres.$ProjectRef"

Write-Host "Proyecto Supabase : $ProjectRef" -ForegroundColor Cyan
Write-Host "Pooler (sesion)   : ${PoolerHost}:${Puerto}" -ForegroundColor Cyan
Write-Host ""

$adminSecure = Read-Host -Prompt "Contrasena de la base de datos de Supabase (rol postgres)" -AsSecureString
$adminPlano = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR(
  [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($adminSecure)
)

function Invoke-Psql {
  param([string]$Archivo, [string]$Sql, [switch]$Silencioso)

  $env:PGPASSWORD = $adminPlano
  try {
    $comunes = @(
      "--host=$PoolerHost", "--port=$Puerto", "--username=$usuario", '--dbname=postgres',
      '--set=ON_ERROR_STOP=1', '--no-psqlrc', '--quiet'
    )
    if ($Silencioso) { $comunes += '--tuples-only' }

    if ($Archivo) { $salida = & $psql @comunes --file=$Archivo 2>&1 }
    else          { $salida = $Sql | & $psql @comunes 2>&1 }

    return [pscustomobject]@{ Salida = $salida; Codigo = $LASTEXITCODE }
  }
  finally {
    # Asignar $null en vez de Remove-Item: mismo efecto y no depende de la unidad Env:.
    $env:PGPASSWORD = $null
  }
}

Write-Host "Comprobando conexion..." -NoNewline
$prueba = Invoke-Psql -Sql 'select 1;' -Silencioso
if ($prueba.Codigo -ne 0) {
  Write-Host " FALLO" -ForegroundColor Red
  $prueba.Salida | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
  throw "No se pudo conectar. Revisa el host del pooler y la contrasena."
}
Write-Host " ok" -ForegroundColor Green

# --------------------------------------------------------------------------------------
# Aplicacion
# --------------------------------------------------------------------------------------
if (-not $SoloVerificar) {
  # Orden alfabetico = orden numerico, porque los nombres van con prefijo de tres digitos.
  # Si algun dia hay mas de 999 migraciones, este es el menor de los problemas.
  $archivos = @(Get-ChildItem -Path (Join-Path $db 'migrations') -Filter '*.sql' | Sort-Object Name)

  if ($ConSeed) {
    $archivos += @(Get-ChildItem -Path (Join-Path $db 'seed') -Filter '*.sql' | Sort-Object Name)
  }

  Write-Host "`n=== Aplicando $($archivos.Count) archivos ===" -ForegroundColor Cyan

  foreach ($archivo in $archivos) {
    $etiqueta = if ($archivo.DirectoryName -like '*seed*') { "seed $($archivo.Name)" } else { $archivo.Name }
    Write-Host ("  {0,-52}" -f $etiqueta) -NoNewline

    $r = Invoke-Psql -Archivo $archivo.FullName
    if ($r.Codigo -ne 0) {
      Write-Host " FALLO" -ForegroundColor Red
      $r.Salida | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
      throw "Fallo al aplicar $($archivo.Name). Nada posterior se aplico."
    }

    # 007_realtime.sql avisa de wal_level en un Postgres pelado; en Supabase no deberia
    # salir, pero si alguna migracion emite avisos conviene verlos sin que parezcan errores.
    $avisos = @($r.Salida | Where-Object { "$_" -match 'WARNING|NOTICE' })
    if ($avisos.Count -gt 0) {
      Write-Host " ok (con avisos)" -ForegroundColor DarkYellow
      $avisos | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    } else {
      Write-Host " ok" -ForegroundColor Green
    }
  }
}

# --------------------------------------------------------------------------------------
# Verificacion
#
# No basta con que psql termine en 0: se comprueba que el estado final sea el que la
# rubrica exige y que la ultima migracion realmente dejo su rastro.
# --------------------------------------------------------------------------------------
Write-Host "`n=== Verificacion ===" -ForegroundColor Cyan

$comprobaciones = @(
  @{
    Nombre = 'Migraciones aplicadas (schemas del dominio)'
    Sql    = "select count(*) from information_schema.schemata where schema_name in ('comun','intake','dispatch','geo','notify');"
    Espera = '5'
  },
  @{
    Nombre = 'Vista publica v_emergencias existe'
    Sql    = "select count(*) from pg_views where schemaname = 'public' and viewname = 'v_emergencias';"
    Espera = '1'
  },
  @{
    # Esta es la que delata si la migracion 010 falta: la vista existe desde la 009, pero
    # sin estas cuatro columnas el panel de comando no puede pintar el popup ni despachar.
    Nombre = 'Columnas de la migracion 010 (datos, contacto, estado_despacho, despacho_id)'
    Sql    = "select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'v_emergencias' and column_name in ('datos','contacto','estado_despacho','despacho_id');"
    Espera = '4'
  },
  @{
    Nombre = 'Roles de servicio creados'
    Sql    = "select count(*) from pg_roles where rolname in ('svc_intake','svc_dispatch','svc_geo','svc_notify');"
    Espera = '4'
  },
  @{
    Nombre = 'Ningun rol de servicio con BYPASSRLS'
    Sql    = "select count(*) from pg_roles where rolname like 'svc\_%' and rolbypassrls;"
    Espera = '0'
  },
  @{
    Nombre = 'Cobertura del dominio (16 combinaciones tipo x ciudad)'
    Sql    = 'select count(distinct (tipo, ciudad)) from intake.emergencias;'
    Espera = '16'
  }
)

$fallos = 0

foreach ($c in $comprobaciones) {
  Write-Host ("  {0,-62}" -f $c.Nombre) -NoNewline
  $r = Invoke-Psql -Sql $c.Sql -Silencioso

  if ($r.Codigo -ne 0) {
    Write-Host " ERROR" -ForegroundColor Red
    $r.Salida | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
    $fallos++
    continue
  }

  $valor = ("$($r.Salida)").Trim()
  if ($valor -eq $c.Espera) {
    Write-Host " ok ($valor)" -ForegroundColor Green
  } else {
    Write-Host " FALLO (esperado $($c.Espera), obtenido '$valor')" -ForegroundColor Red
    $fallos++
  }
}

$adminPlano = $null
[System.GC]::Collect()

Write-Host ""
if ($fallos -gt 0) {
  # La cobertura del dominio falla legitimamente si nunca se aplico el seed: se dice, en
  # vez de dejar al lector adivinando cual de las seis comprobaciones era.
  Write-Host "$fallos comprobacion(es) fallaron." -ForegroundColor Red
  Write-Host "Si la que fallo es la cobertura del dominio, vuelve a correr con -ConSeed." -ForegroundColor DarkYellow
  exit 1
}

Write-Host "Base de datos al dia. Las $($comprobaciones.Count) comprobaciones pasan." -ForegroundColor Green
Write-Host ""
Write-Host "Siguiente paso, si vas a levantar los contenedores en local:" -ForegroundColor Cyan
Write-Host "  .\scripts\preparar-env-local.ps1"
Write-Host "  docker compose up --build"
