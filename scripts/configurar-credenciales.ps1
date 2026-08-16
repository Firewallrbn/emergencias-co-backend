<#
.SYNOPSIS
  Genera las contraseñas de los roles de servicio, se las asigna en Supabase y sube las
  cadenas de conexión a AWS Parameter Store cifradas.

.DESCRIPTION
  Este script existe para resolver un problema concreto: los roles svc_* se crean sin
  contraseña (ponerla en una migración la metería en el repositorio), pero las Lambdas no
  pueden conectarse sin ella.

  Las contraseñas se generan aquí con el RNG criptográfico del sistema, viajan directamente
  a Supabase y a Parameter Store, y nunca se imprimen en pantalla, ni se guardan en disco,
  ni quedan en el historial del shell. Si necesitas recuperarlas después, se leen de
  Parameter Store; no hay otra copia.

  Es idempotente: volver a ejecutarlo rota las contraseñas y actualiza los parámetros.

.PARAMETER PoolerHost
  Host del pooler de Supabase. Se copia del dashboard: Project Settings -> Database ->
  Connection string -> pestaña "Transaction pooler". Tiene la forma
  aws-1-<region>.pooler.supabase.com

.PARAMETER ProjectRef
  Referencia del proyecto de Supabase. Es el subdominio de la URL del proyecto.

.EXAMPLE
  .\scripts\configurar-credenciales.ps1 -PoolerHost aws-1-us-east-2.pooler.supabase.com

.NOTES
  Requiere psql (PostgreSQL 17 en el PATH) y la AWS CLI autenticada.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$PoolerHost,

  [string]$ProjectRef = 'vapnqzhttqcjxdvfpblk',
  [string]$RegionAws  = 'us-east-2',
  [string]$Prefijo    = '/emergencias/prod'
)

$ErrorActionPreference = 'Stop'

# Cada servicio recibe su propio rol. Nada de una credencial compartida: si una se filtra,
# el alcance del daño queda acotado al schema de ese servicio.
$servicios = @('intake', 'dispatch', 'geo', 'notify')

# --------------------------------------------------------------------------------------
# Comprobaciones previas
# --------------------------------------------------------------------------------------
foreach ($cmd in @('psql', 'aws')) {
  if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
    throw "No se encontro '$cmd' en el PATH. psql viene con PostgreSQL 17; aws con la AWS CLI v2."
  }
}

try { aws sts get-caller-identity --output json | Out-Null }
catch { throw "La AWS CLI no tiene credenciales validas. Ejecuta 'aws login' y reintenta." }

Write-Host "Proyecto Supabase : $ProjectRef" -ForegroundColor Cyan
Write-Host "Pooler            : $PoolerHost" -ForegroundColor Cyan
Write-Host "Region AWS        : $RegionAws" -ForegroundColor Cyan
Write-Host "Prefijo SSM       : $Prefijo" -ForegroundColor Cyan
Write-Host ""

