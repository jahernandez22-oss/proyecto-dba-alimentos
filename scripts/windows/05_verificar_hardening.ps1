<#
.SYNOPSIS
  Checklist automatico de hardening: revisa Windows, PostgreSQL y MongoDB y marca CUMPLE / FALLA.

.DESCRIPTION
  Genera la tabla que va en la Seccion 1 del reporte ("checklist de hardening completado") y la
  guarda en C:\DBA\logs\checklist_hardening_<fecha>.csv. Se puede correr cuantas veces se quiera:
  solo lee, no cambia nada. Correrlo antes de cada checkpoint y antes de la defensa.
  Ejecutar como Administrador (necesita leer la directiva local y las carpetas protegidas).
#>
. (Join-Path $PSScriptRoot '..\00_parametros.ps1')
Assert-Administrador

$resultados = New-Object System.Collections.Generic.List[object]
function Revisar {
    param([string]$Area, [string]$Control, [bool]$Cumple, [string]$Detalle)
    $resultados.Add([pscustomobject]@{
        Area = $Area; Control = $Control; Resultado = $(if ($Cumple) { 'CUMPLE' } else { 'FALLA' }); Detalle = $Detalle
    })
}
function Get-UltimoValor {
    # Devuelve el ultimo valor de un parametro en postgresql.conf (PostgreSQL usa el ultimo).
    param([string[]]$Lineas, [string]$Parametro)
    $v = $null
    foreach ($l in $Lineas) {
        if ($l -match "^\s*$Parametro\s*=\s*('([^']*)'|[^\s#]+)") { $v = if ($matches[2] -ne $null) { $matches[2] } else { $matches[1] } }
    }
    return $v
}

# ---------- Windows: cuentas y servicios ----------
foreach ($par in @(@($P.PgServicio, $P.CuentaPg), @($P.MongoServicio, $P.CuentaMongo))) {
    $svc = Get-CimInstance Win32_Service -Filter "Name='$($par[0])'"
    $cuenta = if ($svc) { $svc.StartName } else { 'no existe' }
    Revisar 'Windows' "Servicio $($par[0]) corre con cuenta dedicada" ($cuenta -match "\\$($par[1])$") $cuenta
}
$admins = @()
try { $admins = (Get-LocalGroupMember -Group (Get-LocalGroup -SID $SID.Administradores) -ErrorAction Stop).Name } catch {}
foreach ($c in $P.CuentaPg, $P.CuentaMongo, $P.CuentaRespaldo) {
    Revisar 'Windows' "$c no es Administrador" (-not ($admins -match "\\$c$")) ''
}
$inf = Join-Path $env:TEMP 'verif_derechos.inf'
secedit /export /areas USER_RIGHTS /cfg $inf | Out-Null
$derechos = Get-Content $inf -Encoding Unicode
Remove-Item $inf -ErrorAction SilentlyContinue
foreach ($c in $P.CuentaPg, $P.CuentaMongo, $P.CuentaRespaldo) {
    try { $sidCuenta = (Get-Identidad $c).Translate([Security.Principal.SecurityIdentifier]).Value } catch { $sidCuenta = 'sin-sid' }
    $linea = $derechos | Where-Object { $_ -match '^SeDenyInteractiveLogonRight' }
    $valores = @(if ($linea) { (($linea -split '=', 2)[1] -split ',') | ForEach-Object { $_.Trim() } })
    Revisar 'Windows' "$c sin inicio de sesion interactivo" (($valores -contains "*$sidCuenta") -or ($valores -contains $c)) ''
}
# Politica de contraseñas y bloqueo de cuentas (las claves de secedit no dependen del idioma)
$inf2 = Join-Path $env:TEMP 'verif_politica.inf'
secedit /export /areas SECURITYPOLICY /cfg $inf2 | Out-Null
$pol = Get-Content $inf2 -Encoding Unicode
Remove-Item $inf2 -ErrorAction SilentlyContinue
function Get-Politica([string]$Clave) {
    $l = $pol | Where-Object { $_ -match "^$Clave\s*=" } | Select-Object -First 1
    if ($l) { return [int](($l -split '=')[1].Trim()) } else { return 0 }
}
$umbral = Get-Politica 'LockoutBadCount'
$minimo = Get-Politica 'MinimumPasswordLength'
Revisar 'Windows' 'Bloqueo de cuenta tras 5 intentos o menos' ($umbral -ge 1 -and $umbral -le 5) "LockoutBadCount=$umbral"
Revisar 'Windows' 'Contraseñas de 14 caracteres o mas' ($minimo -ge 14) "MinimumPasswordLength=$minimo"
$smb1 = $true
try { $smb1 = (Get-SmbServerConfiguration -ErrorAction Stop).EnableSMB1Protocol } catch {}
Revisar 'Windows' 'SMBv1 deshabilitado' (-not $smb1) ''

