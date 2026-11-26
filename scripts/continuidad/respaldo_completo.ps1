<#
.SYNOPSIS
  Orquestador del respaldo: PostgreSQL + MongoDB + configuraciones, retencion y aviso al Visor.
  Es el script que ejecuta el Programador de tareas (cuenta svc_respaldo).

.DESCRIPTION
  1. Corre respaldo_postgres.ps1, respaldo_mongodb.ps1 y respaldo_config.ps1. Si uno falla, sigue con
     los demas (un motor caido no debe dejar sin respaldo al otro) y al final reporta el error.
  2. Retencion: borra respaldos con mas de RetencionDias, pero SIEMPRE conserva los 3 mas recientes
     de cada tipo (si los respaldos dejaron de correr hace semanas, no se borra lo ultimo que queda).
  3. Deja todo en C:\DBA\logs\respaldo_<fecha>.log y un evento en Aplicacion (1000 bien, 1001 error).
  4. Sale con codigo 0 o 1: el Programador de tareas lo muestra en "Resultado de la ultima ejecucion".

  Regla 3-2-1 (3 copias, 2 medios, 1 fuera del sitio): aqui hay 2 copias en 2 discos (C: datos, E:
  respaldos). La tercera, fuera del sitio, es copiar E:\Respaldos a un USB cifrado o a la nube: se
  explica en el reporte como siguiente paso (y el USB "cuando se acuerda" queda reemplazado).
#>
param([switch]$SinRetencion)
. (Join-Path $PSScriptRoot '..\00_parametros.ps1')
New-Item -ItemType Directory -Path $P.LogsScripts -Force | Out-Null
$bitacora = Join-Path $P.LogsScripts ("respaldo_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
Start-Transcript -Path $bitacora | Out-Null
$reloj = [Diagnostics.Stopwatch]::StartNew()
$resultados = @(); $errores = @()

foreach ($s in 'respaldo_postgres.ps1', 'respaldo_mongodb.ps1', 'respaldo_config.ps1') {
    try { $resultados += & (Join-Path $PSScriptRoot $s) }
    catch { $errores += "$s : $($_.Exception.Message)"; Write-Paso "$s fallo: $($_.Exception.Message)" 'ERROR' }
}

if (-not $SinRetencion) {
    $limite = (Get-Date).AddDays(-$P.RetencionDias)
    foreach ($tipo in 'postgresql', 'mongodb', 'config') {
        $carpetas = Get-ChildItem (Join-Path $P.Respaldos $tipo) -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d{8}_\d{6}$' } | Sort-Object Name -Descending
        $carpetas | Select-Object -Skip 3 | Where-Object { $_.CreationTime -lt $limite } | ForEach-Object {
            Remove-Item $_.FullName -Recurse -Force
            Write-Paso "Retencion: borrado $($_.FullName)" 'INFO'
        }
    }
}

$reloj.Stop()
$tabla = ($resultados | ForEach-Object { "$($_.Motor): $($_.MB) MB en $($_.Segundos) s" }) -join '; '
$libre = [math]::Round((Get-PSDrive (Split-Path $P.Respaldos -Qualifier).TrimEnd(':')).Free / 1GB, 1)
if ($errores.Count) {
    $msg = "Respaldo con ERRORES en $([math]::Round($reloj.Elapsed.TotalSeconds)) s. $tabla. Errores: $($errores -join ' | '). Bitacora: $bitacora"
    Write-EventoDBA -Mensaje $msg -Id 1001 -Tipo Error
    Write-Paso $msg 'ERROR'
    Stop-Transcript | Out-Null
    exit 1
}
$msg = "Respaldo correcto en $([math]::Round($reloj.Elapsed.TotalSeconds)) s. $tabla. Espacio libre: $libre GB. Bitacora: $bitacora"
Write-EventoDBA -Mensaje $msg -Id 1000 -Tipo Information
Write-Paso $msg 'OK'
Stop-Transcript | Out-Null
exit 0