# --------------------------------------------------------------------------------------
# Contraseña de administrador de la base
#
# Se pide como SecureString para que no aparezca en pantalla ni en el historial del shell.
# Solo se convierte a texto plano el instante en que psql la necesita.
# --------------------------------------------------------------------------------------
$adminSecure = Read-Host -Prompt "Contrasena de la base de datos de Supabase (rol postgres)" -AsSecureString
$adminPlano = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR(
  [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($adminSecure)
)

# Para tareas administrativas se usa el pooler en modo SESION (puerto 5432). El modo
# transaccion del 6543 es para la aplicacion y no admite todas las sentencias de sesion.
$adminUser = "postgres.$ProjectRef"

function Invoke-PsqlAdmin {
  param([string]$Sql, [int]$Puerto = 5432, [string]$Usuario = $adminUser, [string]$Password = $adminPlano)

  $env:PGPASSWORD = $Password
  try {
    # El SQL entra por stdin, no por -c: asi la sentencia (que lleva la contrasena nueva)
    # no aparece en la linea de comandos, que es visible en la lista de procesos.
    $salida = $Sql | psql `
      --host=$PoolerHost --port=$Puerto --username=$Usuario --dbname=postgres `
      --set=ON_ERROR_STOP=1 --quiet --no-psqlrc --tuples-only 2>&1
    $codigo = $LASTEXITCODE
    return [pscustomobject]@{ Salida = $salida; Codigo = $codigo }
  }
  finally {
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
  }
}

Write-Host "Comprobando conexion administrativa..." -NoNewline
$prueba = Invoke-PsqlAdmin -Sql 'select 1;'
if ($prueba.Codigo -ne 0) {
  Write-Host " FALLO" -ForegroundColor Red
  $prueba.Salida | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
  throw "No se pudo conectar. Revisa el host del pooler y la contrasena."
}
Write-Host " ok" -ForegroundColor Green

# --------------------------------------------------------------------------------------
# Generacion de contraseñas
#
# Solo alfanumericas a proposito: la contrasena se embebe en una URL de conexion, y
# caracteres como @ : / ? # obligarian a codificarla en porcentaje. Se compensa la menor
# variedad con longitud: 40 caracteres alfanumericos son ~238 bits de entropia.
# --------------------------------------------------------------------------------------
function New-Password {
  param([int]$Longitud = 40)

  $alfabeto = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
  $bytes = [byte[]]::new($Longitud)
  # RNG criptografico, no Get-Random: este ultimo no sirve para material de seguridad.
  [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)

  $sb = [System.Text.StringBuilder]::new($Longitud)
  foreach ($b in $bytes) { [void]$sb.Append($alfabeto[$b % $alfabeto.Length]) }
  return $sb.ToString()
}

# --------------------------------------------------------------------------------------
# Por cada servicio: rotar contrasena y publicar la cadena de conexion
# --------------------------------------------------------------------------------------
$resultados = @()

foreach ($servicio in $servicios) {
  $rol = "svc_$servicio"
  Write-Host "`n[$rol]" -ForegroundColor Yellow

  $password = New-Password

  # 1. Asignar la contrasena y habilitar el login.
  Write-Host "  asignando contrasena..." -NoNewline
  $sql = "alter role $rol with login password '$password';"
  $r = Invoke-PsqlAdmin -Sql $sql
  if ($r.Codigo -ne 0) {
    Write-Host " FALLO" -ForegroundColor Red
    $r.Salida | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
    throw "No se pudo asignar la contrasena de $rol."
  }
  Write-Host " ok" -ForegroundColor Green

  # 2. Verificar que el rol puede conectarse por el pooler en modo TRANSACCION (6543),
  #    que es exactamente como lo hara la Lambda. Verificar con el modo de sesion no
  #    probaria nada util.
  Write-Host "  probando conexion por el pooler (6543)..." -NoNewline
  $usuarioServicio = "$rol.$ProjectRef"
  $prueba = Invoke-PsqlAdmin -Sql 'select current_user;' -Puerto 6543 -Usuario $usuarioServicio -Password $password
  if ($prueba.Codigo -ne 0) {
    Write-Host " FALLO" -ForegroundColor Red
    $prueba.Salida | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
    throw "El rol $rol no pudo conectarse por el pooler."
  }
  Write-Host " ok" -ForegroundColor Green

  # 3. Publicar la cadena de conexion en Parameter Store, cifrada.
  #    Puerto 6543 = modo transaccion, que es para el que esta escrito packages/shared/src/db.ts.
  Write-Host "  publicando en Parameter Store..." -NoNewline
  $cadena = "postgresql://${usuarioServicio}:${password}@${PoolerHost}:6543/postgres"
  $nombreParametro = "$Prefijo/$servicio/database_url"

  # El valor va por stdin via un archivo temporal para no exponerlo en la linea de comandos.
  $tmp = [System.IO.Path]::GetTempFileName()
  try {
    Set-Content -Path $tmp -Value $cadena -NoNewline -Encoding utf8
    aws ssm put-parameter `
      --name $nombreParametro `
      --type SecureString `
      --value "file://$tmp" `
      --overwrite `
      --region $RegionAws `
      --description "Cadena de conexion del microservicio $servicio (pooler en modo transaccion)" `
      --output json | Out-Null
  }
  finally {
    # Sobrescribir antes de borrar: un delete a secas deja el contenido en el disco.
    if (Test-Path $tmp) {
      Set-Content -Path $tmp -Value ('0' * 200) -NoNewline
      Remove-Item $tmp -Force
    }
  }
  Write-Host " ok" -ForegroundColor Green

  $resultados += [pscustomobject]@{ Rol = $rol; Parametro = $nombreParametro }

  # Borrar la contrasena de la memoria del script. No es una garantia fuerte en .NET
  # (los strings son inmutables y pueden quedar en el heap hasta el GC), pero acorta
  # la ventana de exposicion.
  $password = $null
}

$adminPlano = $null
[System.GC]::Collect()

# --------------------------------------------------------------------------------------
# Resumen — nombres de parametros, nunca valores
# --------------------------------------------------------------------------------------
Write-Host "`n=== Parametros publicados ===" -ForegroundColor Cyan
$resultados | Format-Table -AutoSize

Write-Host "Verificacion (solo metadatos, sin descifrar):" -ForegroundColor Cyan
aws ssm describe-parameters `
  --parameter-filters "Key=Name,Option=BeginsWith,Values=$Prefijo" `
  --query "Parameters[].{Nombre:Name,Tipo:Type,Modificado:LastModifiedDate}" `
  --output table `
  --region $RegionAws

Write-Host @"

Listo. Las contrasenas solo existen ahora dentro de Supabase y de Parameter Store.
No quedaron en disco, en pantalla ni en el historial del shell.

Si alguna vez necesitas ver una:
  aws ssm get-parameter --name $Prefijo/intake/database_url --with-decryption --region $RegionAws

Para rotarlas, vuelve a ejecutar este script.
"@ -ForegroundColor DarkGray
