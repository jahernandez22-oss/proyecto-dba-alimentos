<#
.SYNOPSIS
  Recupera PostgreSQL a un instante exacto (PITR): respaldo base + WAL archivado hasta -Hasta.

.DESCRIPTION
  Uso tipico en la defensa: el docente borra datos a las 10:32:15; ustedes recuperan hasta 10:32:00
  y no se pierde ni la venta de las 10:31 (RPO de segundos, no de horas).
      .\pitr_restaurar_postgres.ps1 -Hasta '2026-12-10 10:32:00'
  La hora se interpreta en la zona horaria del servidor (SHOW timezone).

  Pasos: detiene el servicio; APARTA la carpeta de datos actual (data_danada_<fecha>, evidencia);
  copia la base mas reciente anterior a -Hasta; pone las configuraciones maestras; escribe
  restore_command + recovery_target_time + recovery_target_action = 'promote' y recovery.signal;
  devuelve los permisos a svc_postgres; arranca y espera a que termine la recuperacion.
  Despues hay que sacar una base nueva (la linea de tiempo cambio) y volver a aplicar la SACL de
  auditoria (06_auditoria_windows.ps1) porque los archivos de configuracion son nuevos.
  Ejecutar como Administrador. Ensayenlo al menos dos veces antes de la defensa.
#>
param([Parameter(Mandatory)][datetime]$Hasta)
. (Join-Path $PSScriptRoot '..\00_parametros.ps1')
Assert-Administrador
$ErrorActionPreference = 'Stop'
$reloj = [Diagnostics.Stopwatch]::StartNew()
$env:PGPASSFILE = Join-Path $P.SecretosAdmin 'pgpass_admin.conf'
$psql = Join-Path $P.PgBin 'psql.exe'

# 1) Elegir la base mas reciente que sea ANTERIOR al instante objetivo
$base = Get-ChildItem (Join-Path $P.Respaldos 'postgresql_base') -Directory |
    Where-Object { $_.Name -match '^\d{8}_\d{6}$' -and [datetime]::ParseExact($_.Name, 'yyyyMMdd_HHmmss', $null) -lt $Hasta } |
    Sort-Object Name -Descending | Select-Object -First 1
if (-not $base) { throw "No hay respaldo base anterior a $Hasta" }
Write-Paso "Base elegida: $($base.Name); objetivo: $($Hasta.ToString('yyyy-MM-dd HH:mm:ss'))" 'AVISO'

# 2) Mandar al archivo el WAL que esta en curso (contiene los ultimos cambios antes del incidente),
#    luego detener y apartar la carpeta de datos actual
& $psql -h 127.0.0.1 -p $P.PgPuerto -U postgres -w -d postgres -At -c 'SELECT pg_switch_wal()' 2>$null | Out-Null
Start-Sleep -Seconds 5
Stop-Service $P.PgServicio -Force
$apartada = "$($P.PgData)_danada_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
Rename-Item -LiteralPath $P.PgData -NewName (Split-Path $apartada -Leaf)
Write-Paso "Datos actuales apartados en $apartada" 'INFO'

# 3) Copiar la base (robocopy es rapido y conserva la estructura) y las configuraciones maestras
robocopy $base.FullName $P.PgData /E /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy fallo con codigo $LASTEXITCODE" }
# WAL que no alcanzo a archivarse: se toma de la carpeta apartada (PostgreSQL lo busca en pg_wal)
Get-ChildItem (Join-Path $apartada 'pg_wal') -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^[0-9A-F]{24}$' -and -not (Test-Path (Join-Path $P.PgData "pg_wal\$($_.Name)")) } |
    Copy-Item -Destination (Join-Path $P.PgData 'pg_wal')
foreach ($f in 'postgresql.conf', 'pg_hba.conf', 'postgresql.auto.conf') {
    Copy-Item (Join-Path $P.ConfigMaestra $f) (Join-Path $P.PgData $f) -Force
}
$wal = (Join-Path $P.Respaldos 'wal').Replace('\', '\\')
Add-Content -Path (Join-Path $P.PgData 'postgresql.auto.conf') -Encoding ASCII -Value @(
    "restore_command = 'copy `"$wal\\%f`" `"%p`"'",
    "recovery_target_time = '$($Hasta.ToString('yyyy-MM-dd HH:mm:ss'))'",
    "recovery_target_action = 'promote'")
New-Item -ItemType File -Path (Join-Path $P.PgData 'recovery.signal') -Force | Out-Null
Remove-Item (Join-Path $P.PgData 'postmaster.pid') -ErrorAction SilentlyContinue

# 4) Permisos: la carpeta nueva solo para SYSTEM, Administradores y svc_postgres
$item = Get-Item -LiteralPath $P.PgData
$acl = $item.GetAccessControl('Access')
$acl.SetAccessRuleProtection($true, $false)
foreach ($r in @($acl.Access)) { if (-not $r.IsInherited) { [void]$acl.RemoveAccessRuleSpecific($r) } }
foreach ($c in @($SID.SYSTEM, $SID.Administradores, $P.CuentaPg)) {
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((Get-Identidad $c), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
}
$item.SetAccessControl($acl)
icacls "$($P.PgData)\*" /reset /T /C /Q | Out-Null

# 5) Arrancar y esperar a que la recuperacion termine (pg_is_in_recovery = f)
Start-Service $P.PgServicio
$listo = $false
for ($i = 0; $i -lt 300 -and -not $listo; $i++) {
    Start-Sleep -Seconds 2
    $r = & $psql -h 127.0.0.1 -p $P.PgPuerto -U postgres -w -d postgres -At -c 'SELECT pg_is_in_recovery()' 2>$null
    $listo = ($r -eq 'f')
}
if (-not $listo) { throw "PostgreSQL no termino la recuperacion; revisen el log en $($P.PgData)\log" }

# 6) Limpiar los parametros de recuperacion para el siguiente reinicio
& $psql -h 127.0.0.1 -p $P.PgPuerto -U postgres -w -d postgres -q -c "ALTER SYSTEM RESET recovery_target_time; ALTER SYSTEM RESET recovery_target_action; ALTER SYSTEM RESET restore_command; SELECT pg_reload_conf();" | Out-Null
$reloj.Stop()

$ultimo = & $psql -h 127.0.0.1 -p $P.PgPuerto -U postgres -w -d $P.PgBase -At -c "SELECT max(momento) FROM auditoria.bitacora_cambios"
$msg = "PITR terminado en $([math]::Round($reloj.Elapsed.TotalSeconds)) s (RTO). Base $($base.Name) + WAL hasta $($Hasta.ToString('yyyy-MM-dd HH:mm:ss')). Ultimo cambio auditado recuperado: $ultimo"
Write-EventoDBA -Mensaje $msg -Id 1100
Write-Paso $msg 'OK'
Write-Host 'Siguientes pasos: Start-ScheduledTask -TaskPath \AlimentosDelValle\ -TaskName ADV-Respaldo-Base-WAL' -ForegroundColor Yellow
Write-Host '                  y volver a correr scripts\windows\06_auditoria_windows.ps1 (SACL de los configs nuevos)' -ForegroundColor Yellow
