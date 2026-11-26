<#
.SYNOPSIS
  Registra en el Programador de tareas de Windows todas las tareas automaticas del proyecto.

.DESCRIPTION
  Carpeta \AlimentosDelValle\ del Programador de tareas:
    ADV-Respaldo-Logico      13:30 y 23:30 diario  respaldo_completo.ps1          svc_respaldo   (RPO <= 14 h: de 23:30 a 13:30)
    ADV-Respaldo-Base-WAL    03:00 diario          pitr_base_postgres.ps1         svc_respaldo   (PITR)
    ADV-Refresco-Reportes    02:00 diario          SELECT reportes.refrescar_ventas()  svc_respaldo
    ADV-Integridad-Config    cada hora             verificar_integridad.ps1       SYSTEM (lee el registro Security)
  (ADV-Mantenimiento-Bitacoras se registra con 07_mantenimiento_logs.ps1 -Registrar.)

  Por que svc_respaldo y no un Administrador: la tarea solo necesita conectarse a los motores con
  usuarios de solo lectura y escribir en E:\Respaldos. Si alguien roba esa cuenta, no obtiene nada mas.
  La tarea queda con "Ejecutar tanto si el usuario inicio sesion como si no" (contraseña guardada por
  Windows) y con RunLevel Limited (sin elevacion).
  Ejecutar como Administrador. Pide la contraseña de svc_respaldo una sola vez.
#>
. (Join-Path $PSScriptRoot '..\00_parametros.ps1')
Assert-Administrador
$carpeta = '\AlimentosDelValle\'
$ps = 'powershell.exe'
$base = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File'
$cred = Get-Credential -UserName ".\$($P.CuentaRespaldo)" -Message 'Contraseña de svc_respaldo (para guardar en las tareas)'
$usuario = $cred.UserName; $clave = $cred.GetNetworkCredential().Password

$ajustes = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 2) -RestartCount 2 -RestartInterval (New-TimeSpan -Minutes 10) `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

function Registrar($Nombre, $Accion, $Disparadores, $Descripcion, [switch]$ComoSystem) {
    if ($ComoSystem) {
        $quien = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName $Nombre -TaskPath $carpeta -Action $Accion -Trigger $Disparadores `
            -Principal $quien -Settings $ajustes -Description $Descripcion -Force | Out-Null
    } else {
        Register-ScheduledTask -TaskName $Nombre -TaskPath $carpeta -Action $Accion -Trigger $Disparadores `
            -User $usuario -Password $clave -RunLevel Limited -Settings $ajustes -Description $Descripcion -Force | Out-Null
    }
    Write-Paso "Tarea $carpeta$Nombre registrada" 'OK'
}

$scripts = $PSScriptRoot
Registrar 'ADV-Respaldo-Logico' `
    (New-ScheduledTaskAction -Execute $ps -Argument "$base `"$scripts\respaldo_completo.ps1`"" -WorkingDirectory $scripts) `
    @((New-ScheduledTaskTrigger -Daily -At '13:30'), (New-ScheduledTaskTrigger -Daily -At '23:30')) `
    'pg_dump + mongodump --oplog + configuraciones, con retencion (Equipo DBA)'

Registrar 'ADV-Respaldo-Base-WAL' `
    (New-ScheduledTaskAction -Execute $ps -Argument "$base `"$scripts\pitr_base_postgres.ps1`"" -WorkingDirectory $scripts) `
    (New-ScheduledTaskTrigger -Daily -At '03:00') `
    'Respaldo base de PostgreSQL para recuperar a un punto en el tiempo con el archivo WAL'

$psql = Join-Path $P.PgBin 'psql.exe'
$refresco = "-NoProfile -NonInteractive -Command `"`$env:PGPASSFILE='$($P.Secretos)\pgpass.conf'; & '$psql' -h 127.0.0.1 -p $($P.PgPuerto) -U app_reportes -d $($P.PgBase) -w -c 'SELECT reportes.refrescar_ventas()'`""
Registrar 'ADV-Refresco-Reportes' (New-ScheduledTaskAction -Execute $ps -Argument $refresco) `
    (New-ScheduledTaskTrigger -Daily -At '02:00') 'Refresca la vista materializada del reporte mensual'

$cadaHora = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Hours 1)
Registrar 'ADV-Integridad-Config' `
    (New-ScheduledTaskAction -Execute $ps -Argument "$base `"$scripts\verificar_integridad.ps1`"" -WorkingDirectory $scripts) `
    $cadaHora 'Compara las configuraciones contra la copia maestra y avisa (evento 2001) si cambiaron' -ComoSystem

$clave = $null
Write-Host "`n--- Evidencia: tareas registradas ---" -ForegroundColor Cyan
Get-ScheduledTask -TaskPath $carpeta | ForEach-Object {
    $i = $_ | Get-ScheduledTaskInfo
    [pscustomobject]@{ Tarea = $_.TaskName; Cuenta = $_.Principal.UserId; Estado = $_.State; Proxima = $i.NextRunTime; UltimoResultado = $i.LastTaskResult }
} | Format-Table -AutoSize
Write-Host "Prueba inmediata:  Start-ScheduledTask -TaskPath '$carpeta' -TaskName 'ADV-Respaldo-Logico'" -ForegroundColor Yellow
