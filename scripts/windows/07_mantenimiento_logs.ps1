<#
.SYNOPSIS
  Mantenimiento diario de bitacoras: rota los logs de MongoDB, borra los rotados viejos y
  reporta cuanto ocupan. Evita el "satura el disco por falta de filtros" de la rubrica.

.DESCRIPTION
  PostgreSQL ya rota solo (un archivo por dia de la semana que se sobrescribe a los 7 dias).
  MongoDB en Windows no rota por tamaño: hay que pedirselo con el comando logRotate.
  Este script lo pide con el usuario "mantenimiento" (su unico permiso es logRotate) y luego
  borra los archivos rotados con mas de $DiasRetencion dias.

  Corre como tarea programada con la cuenta SYSTEM: ninguna cuenta de servicio debe poder
  BORRAR bitacoras (si svc_respaldo pudiera, un atacante que la robe borraria sus huellas).
  El script vive en una carpeta que solo Administradores pueden modificar.

  Requiere: C:\DBA\secretos\mongo_mantenimiento.txt con la contraseña del usuario mantenimiento.
  Uso:  .\07_mantenimiento_logs.ps1             (ejecuta una vez)
        .\07_mantenimiento_logs.ps1 -Registrar  (crea la tarea diaria de las 23:55)
#>
param([switch]$Registrar, [int]$DiasRetencion = 30)
. (Join-Path $PSScriptRoot '..\00_parametros.ps1')

if ($Registrar) {
    Assert-Administrador
    $accion = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $disparo = New-ScheduledTaskTrigger -Daily -At '23:55'
    $quien = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName 'ADV-Mantenimiento-Bitacoras' -TaskPath '\AlimentosDelValle\' `
        -Action $accion -Trigger $disparo -Principal $quien -Force `
        -Description 'Rota logs de MongoDB y depura bitacoras viejas (Equipo DBA)' | Out-Null
    Write-Paso 'Tarea \AlimentosDelValle\ADV-Mantenimiento-Bitacoras registrada (diaria 23:55, SYSTEM)' 'OK'
    return
}

# 1) Rotar logs de MongoDB (servidor y auditoria)
$secreto = Join-Path $P.Secretos 'mongo_mantenimiento.txt'
$resultado = 'sin rotar'
if (Test-Path $secreto) {
    $env:MONGO_PUERTO = "$($P.MongoPuerto)"
$env:MONGO_CLAVE = (Get-Content $secreto -Raw).Trim()
    $js = @'
const c = new Mongo('mongodb://mantenimiento:' + encodeURIComponent(process.env.MONGO_CLAVE) + '@127.0.0.1:' + process.env.MONGO_PUERTO + '/?authSource=admin&directConnection=true');
const r = c.getDB('admin').runCommand({ logRotate: 1 });
print(r.ok === 1 ? 'rotado' : 'error: ' + JSON.stringify(r));
'@
    $resultado = & $P.Mongosh --quiet --nodb --eval $js 2>&1 | Out-String
    Remove-Item Env:\MONGO_CLAVE
} else {
    Write-Paso "No existe $secreto: no se roto MongoDB" 'AVISO'
}

# 2) Borrar rotados viejos (los nombres rotados llevan la fecha: mongod.log.2026-12-01T23-55-00)
$limite = (Get-Date).AddDays(-$DiasRetencion)
$viejos = Get-ChildItem $P.MongoLog -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^(mongod\.log|audit\.json)\.\d{4}-' -and $_.LastWriteTime -lt $limite }
$viejos | Remove-Item -Force -ErrorAction SilentlyContinue

# 3) Cuanto ocupan las bitacoras hoy
$mb = { param($ruta) [math]::Round(((Get-ChildItem $ruta -File -Recurse -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB), 1) }
$pgMb = & $mb (Join-Path $P.PgData 'log')
$moMb = & $mb $P.MongoLog
$mensaje = "Mantenimiento de bitacoras: MongoDB $($resultado.Trim()); rotados borrados: $(@($viejos).Count); " +
           "PostgreSQL log = $pgMb MB; MongoDB log = $moMb MB (retencion $DiasRetencion dias)"
Write-Paso $mensaje 'OK'
if ([Diagnostics.EventLog]::SourceExists($P.FuenteEventos)) {
    Write-EventLog -LogName Application -Source $P.FuenteEventos -EventId 3000 -EntryType Information -Message $mensaje
}
