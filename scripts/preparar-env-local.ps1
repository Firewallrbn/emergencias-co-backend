<#
.SYNOPSIS
  Materializa el .env que necesita docker compose, leyendo las cadenas de conexion de
  AWS Parameter Store.

.DESCRIPTION
  El compose por defecto apunta a Supabase, que es la fuente de la verdad del sistema.
  Para conectarse hacen falta las cuatro cadenas de conexion, y esas viven cifradas en
  Parameter Store bajo /emergencias/prod/<servicio>/database_url — nunca en el repositorio.

  Este script las descarga y escribe un .env local. Es el unico punto donde los secretos
  tocan el disco de la maquina de desarrollo, y .gitignore lo excluye.

  Se ejecuta una vez por clon, o de nuevo despues de rotar credenciales con
  scripts/configurar-credenciales.ps1.

.PARAMETER Forzar
  Sobrescribe un .env existente sin preguntar.

.EXAMPLE
  .\scripts\preparar-env-local.ps1
  .\scripts\preparar-env-local.ps1 -Forzar

.NOTES
  Requiere la AWS CLI v2 autenticada con permiso de lectura sobre el prefijo.
#>
[CmdletBinding()]
param(
  [switch]$Forzar,
  [string]$RegionAws = 'us-east-2',
  [string]$Prefijo   = '/emergencias/prod'
)

$ErrorActionPreference = 'Stop'

$raiz = Split-Path -Parent $PSScriptRoot
$destino = Join-Path $raiz '.env'

$servicios = @('intake', 'dispatch', 'geo', 'notify')

# --------------------------------------------------------------------------------------
# Comprobaciones previas
# --------------------------------------------------------------------------------------
if (-not (Get-Command 'aws' -ErrorAction SilentlyContinue)) {
  throw "No se encontro 'aws' en el PATH. Instala la AWS CLI v2."
}

try { aws sts get-caller-identity --output json | Out-Null }
catch { throw "La AWS CLI no tiene credenciales validas. Ejecuta 'aws login' y reintenta." }

if ((Test-Path $destino) -and -not $Forzar) {
  $respuesta = Read-Host "Ya existe .env. Sobrescribir? (s/N)"
  if ($respuesta -notmatch '^[sS]') {
    Write-Host "Cancelado. El .env existente no se toco." -ForegroundColor DarkYellow
    return
  }
}

# --------------------------------------------------------------------------------------
# Descarga
#
# Un parametro por servicio. Se descifra en memoria y no se imprime: solo se reporta que
# se obtuvo y su longitud, que basta para diagnosticar un valor truncado sin exponerlo.
# --------------------------------------------------------------------------------------
Write-Host "Leyendo cadenas de conexion de Parameter Store ($RegionAws)..." -ForegroundColor Cyan

$lineas = New-Object System.Collections.Generic.List[string]

foreach ($servicio in $servicios) {
  $nombre = "$Prefijo/$servicio/database_url"
  Write-Host "  $nombre ..." -NoNewline

  $valor = aws ssm get-parameter `
    --name $nombre `
    --with-decryption `
    --region $RegionAws `
    --query 'Parameter.Value' `
    --output text 2>&1

  if ($LASTEXITCODE -ne 0) {
    Write-Host " FALLO" -ForegroundColor Red
    Write-Host "  $valor" -ForegroundColor Red
    throw "No se pudo leer $nombre. Ejecuta scripts/configurar-credenciales.ps1 si nunca se publico."
  }

  $valor = $valor.Trim()

  # Una cadena que no empieza por postgresql:// es casi siempre un parametro con BOM o un
  # mensaje de error que la CLI devolvio con codigo 0. Mejor detenerse aqui que dejar que
  # docker falle luego con un error de host que no apunta a la causa.
  if ($valor -notmatch '^postgresql://') {
    throw "El valor de $nombre no parece una cadena de conexion. Revisalo en Parameter Store."
  }

  Write-Host " ok ($($valor.Length) caracteres)" -ForegroundColor Green

  $lineas.Add("DATABASE_URL_$($servicio.ToUpperInvariant())=$valor")
}

# --------------------------------------------------------------------------------------
# Escritura
#
# UTF-8 SIN BOM, escrito con .NET en vez de Set-Content. En Windows PowerShell 5.1,
# `Set-Content -Encoding utf8` antepone el BOM (EF BB BF), y esos tres bytes acabarian
# dentro del nombre de la primera variable: docker compose no la reconoceria.
# --------------------------------------------------------------------------------------
$cabecera = @(
  '# Generado por scripts/preparar-env-local.ps1 — NO se versiona, NO se comparte.'
  "# Origen: AWS Parameter Store $Prefijo/<servicio>/database_url"
  "# Generado: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
  '#'
  '# Para rotar estas credenciales: scripts/configurar-credenciales.ps1, y despues'
  '# volver a ejecutar este script.'
  ''
)

$contenido = (($cabecera + $lineas) -join "`n") + "`n"
[System.IO.File]::WriteAllText($destino, $contenido, (New-Object System.Text.UTF8Encoding($false)))

# Ultima linea de defensa: si alguien rompiera .gitignore, este aviso lo delata antes del
# commit. Se comprueba de verdad en vez de confiar en que la regla sigue ahi.
$ignorado = & git -C $raiz check-ignore .env 2>$null
if (-not $ignorado) {
  Write-Warning "ATENCION: .env NO esta siendo ignorado por git. Revisa .gitignore ANTES de hacer commit."
}

Write-Host ""
Write-Host "Escrito $destino con $($lineas.Count) cadenas de conexion." -ForegroundColor Green
Write-Host ""
Write-Host "Ya puedes levantar el sistema contra Supabase:" -ForegroundColor Cyan
Write-Host "  docker compose up --build"
Write-Host "  curl http://localhost:8080/v1/health"
