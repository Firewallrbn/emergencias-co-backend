<#
.SYNOPSIS
  Construye y despliega un microservicio con SAM.

.DESCRIPTION
  Cada servicio es un stack independiente, con su propio ciclo de vida. Este script hace
  el bundle con esbuild y ejecuta `sam deploy` contra el stack correspondiente.

  Absorbe dos fricciones conocidas de esta maquina para que no haya que recordarlas:

  1. `sam` y `psql` se anadieron al PATH despues de instalarlos, asi que una terminal
     abierta desde antes no los ve. Se busca la ruta de instalacion como respaldo.

  2. El Python embebido de la SAM CLI carga el site-packages del usuario, donde hay un
     `typing_extensions` viejo que tapa al suyo y rompe el arranque con
     "cannot import name 'Sentinel'". Se evita con PYTHONNOUSERSITE=1.

.PARAMETER Servicio
  intake | dispatch | geo | notify

.EXAMPLE
  .\scripts\desplegar-servicio.ps1 intake
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [ValidateSet('intake', 'dispatch', 'geo', 'notify')]
  [string]$Servicio,

  [string]$RegionAws = 'us-east-2',
  [switch]$SoloConstruir,

  # Pares Clave=Valor para sam deploy --parameter-overrides.
  [string[]]$Parametros = @(),

  # Construye la variante con el fallo sintetico inyectado, para la prueba de rollback.
  # Cambia el bundle de verdad, que es lo unico que hace publicar una version nueva a SAM
  # y por tanto lo unico que arranca el canary.
  [switch]$Caos
)

$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot

# --- sam, aunque no este en el PATH de esta terminal ------------------------------------
$cmdSam = Get-Command 'sam' -ErrorAction SilentlyContinue
$sam = if ($cmdSam) { $cmdSam.Source } else { 'C:\Program Files\Amazon\AWSSAMCLI\bin\sam.cmd' }
if (-not (Test-Path $sam)) { throw "No se encontro la SAM CLI. Instalala o anadela al PATH." }

# Impide que el site-packages del usuario tape las dependencias embebidas de SAM.
$env:PYTHONNOUSERSITE = '1'

Write-Host "== $Servicio ==" -ForegroundColor Cyan

# --- 1. Bundle ---------------------------------------------------------------------------
$tareaBuild = if ($Caos) { 'build:caos' } else { 'build' }
if ($Caos) {
  Write-Host "MODO CAOS: se inyecta un fallo sintetico. Esta version DEBE ser revertida." -ForegroundColor Red
}
Write-Host "Construyendo el bundle ($tareaBuild)..." -ForegroundColor Cyan
Push-Location $raiz
try {
  npm run $tareaBuild --workspace "@emergencias/$Servicio"
  if ($LASTEXITCODE -ne 0) { throw "Fallo el build de $Servicio." }
}
finally { Pop-Location }

$artefacto = Join-Path $raiz "services/$Servicio/dist/index.js"
if (-not (Test-Path $artefacto)) { throw "No se genero $artefacto." }
$kb = [math]::Round((Get-Item $artefacto).Length / 1KB, 1)
Write-Host "Artefacto: $kb KB" -ForegroundColor Green

if ($SoloConstruir) { Write-Host "Solo construir: no se despliega." -ForegroundColor DarkGray; return }

# --- 2. Despliegue -----------------------------------------------------------------------
$stack = "emergencias-$Servicio"
Write-Host "Desplegando el stack $stack..." -ForegroundColor Cyan

# No usar $args: es una variable automatica de PowerShell y reutilizarla trae sorpresas.
$argumentos = @(
  'deploy'
  '--template-file', 'template.yaml'
  '--stack-name', $stack
  '--region', $RegionAws
  '--capabilities', 'CAPABILITY_NAMED_IAM'
  '--resolve-s3'
  '--no-confirm-changeset'
  '--no-fail-on-empty-changeset'
)
if ($Parametros.Count -gt 0) {
  Write-Host "Parametros: $($Parametros -join ' ')" -ForegroundColor DarkYellow
  $argumentos += '--parameter-overrides'
  $argumentos += $Parametros
}

Push-Location (Join-Path $raiz "services/$Servicio")
try {
  & $sam @argumentos
  if ($LASTEXITCODE -ne 0) { throw "Fallo el despliegue de $stack." }
}
finally { Pop-Location }

# --- 3. Resultado ------------------------------------------------------------------------
Write-Host "`nSalidas del stack:" -ForegroundColor Cyan
aws cloudformation describe-stacks `
  --stack-name $stack `
  --region $RegionAws `
  --query "Stacks[0].Outputs[].{Clave:OutputKey,Valor:OutputValue}" `
  --output table

Write-Host "Listo." -ForegroundColor Green
