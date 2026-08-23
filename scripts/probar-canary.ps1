<#
.SYNOPSIS
  Prueba de extremo a extremo del despliegue progresivo canary, con evidencia automatica.

.DESCRIPTION
  Orquesta en un solo comando lo que hasta ahora se hacia en dos terminales y a mano:

    1. Toma una foto del estado previo (version del alias, alarmas, despliegues).
    2. Lanza el despliegue en segundo plano (scripts/desplegar-servicio.ps1).
    3. Mientras CodeDeploy reparte el trafico, cada tick:
         - envia peticiones reales a /v1/health y cuenta que version responde,
         - lee los pesos de reparto del alias (plano de control),
         - lee el estado de las alarmas y del despliegue de CodeDeploy.
    4. Detecta si el canary se PROMOVIO o si se REVIRTIO solo.
    5. Escribe la evidencia en docs/evidencias/ con cronologia y salidas crudas.

  Medir a la vez el plano de datos (que version contesta) y el plano de control (que
  pesos tiene el alias) es lo que hace la demostracion convincente: cuando CodeDeploy
  pone el 10 %, aproximadamente 1 de cada 10 respuestas cambia de version. Y cuando
  revierte, los pesos desaparecen del alias ANTES de que dejen de verse errores, porque
  las invocaciones en vuelo terminan.

  Las peticiones van secuenciales a proposito: esta cuenta tiene un limite de 10
  ejecuciones concurrentes y las rafagas paralelas producirian throttling que enturbia
  la lectura del reparto.

.PARAMETER Servicio
  intake | dispatch | geo | notify

.PARAMETER Caos
  Despliega la variante con el fallo sintetico inyectado (npm run build:caos). Se ESPERA
  que CodeDeploy revierta. Es la prueba de resiliencia que pide el enunciado.

.PARAMETER SoloObservar
  No despliega nada: se engancha a un despliegue ya en curso (por ejemplo el que lanzo
  GitHub Actions).

.EXAMPLE
  .\scripts\probar-canary.ps1 intake
  Despliegue sano: se espera promocion al 100 %.

.EXAMPLE
  .\scripts\probar-canary.ps1 intake -Caos
  Despliegue defectuoso: se espera rollback automatico.

.EXAMPLE
  .\scripts\probar-canary.ps1 intake -SoloObservar
  Observa el canary que lanzo el CI, sin desplegar.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('intake', 'dispatch', 'geo', 'notify')]
  [string]$Servicio = 'intake',

  [switch]$Caos,
  [switch]$SoloObservar,

  [int]$PeticionesPorTick = 5,
  [int]$IntervaloS = 10,
  [int]$MinutosMaximos = 12,

  # Margen para que las alarmas de la prueba anterior vuelvan a OK antes de desplegar.
  [int]$MinutosEsperaAlarmas = 8,

  [string]$RegionAws = 'us-east-2',
  [string]$Etapa = 'prod',
  [switch]$SinEvidencia
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # sin esto Invoke-WebRequest pinta una barra que ensucia la tabla
$raiz = Split-Path -Parent $PSScriptRoot
$stack = "emergencias-$Servicio"
$funcion = "emergencias-$Servicio"
$inicioPrueba = Get-Date

# --- Utilidades ---------------------------------------------------------------------------

$script:ultimoErrorAws = ''

function Invocar-Aws {
  # Devuelve el JSON ya deserializado. Si el comando falla devuelve $null en vez de lanzar:
  # durante un rollback hay ventanas de segundos en las que un recurso todavia no existe o
  # ya no existe, y abortar la observacion por eso seria perder la prueba entera.
  #
  # El stderr no se descarta: se guarda en $script:ultimoErrorAws para que quien lance la
  # excepcion pueda mostrar el motivo real. Tragarselo convierte cualquier fallo —sesion
  # caducada, region equivocada, stack inexistente— en el mismo mensaje inutil.
  param([string[]]$Argumentos)
  $script:ultimoErrorAws = ''
  $salida = & aws @Argumentos --region $RegionAws --output json 2>&1
  $texto = ($salida | Out-String).Trim()
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($texto)) {
    $script:ultimoErrorAws = $texto
    return $null
  }
  try { return ($texto | ConvertFrom-Json) } catch { $script:ultimoErrorAws = $texto; return $null }
}

