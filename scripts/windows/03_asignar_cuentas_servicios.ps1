<#
.SYNOPSIS
  Cambia los servicios de PostgreSQL y MongoDB para que corran con sus cuentas dedicadas.

.DESCRIPTION
  Usa el metodo Change de Win32_Service (CIM) en lugar de "sc.exe config ... password= ...":
  asi la contraseña nunca aparece en la linea de comandos de un proceso, que cualquier usuario
  del equipo puede listar.

  Ejecutar como Administrador DESPUES de 01 y 02. Al final arranca ambos servicios y muestra
  con que cuenta corre cada proceso (evidencia para la Seccion 1 del reporte).
#>
. (Join-Path $PSScriptRoot '..\00_parametros.ps1')
Assert-Administrador

function Set-CuentaServicio {
    param([Parameter(Mandatory)][string]$Servicio, [Parameter(Mandatory)][string]$Cuenta)
    $svc = Get-CimInstance Win32_Service -Filter "Name='$Servicio'"
    if (-not $svc) { throw "No existe el servicio $Servicio" }
    $cred = Get-Credential -UserName ".\$Cuenta" -Message "Contraseña de $Cuenta (servicio $Servicio)"
    $r = Invoke-CimMethod -InputObject $svc -MethodName Change -Arguments @{
        StartName     = ".\$Cuenta"
        StartPassword = $cred.GetNetworkCredential().Password
    }
    if ($r.ReturnValue -ne 0) { throw "Win32_Service.Change devolvio $($r.ReturnValue) para $Servicio" }
    Write-Paso "$Servicio ahora inicia sesion como .\$Cuenta" 'OK'
}

foreach ($par in @(@($P.PgServicio, $P.CuentaPg), @($P.MongoServicio, $P.CuentaMongo))) {
    $servicio, $cuenta = $par
    if (Get-Service $servicio -ErrorAction SilentlyContinue) {
        Stop-Service $servicio -Force -ErrorAction SilentlyContinue
        Set-CuentaServicio -Servicio $servicio -Cuenta $cuenta
        Start-Service $servicio
        (Get-Service $servicio).WaitForStatus('Running', '00:00:30')
        Write-Paso "$servicio en ejecucion" 'OK'
    } else {
        Write-Paso "No se encontro el servicio $servicio" 'AVISO'
    }
}

Write-Host "`n--- Evidencia 1: cuenta configurada en cada servicio ---" -ForegroundColor Cyan
Get-CimInstance Win32_Service | Where-Object { $_.Name -in $P.PgServicio, $P.MongoServicio } |
    Select-Object Name, State, StartMode, StartName | Format-Table -AutoSize

Write-Host "--- Evidencia 2: dueño real de los procesos en ejecucion ---" -ForegroundColor Cyan
Get-CimInstance Win32_Process -Filter "Name='postgres.exe' OR Name='mongod.exe'" | ForEach-Object {
    $o = Invoke-CimMethod -InputObject $_ -MethodName GetOwner
    [pscustomobject]@{ Proceso = $_.Name; PID = $_.ProcessId; Usuario = "$($o.Domain)\$($o.User)" }
} | Sort-Object Proceso -Unique | Format-Table -AutoSize

Write-Host "--- Evidencia 3: las cuentas no pertenecen a Administradores ---" -ForegroundColor Cyan
Get-LocalGroupMember -Group (Get-LocalGroup -SID $SID.Administradores) | Select-Object Name, PrincipalSource | Format-Table -AutoSize
