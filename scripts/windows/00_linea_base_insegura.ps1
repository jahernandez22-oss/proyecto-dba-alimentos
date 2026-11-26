<#
.SYNOPSIS
  Reproduce el estado INSEGURO del prototipo para capturar el "antes".

.DESCRIPTION
  El caso dice que ambos motores escuchan en 5432 y 27017 y que el Firewall de Windows
  los deja abiertos a todo internet. Este script crea esas reglas abiertas (y nada mas)
  para que la bitacora de hardening tenga capturas del "antes".
  El script 04_firewall.ps1 las borra y aplica la lista blanca.

  Ejecutar como Administrador, SOLO al inicio de la Fase 1.
#>
. (Join-Path $PSScriptRoot '..\00_parametros.ps1')
Assert-Administrador

Write-Paso 'Creando reglas abiertas del prototipo (estado inseguro a documentar)' 'AVISO'
New-NetFirewallRule -DisplayName 'ADV-INSEGURO-PostgreSQL-5432-cualquiera' -Direction Inbound `
    -Protocol TCP -LocalPort 5432 -RemoteAddress Any -Action Allow -Profile Any | Out-Null
New-NetFirewallRule -DisplayName 'ADV-INSEGURO-MongoDB-27017-cualquiera' -Direction Inbound `
    -Protocol TCP -LocalPort 27017 -RemoteAddress Any -Action Allow -Profile Any | Out-Null

Write-Paso 'Evidencias del ANTES (tomar captura de cada bloque):' 'INFO'

Write-Host "`n--- 1. Reglas de firewall abiertas a cualquier IP ---" -ForegroundColor Cyan
Get-NetFirewallRule -DisplayName 'ADV-INSEGURO-*' |
    Select-Object DisplayName, Enabled, Direction, Action,
        @{n='Puerto';e={($_ | Get-NetFirewallPortFilter).LocalPort}},
        @{n='IP remota';e={($_ | Get-NetFirewallAddressFilter).RemoteAddress}} | Format-Table -AutoSize

Write-Host "--- 2. Puertos por defecto escuchando en todas las interfaces ---" -ForegroundColor Cyan
Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
    Where-Object { $_.LocalPort -in 5432, 27017 } |
    Select-Object LocalAddress, LocalPort, OwningProcess,
        @{n='Proceso';e={(Get-Process -Id $_.OwningProcess).ProcessName}} | Format-Table -AutoSize

Write-Host "--- 3. Cuenta con la que corren los servicios hoy ---" -ForegroundColor Cyan
Get-CimInstance Win32_Service | Where-Object { $_.Name -like 'postgresql*' -or $_.Name -eq 'MongoDB' } |
    Select-Object Name, State, StartName | Format-Table -AutoSize

Write-Host "Siguiente: capturar desde el anfitrion 'psql -h 192.168.56.10 -p 5432 -U postgres' y" -ForegroundColor Yellow
Write-Host "'mongosh --host 192.168.56.10 --port 27017' entrando sin restricciones." -ForegroundColor Yellow