function Comprobar-Sesion {
  # Falla temprano y con el motivo concreto. Sin esto, una sesion caducada se manifiesta
  # como "no se pudo leer el stack", que manda a buscar el problema donde no esta.
  $quien = Invocar-Aws @('sts', 'get-caller-identity')
  if (-not $quien) {
    Write-Host ""
    Write-Host "  AWS respondio:" -ForegroundColor Red
    Write-Host "    $script:ultimoErrorAws" -ForegroundColor Red
    Write-Host ""
    if ($script:ultimoErrorAws -match 'session has expired|ExpiredToken|InvalidClientTokenId') {
      throw "La sesion de AWS caduco. Ejecuta 'aws login' y vuelve a lanzar el script."
    }
    throw "No hay credenciales de AWS validas en esta terminal."
  }
  Write-Host "  Identidad             : $($quien.Arn)"
}

function Escribir-Paso { param([string]$Texto) Write-Host "== $Texto" -ForegroundColor Cyan }

function Color-Estado {
  param([string]$Estado)
  if ($Estado -match 'Succeeded') { return 'Green' }
  if ($Estado -match 'Stopped|Failed') { return 'Red' }
  if ($Estado -match 'InProgress|Created|Ready|Queued') { return 'Yellow' }
  return 'DarkGray'
}

function Sumar {
  param([hashtable]$Mapa, [string]$Clave)
  if ($Mapa.ContainsKey($Clave)) { $Mapa[$Clave] = $Mapa[$Clave] + 1 } else { $Mapa[$Clave] = 1 }
}

# --- 1. Descubrimiento de recursos ---------------------------------------------------------
# Nada esta escrito a mano: todo se resuelve desde el stack. Asi el script no se rompe cuando
# CloudFormation regenera los nombres fisicos de CodeDeploy, que llevan sufijo aleatorio.

Escribir-Paso "Resolviendo recursos del stack $stack"

Comprobar-Sesion

$recursos = Invocar-Aws @('cloudformation', 'describe-stack-resources', '--stack-name', $stack)
if (-not $recursos) {
  Write-Host ""
  Write-Host "  AWS respondio:" -ForegroundColor Red
  Write-Host "    $script:ultimoErrorAws" -ForegroundColor Red
  Write-Host ""
  throw "No se pudo leer el stack $stack en la region $RegionAws."
}

$appCodeDeploy = @($recursos.StackResources |
    Where-Object { $_.ResourceType -eq 'AWS::CodeDeploy::Application' } |
    ForEach-Object { $_.PhysicalResourceId })[0]

$grupoCodeDeploy = @($recursos.StackResources |
    Where-Object { $_.ResourceType -eq 'AWS::CodeDeploy::DeploymentGroup' } |
    ForEach-Object { $_.PhysicalResourceId })[0]

if (-not $appCodeDeploy -or -not $grupoCodeDeploy) {
  throw "El stack $stack no expone recursos de CodeDeploy. Falta DeploymentPreference en la plantilla?"
}

$alarmas = @($recursos.StackResources |
    Where-Object { $_.ResourceType -eq 'AWS::CloudWatch::Alarm' } |
    ForEach-Object { $_.PhysicalResourceId })

$gateway = Invocar-Aws @('cloudformation', 'describe-stacks', '--stack-name', 'emergencias-gateway')
$urlBase = @($gateway.Stacks[0].Outputs | Where-Object { $_.OutputKey -eq 'UrlBase' } |
    ForEach-Object { $_.OutputValue })[0]
if (-not $urlBase) { throw "No se encontro la salida UrlBase en el stack emergencias-gateway." }
$urlSalud = "$urlBase/v1/health"

Write-Host "  Aplicacion CodeDeploy : $appCodeDeploy"
Write-Host "  Grupo de despliegue   : $grupoCodeDeploy"
Write-Host "  Alarmas vigilantes    : $($alarmas -join ', ')"
Write-Host "  Endpoint de sondeo    : $urlSalud"