# ---------- Windows: red y firewall ----------
$escucha = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue
foreach ($m in @(@('PostgreSQL', $P.PgPuerto, 5432), @('MongoDB', $P.MongoPuerto, 27017))) {
    $nuevo = $escucha | Where-Object LocalPort -eq $m[1]
    $viejo = $escucha | Where-Object LocalPort -eq $m[2]
    Revisar 'Red' "$($m[0]) escucha en $($m[1]) y no en $($m[2])" ([bool]$nuevo -and -not $viejo) (($nuevo.LocalAddress | Sort-Object -Unique) -join ', ')
    $comodin = $nuevo | Where-Object { $_.LocalAddress -in '0.0.0.0', '::' }
    Revisar 'Red' "$($m[0]) no escucha en todas las interfaces" (-not $comodin) ''
}
$perfiles = Get-NetFirewallProfile
Revisar 'Firewall' 'Los 3 perfiles activos con entrada bloqueada por defecto' `
    (-not ($perfiles | Where-Object { -not $_.Enabled -or $_.DefaultInboundAction -ne 'Block' })) (($perfiles | ForEach-Object { "$($_.Name)=$($_.DefaultInboundAction)" }) -join ' ')
Revisar 'Firewall' 'Registro de paquetes descartados activo' (-not ($perfiles | Where-Object { $_.LogBlocked -ne 'True' })) ''
$permiten = Get-NetFirewallRule -Direction Inbound -Action Allow -Enabled True -ErrorAction SilentlyContinue |
    Where-Object { @(($_ | Get-NetFirewallPortFilter).LocalPort | Where-Object { $_ -in '5432', '27017' }).Count -gt 0 }
Revisar 'Firewall' 'Ninguna regla permite 5432 ni 27017' (-not $permiten) (($permiten.DisplayName) -join ', ')
foreach ($puerto in $P.PgPuerto, $P.MongoPuerto) {
    $r = Get-NetFirewallRule -DisplayName "ADV-*-$puerto-lista-blanca" -ErrorAction SilentlyContinue
    $ips = if ($r) { ($r | Get-NetFirewallAddressFilter).RemoteAddress } else { @() }
    Revisar 'Firewall' "Lista blanca en $puerto sin 'Any'" ([bool]$r -and ($ips -notcontains 'Any')) ($ips -join ', ')
}

# ---------- Permisos NTFS ----------
$prohibidos = @($SID.Usuarios, $SID.Autenticados, $SID.Todos)
foreach ($ruta in $P.PgData, $P.MongoData, $P.MongoLog, $P.MongoCfg, $P.Secretos) {
    if (-not (Test-Path -LiteralPath $ruta)) { Revisar 'NTFS' "Permisos de $ruta" $false 'no existe'; continue }
    $acl = (Get-Item -LiteralPath $ruta).GetAccessControl('Access')
    $sids = $acl.Access | ForEach-Object { try { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { '' } }
    $malos = $sids | Where-Object { $_ -in $prohibidos }
    Revisar 'NTFS' "Sin acceso de Usuarios/Todos en $ruta" (-not $malos) ''
}

# ---------- PostgreSQL ----------
$conf = Join-Path $P.PgData 'postgresql.conf'
if (Test-Path $conf) {
    $l = Get-Content $conf
    Revisar 'PostgreSQL' "port = $($P.PgPuerto)" ((Get-UltimoValor $l 'port') -eq "$($P.PgPuerto)") (Get-UltimoValor $l 'port')
    $la = Get-UltimoValor $l 'listen_addresses'
    Revisar 'PostgreSQL' 'listen_addresses sin comodin *' ($la -and $la -notmatch '\*') $la
    Revisar 'PostgreSQL' 'password_encryption = scram-sha-256' ((Get-UltimoValor $l 'password_encryption') -eq 'scram-sha-256') ''
    Revisar 'PostgreSQL' 'ssl = on' ((Get-UltimoValor $l 'ssl') -eq 'on') ''
    Revisar 'PostgreSQL' 'Bitacora de conexiones activa' ((Get-UltimoValor $l 'log_connections') -in 'on', 'all', 'receipt,authentication,authorization') (Get-UltimoValor $l 'log_connections')
    Revisar 'PostgreSQL' "log_statement = 'ddl' (o mas)" ((Get-UltimoValor $l 'log_statement') -in 'ddl', 'mod') (Get-UltimoValor $l 'log_statement')
} else { Revisar 'PostgreSQL' 'postgresql.conf legible' $false $conf }
$hba = Join-Path $P.PgData 'pg_hba.conf'
if (Test-Path $hba) {
    $reglas = Get-Content $hba | Where-Object { $_ -match '^\s*(local|host|hostssl|hostnossl)\s' }
    Revisar 'PostgreSQL' 'pg_hba.conf sin metodo trust' (-not ($reglas -match '\strust(\s|$)')) ''
    Revisar 'PostgreSQL' 'pg_hba.conf sin md5' (-not ($reglas -match '\smd5(\s|$)')) ''
    Revisar 'PostgreSQL' 'pg_hba.conf termina rechazando todo' ([bool]($reglas[-1] -match '\sreject\s*$')) $reglas[-1]
}

# ---------- MongoDB ----------
if (Test-Path -LiteralPath $P.MongoCfg) {
    $cfg = Get-Content -LiteralPath $P.MongoCfg -Raw
    Revisar 'MongoDB' 'security.authorization: enabled' ($cfg -match '(?m)^\s*authorization:\s*enabled') ''
    Revisar 'MongoDB' "net.port: $($P.MongoPuerto)" ($cfg -match "(?m)^\s*port:\s*$($P.MongoPuerto)\b") ''
    $bind = if ($cfg -match '(?m)^\s*bindIp:\s*(.+)$') { $matches[1].Trim() } else { '' }
    Revisar 'MongoDB' 'bindIp sin 0.0.0.0 ni bindIpAll' ($bind -and $bind -notmatch '0\.0\.0\.0' -and $cfg -notmatch 'bindIpAll:\s*true') $bind
    Revisar 'MongoDB' 'JavaScript del servidor apagado' ($cfg -match '(?m)^\s*javascriptEnabled:\s*false') ''
    Revisar 'MongoDB' 'keyFile configurado' ($cfg -match '(?m)^\s*keyFile:') ''
    Revisar 'MongoDB' 'auditLog configurado (Fase 2)' ($cfg -match '(?m)^auditLog:') ''
} else { Revisar 'MongoDB' 'mongod.cfg legible' $false $P.MongoCfg }

# ---------- Resultado ----------
$resultados | Format-Table -AutoSize -Wrap
$fallas = @($resultados | Where-Object Resultado -eq 'FALLA').Count
$salida = Join-Path $P.LogsScripts ("checklist_hardening_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmm'))
if (Test-Path $P.LogsScripts) { $resultados | Export-Csv -Path $salida -NoTypeInformation -Encoding UTF8 }
Write-Paso ("{0} controles, {1} con FALLA. CSV: {2}" -f $resultados.Count, $fallas, $salida) $(if ($fallas) { 'AVISO' } else { 'OK' })
