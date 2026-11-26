<#
.SYNOPSIS
  Firewall de Windows con lista blanca: solo las IPs autorizadas llegan a los puertos no nativos.

.DESCRIPTION
  Por que: el caso sufre fuerza bruta constante porque 5432 y 27017 estan abiertos a internet.
  Cambiar el puerto quita el ruido de los bots que solo prueban los puertos conocidos, pero NO es
  seguridad por si solo (un escaneo completo lo encuentra). La proteccion real es la lista blanca:
  aunque alguien encuentre 15432 o 37017, el firewall descarta el paquete si su IP no esta autorizada.

  Detalle clave del Firewall de Windows: una regla de BLOQUEO gana sobre una de PERMITIR.
  Por eso NO se crea un "bloquear 15432 para todos": el bloqueo de lo no autorizado ya lo hace
  la accion por defecto de entrada (Block). Solo se bloquean explicitamente 5432 y 27017.

  Nota: el trafico local (127.0.0.1) no pasa por el firewall; ese lo controlan pg_hba.conf y bindIp.
  Ejecutar como Administrador.
#>
. (Join-Path $PSScriptRoot '..\00_parametros.ps1')
Assert-Administrador

# 1) Borrar reglas previas del proyecto (incluidas las inseguras de la linea base)
Get-NetFirewallRule -DisplayName 'ADV-*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
Write-Paso 'Reglas ADV-* anteriores eliminadas (incluidas las del prototipo inseguro)' 'OK'

# 2) Cualquier otra regla de ENTRADA que permita 5432 o 27017 (por ejemplo, creada por un instalador)
$abiertas = Get-NetFirewallRule -Direction Inbound -Action Allow -Enabled True -ErrorAction SilentlyContinue |
    Where-Object { @(($_ | Get-NetFirewallPortFilter).LocalPort | Where-Object { $_ -in '5432', '27017' }).Count -gt 0 }
foreach ($r in $abiertas) {
    Disable-NetFirewallRule -Name $r.Name
    Write-Paso "Deshabilitada regla ajena que abria un puerto por defecto: $($r.DisplayName)" 'AVISO'
}

# 3) Perfiles: firewall encendido, entrada bloqueada por defecto y registro de paquetes descartados
Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled True `
    -DefaultInboundAction Block -DefaultOutboundAction Allow `
    -LogBlocked True -LogAllowed False -LogMaxSizeKilobytes 16384 `
    -LogFileName '%systemroot%\system32\LogFiles\Firewall\pfirewall.log'
Write-Paso 'Perfiles: entrada bloqueada por defecto y registro de descartes activado' 'OK'

# 4) Bloqueo explicito de los puertos por defecto (por si alguien revierte el cambio de puerto)
New-NetFirewallRule -DisplayName 'ADV-BLOQUEO-puertos-por-defecto-5432-27017' -Direction Inbound `
    -Protocol TCP -LocalPort 5432, 27017 -Action Block -Profile Any | Out-Null

# 5) Lista blanca por motor, atada al ejecutable del motor
New-NetFirewallRule -DisplayName "ADV-PostgreSQL-$($P.PgPuerto)-lista-blanca" -Direction Inbound `
    -Protocol TCP -LocalPort $P.PgPuerto -RemoteAddress $P.IpsAutorizadas `
    -Program (Join-Path $P.PgBin 'postgres.exe') -Action Allow -Profile Any | Out-Null
New-NetFirewallRule -DisplayName "ADV-MongoDB-$($P.MongoPuerto)-lista-blanca" -Direction Inbound `
    -Protocol TCP -LocalPort $P.MongoPuerto -RemoteAddress $P.IpsAutorizadas `
    -Program (Join-Path $P.MongoBin 'mongod.exe') -Action Allow -Profile Any | Out-Null
Write-Paso "Lista blanca aplicada: $($P.IpsAutorizadas -join ', ') -> TCP $($P.PgPuerto) y $($P.MongoPuerto)" 'OK'

# 6) Evidencia
Write-Host "`n--- Evidencia: reglas del proyecto ---" -ForegroundColor Cyan
Get-NetFirewallRule -DisplayName 'ADV-*' | ForEach-Object {
    [pscustomobject]@{
        Regla     = $_.DisplayName
        Accion    = $_.Action
        Puerto    = (($_ | Get-NetFirewallPortFilter).LocalPort) -join ','
        IPRemota  = (($_ | Get-NetFirewallAddressFilter).RemoteAddress) -join ','
        Programa  = ($_ | Get-NetFirewallApplicationFilter).Program
    }
} | Format-Table -AutoSize -Wrap

Write-Host "--- Evidencia: perfiles ---" -ForegroundColor Cyan
Get-NetFirewallProfile | Select-Object Name, Enabled, DefaultInboundAction, LogBlocked, LogFileName | Format-Table -AutoSize

Write-Host "Prueba desde el ANFITRION (debe decir TcpTestSucceeded: True):" -ForegroundColor Yellow
Write-Host "  Test-NetConnection $($P.IpServidor) -Port $($P.PgPuerto)" -ForegroundColor Yellow
Write-Host "Prueba hacia la red NO autorizada 192.168.57.10 (debe decir False):" -ForegroundColor Yellow
Write-Host "  Test-NetConnection 192.168.57.10 -Port $($P.PgPuerto)" -ForegroundColor Yellow