# --- 2. Estado previo ----------------------------------------------------------------------

function Leer-Alias {
  $a = Invocar-Aws @('lambda', 'get-alias', '--function-name', $funcion, '--name', $Etapa)
  if (-not $a) { return $null }
  $pesos = @()
  if ($a.RoutingConfig -and $a.RoutingConfig.AdditionalVersionWeights) {
    foreach ($p in $a.RoutingConfig.AdditionalVersionWeights.PSObject.Properties) {
      $pesos += "v$($p.Name)=$([math]::Round([double]$p.Value * 100, 1))%"
    }
  }
  return [pscustomobject]@{ Version = $a.FunctionVersion; Pesos = $pesos }
}

$aliasInicial = Leer-Alias
if (-not $aliasInicial) { throw "No existe el alias '$Etapa' en la funcion $funcion." }

Escribir-Paso "Estado previo"
Write-Host "  Alias $Etapa -> version $($aliasInicial.Version)"
if ($aliasInicial.Pesos.Count -gt 0) {
  Write-Host "  ATENCION: el alias ya reparte trafico ($($aliasInicial.Pesos -join ' '))." -ForegroundColor Yellow
  Write-Host "  Hay un canary en curso: usa -SoloObservar o espera a que termine." -ForegroundColor Yellow
}

# Se guarda la lista COMPLETA de despliegues previos, no solo el ultimo. Es el filtro que
# permite distinguir "un despliegue de esta prueba" de "uno que ya estaba ahi". Sin el, el
# despliegue de reversion que dejo la ejecucion anterior se toma por el de esta y el bucle
# termina en el primer tick sin haber observado nada.
$listaPrevia = Invocar-Aws @('deploy', 'list-deployments',
  '--application-name', $appCodeDeploy, '--deployment-group-name', $grupoCodeDeploy, '--max-items', '20')
$idsPrevios = @()
if ($listaPrevia -and $listaPrevia.deployments) { $idsPrevios = @($listaPrevia.deployments) }
$idPrevio = 'ninguno'
if ($idsPrevios.Count -gt 0) { $idPrevio = $idsPrevios[0] }
Write-Host "  Ultimo despliegue previo : $idPrevio  ($($idsPrevios.Count) en el historial)"

# Un despliegue anterior que TODAVIA esta en curso no es historia: es justo lo que se
# quiere observar, sobre todo con -SoloObservar. Se saca del filtro para que el bucle lo
# siga. Basta con mirar el mas reciente: CodeDeploy no ejecuta dos a la vez en un grupo.
if ($idsPrevios.Count -gt 0) {
  $infoPrevio = Invocar-Aws @('deploy', 'get-deployment', '--deployment-id', $idsPrevios[0])
  if ($infoPrevio -and $infoPrevio.deploymentInfo.status -notin @('Succeeded', 'Failed', 'Stopped')) {
    Write-Host "  ATENCION: $idPrevio sigue $($infoPrevio.deploymentInfo.status). Se observara ese." -ForegroundColor Yellow
    $idsPrevios = @($idsPrevios | Select-Object -Skip 1)
    if (-not $SoloObservar) {
      throw "Hay un canary en curso ($idPrevio). Espera a que termine o usa -SoloObservar."
    }
  }
}

# --- 3. Lanzar el despliegue ---------------------------------------------------------------

function Esperar-AlarmasEnOk {
  # CodeDeploy aborta un despliegue si alguna de las alarmas que lo vigilan YA esta en
  # ALARM cuando arranca: el canary pasa a Stopped en segundos y se revierte sin haber
  # repartido nada de trafico. Es lo que ocurre al encadenar una prueba sana justo detras
  # de una de caos, porque las alarmas tardan uno o dos periodos en volver a OK.
  param([int]$MinutosEspera)
  if ($alarmas.Count -eq 0) { return }
  $limiteEspera = (Get-Date).AddMinutes($MinutosEspera)
  while ($true) {
    $est = Invocar-Aws (@('cloudwatch', 'describe-alarms', '--alarm-names') + $alarmas)
    $malas = @()
    if ($est) { $malas = @($est.MetricAlarms | Where-Object { $_.StateValue -eq 'ALARM' }) }
    if ($malas.Count -eq 0) {
      Write-Host "  Alarmas en OK: se puede desplegar." -ForegroundColor Green
      return
    }
    $nombres = ($malas | ForEach-Object { $_.AlarmName }) -join ', '
    if ((Get-Date) -ge $limiteEspera) {
      throw "Las alarmas siguen en ALARM tras $MinutosEspera min ($nombres). CodeDeploy abortaria el despliegue nada mas empezar."
    }
    Write-Host "  Esperando a que vuelvan a OK: $nombres" -ForegroundColor Yellow
    Start-Sleep -Seconds 15
  }
}

