<#
.SYNOPSIS
  Crea las cuentas de servicio sin privilegios y les asigna solo los derechos que necesitan.

.DESCRIPTION
  Por que: si un motor corre como Administrador o SYSTEM y un atacante logra ejecutar codigo
  a traves de el (por ejemplo con COPY ... PROGRAM en PostgreSQL), hereda el control total
  de Windows. Con una cuenta estandar dedicada, el dano se queda dentro de esa cuenta.

  Que hace:
    1. Crea svc_postgres, svc_mongodb y svc_respaldo como usuarios estandar.
    2. Se asegura de que NO esten en el grupo Administradores.
    3. Otorga "Iniciar sesion como servicio" (motores) o "como proceso por lotes" (respaldos).
    4. Niega el inicio de sesion interactivo y por Escritorio remoto a las tres.

  Ejecutar como Administrador. Pide la contraseña de cada cuenta (minimo 16 caracteres);
  guardenlas en el gestor de contraseñas del equipo.
#>
. (Join-Path $PSScriptRoot '..\00_parametros.ps1')
Assert-Administrador

function Set-DerechoUsuario {
    <# Agrega una cuenta a un derecho de usuario de la directiva local (secedit). #>
    param([Parameter(Mandatory)][string]$Cuenta, [Parameter(Mandatory)][string]$Derecho)
    $sidCuenta = (Get-Identidad $Cuenta).Translate([Security.Principal.SecurityIdentifier]).Value
        if (-not $sidCuenta) { throw "No existe la cuenta ${Cuenta}; no se asigna $Derecho" }
    $inf = Join-Path $env:TEMP ("derechos_{0}.inf" -f [guid]::NewGuid())
    $sdb = Join-Path $env:TEMP ("derechos_{0}.sdb" -f [guid]::NewGuid())
    secedit /export /areas USER_RIGHTS /cfg $inf | Out-Null
    $lineas = [System.Collections.Generic.List[string]](Get-Content $inf -Encoding Unicode)
    $i = -1
    for ($k = 0; $k -lt $lineas.Count; $k++) { if ($lineas[$k] -match "^$Derecho\s*=") { $i = $k } }
    if ($i -ge 0) {
        $valores = (($lineas[$i] -split '=', 2)[1] -split ',') | ForEach-Object { $_.Trim() }
        if (($valores -contains "*$sidCuenta") -or ($valores -contains $Cuenta)) {
            Write-Paso "  $Cuenta ya tenia $Derecho" 'INFO'
            Remove-Item $inf -ErrorAction SilentlyContinue
            return
        }
        $lineas[$i] = $lineas[$i] + ",*$sidCuenta"
    } else {
        $pos = $lineas.IndexOf('[Privilege Rights]')
        if ($pos -lt 0) { throw 'No se encontro la seccion [Privilege Rights] en la exportacion de secedit.' }
        $lineas.Insert($pos + 1, "$Derecho = *$sidCuenta")
    }
    Set-Content -Path $inf -Value $lineas -Encoding Unicode
    secedit /configure /db $sdb /cfg $inf /areas USER_RIGHTS /quiet | Out-Null
    Remove-Item $inf, $sdb -ErrorAction SilentlyContinue
    Write-Paso "  $Derecho otorgado a $Cuenta" 'OK'
}

$cuentas = @(
    @{ Nombre = $P.CuentaPg;       Descripcion = 'Servicio de PostgreSQL (sin privilegios)'; Derecho = 'SeServiceLogonRight' },
    @{ Nombre = $P.CuentaMongo;    Descripcion = 'Servicio de MongoDB (sin privilegios)';    Derecho = 'SeServiceLogonRight' },
    @{ Nombre = $P.CuentaRespaldo; Descripcion = 'Ejecuta las tareas programadas de respaldo';          Derecho = 'SeBatchLogonRight' }
)

$grupoAdmins = Get-LocalGroup -SID $SID.Administradores

foreach ($c in $cuentas) {
    Write-Paso "Cuenta $($c.Nombre)"
    if (-not (Get-LocalUser -Name $c.Nombre -ErrorAction SilentlyContinue)) {
        $clave = Read-Host "  Contraseña para $($c.Nombre) (minimo 16 caracteres)" -AsSecureString
        New-LocalUser -Name $c.Nombre -Password $clave -Description $c.Descripcion `
            -PasswordNeverExpires -UserMayNotChangePassword -AccountNeverExpires -ErrorAction Stop | Out-Null | Out-Null
        Write-Paso "  creada como usuario estandar" 'OK'
    } else {
        Write-Paso "  ya existia" 'INFO'
    }

    # Nunca debe ser administradora
    try {
        $esAdmin = Get-LocalGroupMember -Group $grupoAdmins -ErrorAction Stop |
            Where-Object { $_.Name -match "\\$($c.Nombre)$" }
        if ($esAdmin) {
            Remove-LocalGroupMember -Group $grupoAdmins -Member $c.Nombre
            Write-Paso "  retirada del grupo Administradores" 'AVISO'
        }
    } catch {
        Write-Paso "  no se pudo leer el grupo Administradores: $($_.Exception.Message)" 'AVISO'
    }

    Set-DerechoUsuario -Cuenta $c.Nombre -Derecho $c.Derecho
    Set-DerechoUsuario -Cuenta $c.Nombre -Derecho 'SeDenyInteractiveLogonRight'
    Set-DerechoUsuario -Cuenta $c.Nombre -Derecho 'SeDenyRemoteInteractiveLogonRight'
}

Write-Host "`n--- Evidencia: cuentas creadas y su pertenencia a grupos ---" -ForegroundColor Cyan
Get-LocalUser -Name $P.CuentaPg, $P.CuentaMongo, $P.CuentaRespaldo |
    Select-Object Name, Enabled, PasswordExpires, Description | Format-Table -AutoSize
foreach ($c in $cuentas) {
    $grupos = Get-LocalGroup | Where-Object {
        try { (Get-LocalGroupMember -Group $_ -ErrorAction Stop).Name -match "\\$($c.Nombre)$" } catch { $false }
    }
    Write-Host ("{0,-14} grupos: {1}" -f $c.Nombre, (($grupos.Name) -join ', '))
}
Write-Paso 'Siguiente paso: 02_permisos_ntfs.ps1' 'INFO'