$trabajo = $null
if (-not $SoloObservar) {
  Escribir-Paso "Comprobando que las alarmas esten en OK"
  Esperar-AlarmasEnOk -MinutosEspera $MinutosEsperaAlarmas

  if ($Caos) {
    Write-Host ""
    Write-Host "  MODO CAOS: se despliega una version que falla en cada invocacion." -ForegroundColor Red
    Write-Host "  Resultado esperado: CodeDeploy detiene el canary y revierte solo." -ForegroundColor Red
  }
  Escribir-Paso "Lanzando el despliegue en segundo plano"

  # En segundo plano porque `sam deploy` bloquea hasta que CodeDeploy termina el canary
  # (unos 6 minutos). Si se esperara a que volviera, no habria nada que observar: el
  # reparto habria empezado y acabado antes de la primera peticion de sondeo.
  $rutaDespliegue = Join-Path $PSScriptRoot 'desplegar-servicio.ps1'

  # El booleano se calcula AQUI, en modo expresion, y se pasa por variable. Escribir
  # `[bool]$Caos` directamente dentro de -ArgumentList no convierte nada: la lista de
  # argumentos se analiza en modo argumento, donde eso es la cadena literal "[bool]False",
  # que al ser no vacia resulta verdadera. El efecto era desplegar siempre en modo caos.
  $modoCaos = [bool]$Caos.IsPresent

  $trabajo = Start-Job -ScriptBlock {
    param($rutaScript, $srv, $caos, $region)
    if ($caos) { & $rutaScript $srv -RegionAws $region -Caos }
    else { & $rutaScript $srv -RegionAws $region }
  } -ArgumentList $rutaDespliegue, $Servicio, $modoCaos, $RegionAws

  Write-Host "  Trabajo #$($trabajo.Id) lanzado."
  Write-Host "  El bundle y el arranque de sam deploy tardan ~1 min antes de que empiece el canary."
}
else {
  Escribir-Paso "Solo observar: no se despliega nada"
}

# --- 4. Observacion en vivo ----------------------------------------------------------------

Escribir-Paso "Observando (Ctrl+C para cortar)"
Write-Host ""
Write-Host "  hh:mm:ss  reparto observado         alias                alarmas       CodeDeploy"
Write-Host "  --------  -----------------------   ------------------   -----------   ------------------"

$historial = New-Object System.Collections.ArrayList
$conteoVersiones = @{}
$errores = 0
$totalPeticiones = 0
$limite = $inicioPrueba.AddMinutes($MinutosMaximos)
$idCanary = ''
$idRollback = ''
$vioReparto = $false

while ((Get-Date) -lt $limite) {

  # --- plano de datos: quien contesta de verdad ---
  $tick = @{}
  for ($i = 0; $i -lt $PeticionesPorTick; $i++) {
    $etiqueta = 'sin-respuesta'
    try {
      $r = Invoke-WebRequest -Uri $urlSalud -TimeoutSec 10 -UseBasicParsing `
        -Headers @{ 'Cache-Control' = 'no-cache' }
      $cuerpo = $r.Content | ConvertFrom-Json
      $etiqueta = "v$($cuerpo.version)"
    }
    catch {
      # Un 5xx llega aqui como excepcion. Es justo la senal que buscamos, no un fallo
      # del script: se etiqueta con su codigo para que aparezca en el reparto.
      $codigo = 0
      if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
        try { $codigo = [int]$_.Exception.Response.StatusCode } catch { $codigo = 0 }
      }
      if ($codigo -gt 0) { $etiqueta = "ERROR $codigo" } else { $etiqueta = 'excepcion' }
      $errores++
    }

    Sumar $tick $etiqueta
    Sumar $conteoVersiones $etiqueta
    $totalPeticiones++
  }
  # Separador 'x' y no ':' porque con 5 peticiones por tick la version 5 producia "v5:5",
  # que se lee como si el numero de version y el conteo fueran lo mismo.
  $reparto = (($tick.GetEnumerator() | Sort-Object Value -Descending |
      ForEach-Object { "$($_.Key) x$($_.Value)" }) -join '  ')

  # --- plano de control: que dice el alias ---
  $alias = Leer-Alias
  $textoAlias = '?'
  if ($alias) {
    if ($alias.Pesos.Count -gt 0) {
      $vioReparto = $true
      $textoAlias = "v$($alias.Version) $($alias.Pesos -join ' ')"
    }
    else { $textoAlias = "v$($alias.Version)" }
  }

  # --- alarmas ---
  $textoAlarmas = 'OK'
  if ($alarmas.Count -gt 0) {
    $estadoAlarmas = Invocar-Aws (@('cloudwatch', 'describe-alarms', '--alarm-names') + $alarmas)
    if ($estadoAlarmas) {
      $enAlarma = @($estadoAlarmas.MetricAlarms | Where-Object { $_.StateValue -eq 'ALARM' })
      if ($enAlarma.Count -gt 0) { $textoAlarmas = "ALARM x$($enAlarma.Count)" }
    }
  }

  # --- CodeDeploy ---
  # Solo se miran los despliegues que NO existian al empezar. Los previos pertenecen a
  # ejecuciones anteriores y consultarlos llevaria a dar por buena una reversion ajena.
  $textoDespliegue = 'esperando al canary'
  $lista = Invocar-Aws @('deploy', 'list-deployments',
    '--application-name', $appCodeDeploy, '--deployment-group-name', $grupoCodeDeploy, '--max-items', '10')
  if ($lista -and $lista.deployments) {
    $nuevos = @($lista.deployments | Where-Object { $idsPrevios -notcontains $_ })
    if ($nuevos.Count -eq 0) {
      $textoDespliegue = "esperando (previo: $idPrevio)"
    }
    else {
      # De mas reciente a mas antiguo. Se clasifican todos porque durante un rollback
      # coexisten dos: el canary detenido y la reversion que lo deshace.
      foreach ($id in $nuevos) {
        $info = Invocar-Aws @('deploy', 'get-deployment', '--deployment-id', $id)
        if (-not $info) { continue }
        $d = $info.deploymentInfo
        if ($d.rollbackInfo -and $d.rollbackInfo.rollbackTriggeringDeploymentId) { $idRollback = $id }
        else { $idCanary = $id }
        if ($id -eq $nuevos[0]) { $textoDespliegue = "$id $($d.status)" }
      }
    }
  }

  $marca = (Get-Date).ToString('HH:mm:ss')
  Write-Host ("  {0}  {1}   {2}   {3}   " -f `
      $marca, $reparto.PadRight(23), $textoAlias.PadRight(18), $textoAlarmas.PadRight(11)) -NoNewline
  Write-Host $textoDespliegue -ForegroundColor (Color-Estado $textoDespliegue)

  [void]$historial.Add([pscustomobject]@{
      Hora = $marca; Reparto = $reparto; Alias = $textoAlias
      Alarmas = $textoAlarmas; CodeDeploy = $textoDespliegue
    })

  # --- condiciones de parada ---
  if ($idRollback) {
    $infoR = Invocar-Aws @('deploy', 'get-deployment', '--deployment-id', $idRollback)
    if ($infoR -and $infoR.deploymentInfo.status -eq 'Succeeded') {
      Write-Host ""
      Write-Host "  Reversion completada. Se sondea 30 s mas para ver que ya no hay errores." -ForegroundColor Yellow
      Start-Sleep -Seconds 30
      break
    }
  }
  elseif ($idCanary -and $vioReparto) {
    $infoC = Invocar-Aws @('deploy', 'get-deployment', '--deployment-id', $idCanary)
    if ($infoC -and $infoC.deploymentInfo.status -eq 'Succeeded') {
      Write-Host ""
      Write-Host "  Canary promovido al 100 %." -ForegroundColor Green
      break
    }
  }

  if ($trabajo -and $trabajo.State -eq 'Failed') {
    Write-Host "  El trabajo de despliegue fallo; se sigue observando por si CodeDeploy revierte." -ForegroundColor Red
  }

  Start-Sleep -Seconds $IntervaloS
}

# --- 5. Veredicto --------------------------------------------------------------------------

$aliasFinal = Leer-Alias
$duracion = [math]::Round(((Get-Date) - $inicioPrueba).TotalMinutes, 1)

if ($idRollback) { $veredicto = 'REVERTIDO AUTOMATICAMENTE' }
elseif ($aliasFinal -and $aliasFinal.Version -ne $aliasInicial.Version) { $veredicto = 'PROMOVIDO' }
else { $veredicto = 'SIN CAMBIOS' }

# Observando un despliegue ajeno no hay nada que esperar: no se sabe si el bundle que
# lanzo otro era sano o de caos. Comparar contra 'PROMOVIDO' marcaria como fallo un
# rollback correctamente observado.
if ($SoloObservar) { $esperado = '(sin expectativa: modo observacion)'; $coincide = $true }
elseif ($Caos) { $esperado = 'REVERTIDO AUTOMATICAMENTE'; $coincide = ($veredicto -eq $esperado) }
else { $esperado = 'PROMOVIDO'; $coincide = ($veredicto -eq $esperado) }
if ($coincide) { $colorVeredicto = 'Green' } else { $colorVeredicto = 'Red' }

$pctError = [math]::Round(100 * $errores / [math]::Max($totalPeticiones, 1), 1)

Write-Host ""
Escribir-Paso "Resultado"
Write-Host "  Veredicto  : $veredicto" -ForegroundColor $colorVeredicto
Write-Host "  Esperado   : $esperado"
Write-Host "  Alias      : v$($aliasInicial.Version) -> v$($aliasFinal.Version)"
Write-Host "  Duracion   : $duracion min"
Write-Host "  Peticiones : $totalPeticiones ($errores con error, $pctError %)"
if ($veredicto -eq 'SIN CAMBIOS') {
  Write-Host "  Pista: SAM solo publica una version nueva si cambia el CODIGO del bundle." -ForegroundColor Yellow
  Write-Host "         Un cambio solo de configuracion no arranca el canary." -ForegroundColor Yellow
}
Write-Host ""
foreach ($e in ($conteoVersiones.GetEnumerator() | Sort-Object Value -Descending)) {
  $pct = [math]::Round(100 * $e.Value / [math]::Max($totalPeticiones, 1), 1)
  Write-Host ("    {0,-14} {1,4}  {2,5} %" -f $e.Key, $e.Value, $pct)
}

if ($trabajo) {
  Write-Host ""
  Write-Host "  Salida del despliegue:" -ForegroundColor DarkGray
  Receive-Job $trabajo -ErrorAction SilentlyContinue | Select-Object -Last 15 |
    ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
  Remove-Job $trabajo -Force -ErrorAction SilentlyContinue
}

# --- 6. Evidencia --------------------------------------------------------------------------

if (-not $SinEvidencia) {
  # El sufijo describe lo que PASO, no lo que se pretendia. Nombrarlo por la intencion
  # produce archivos como "canary-intake-promocion-....md" que documentan un rollback.
  if ($idRollback) { $sufijo = 'rollback' }
  elseif ($veredicto -eq 'PROMOVIDO') { $sufijo = 'promocion' }
  else { $sufijo = 'sin-cambios' }
  $archivo = Join-Path $raiz "docs/evidencias/canary-$Servicio-$sufijo-$(Get-Date -Format 'yyyyMMdd-HHmm').md"

  $l = New-Object System.Collections.ArrayList
  [void]$l.Add("# Evidencia: despliegue canary de ``$Servicio`` ($sufijo)")
  [void]$l.Add("")
  [void]$l.Add("Generado por ``scripts/probar-canary.ps1`` el $(Get-Date -Format 'yyyy-MM-dd HH:mm').")
  [void]$l.Add("")
  [void]$l.Add("| Dato | Valor |")
  [void]$l.Add("|---|---|")
  [void]$l.Add("| Servicio | ``$Servicio`` |")
  if ($Caos) { [void]$l.Add("| Modo | caos (fallo sintetico inyectado) |") }
  else { [void]$l.Add("| Modo | despliegue sano |") }
  [void]$l.Add("| Veredicto | **$veredicto** |")
  [void]$l.Add("| Esperado | $esperado |")
  if ($coincide) { [void]$l.Add("| Coincide | si |") } else { [void]$l.Add("| Coincide | NO |") }
  [void]$l.Add("| Alias | v$($aliasInicial.Version) -> v$($aliasFinal.Version) |")
  [void]$l.Add("| Configuracion | Canary10Percent5Minutes |")
  [void]$l.Add("| Despliegue canary | ``$idCanary`` |")
  if ($idRollback) { [void]$l.Add("| Despliegue de reversion | ``$idRollback`` |") }
  else { [void]$l.Add("| Despliegue de reversion | ninguno |") }
  [void]$l.Add("| Duracion observada | $duracion min |")
  [void]$l.Add("| Peticiones | $totalPeticiones ($errores con error, $pctError %) |")
  [void]$l.Add("")
  [void]$l.Add("## Cronologia observada")
  [void]$l.Add("")
  [void]$l.Add("Plano de datos (que version contesta) y plano de control (pesos del alias) a la vez.")
  [void]$l.Add("")
  [void]$l.Add("| Hora | Reparto observado | Alias | Alarmas | CodeDeploy |")
  [void]$l.Add("|---|---|---|---|---|")
  foreach ($h in $historial) {
    [void]$l.Add("| $($h.Hora) | ``$($h.Reparto)`` | ``$($h.Alias)`` | $($h.Alarmas) | ``$($h.CodeDeploy)`` |")
  }
  [void]$l.Add("")
  [void]$l.Add("## Reparto acumulado")
  [void]$l.Add("")
  [void]$l.Add('```')
  foreach ($e in ($conteoVersiones.GetEnumerator() | Sort-Object Value -Descending)) {
    $pct = [math]::Round(100 * $e.Value / [math]::Max($totalPeticiones, 1), 1)
    [void]$l.Add(("  {0,-14} {1,4}  {2,5} %" -f $e.Key, $e.Value, $pct))
  }
  [void]$l.Add('```')

  if ($idCanary) {
    [void]$l.Add("")
    [void]$l.Add("## Despliegue canary (salida cruda de CodeDeploy)")
    [void]$l.Add("")
    [void]$l.Add('```json')
    $crudo = & aws deploy get-deployment --deployment-id $idCanary --region $RegionAws `
      --query 'deploymentInfo.{Id:deploymentId,Estado:status,Config:deploymentConfigName,Inicio:createTime,Fin:completeTime,Causa:errorInformation}' `
      --output json 2>$null
    [void]$l.Add(($crudo -join "`n"))
    [void]$l.Add('```')
  }
  if ($idRollback) {
    [void]$l.Add("")
    [void]$l.Add("## Despliegue de reversion (salida cruda de CodeDeploy)")
    [void]$l.Add("")
    [void]$l.Add('```json')
    $crudoR = & aws deploy get-deployment --deployment-id $idRollback --region $RegionAws `
      --query 'deploymentInfo.{Id:deploymentId,Estado:status,RollbackInfo:rollbackInfo}' `
      --output json 2>$null
    [void]$l.Add(($crudoR -join "`n"))
    [void]$l.Add('```')
  }

  $l | Set-Content -Path $archivo -Encoding utf8
  Write-Host ""
  Write-Host "  Evidencia -> $archivo" -ForegroundColor Green
}

if ($coincide) { exit 0 } else { exit 1 }
