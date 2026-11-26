<#
.SYNOPSIS
  Deja los archivos de datos, configuracion, secretos y respaldos con permisos NTFS minimos.

.DESCRIPTION
  Por que: aunque nadie entre por la red, cualquier usuario local que pueda LEER la carpeta
  de datos puede copiar los archivos de la base y abrirlos en otra maquina, y cualquiera que
  pueda ESCRIBIR postgresql.conf, pg_hba.conf o mongod.cfg puede apagar la seguridad.
  Por eso cada carpeta queda solo para SYSTEM, Administradores y la cuenta que la necesita.

  Regla para scripts programados: la cuenta que ejecuta una tarea (svc_respaldo) puede LEER
  sus scripts pero no modificarlos; si pudiera, podria cambiar el script y escalar privilegios.

  Ejecutar como Administrador DESPUES de 01_cuentas_servicio.ps1 y con los servicios detenidos
  (el script los detiene y los deja detenidos; 03_asignar_cuentas_servicios.ps1 los arranca).
#>
. (Join-Path $PSScriptRoot '..\00_parametros.ps1')
Assert-Administrador

function Set-PermisosExclusivos {
    <# Corta la herencia, borra todas las reglas previas y deja solo las indicadas. #>
    param(
        [Parameter(Mandatory)][string]$Ruta,
        [string[]]$ControlTotal = @(),
        [string[]]$Lectura = @()
    )
    if (-not (Test-Path -LiteralPath $Ruta)) { Write-Paso "No existe $Ruta (se omite)" 'AVISO'; return }
    $item = Get-Item -LiteralPath $Ruta
    $acl  = $item.GetAccessControl('Access')           # solo la DACL: no toca el propietario
    $acl.SetAccessRuleProtection($true, $false)       # sin herencia del padre
    foreach ($r in @($acl.Access)) { if (-not $r.IsInherited) { [void]$acl.RemoveAccessRuleSpecific($r) } }
    $herencia = if ($item.PSIsContainer) { 'ContainerInherit,ObjectInherit' } else { 'None' }
    foreach ($c in $ControlTotal) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((Get-Identidad $c), 'FullControl', $herencia, 'None', 'Allow')))
    }
    foreach ($c in $Lectura) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((Get-Identidad $c), 'ReadAndExecute', $herencia, 'None', 'Allow')))
    }
    $item.SetAccessControl($acl)
    if ($item.PSIsContainer) { icacls "$Ruta\*" /reset /T /C /Q | Out-Null }   # los hijos heredan de esta carpeta
    Write-Paso "Permisos exclusivos aplicados en $Ruta" 'OK'
}

function Add-LecturaArchivo {
    <# Agrega lectura explicita sobre un archivo puntual (por ejemplo, para el respaldo de configs). #>
    param([string]$Ruta, [string]$Cuenta)
    if (-not (Test-Path -LiteralPath $Ruta)) { return }
    $item = Get-Item -LiteralPath $Ruta
    $acl  = $item.GetAccessControl('Access')
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((Get-Identidad $Cuenta), 'Read', 'None', 'None', 'Allow')))
    $item.SetAccessControl($acl)
}

# 0) Carpetas del equipo
foreach ($d in @($P.RaizDBA, $P.ConfigMaestra, $P.Secretos, $P.SecretosAdmin, $P.LogsScripts,
                 $P.Respaldos, (Join-Path $P.Respaldos 'postgresql'), (Join-Path $P.Respaldos 'mongodb'),
                 (Join-Path $P.Respaldos 'config'), (Join-Path $P.Respaldos 'wal'),
                 $P.MongoData, $P.MongoLog, $P.MongoSeguridad)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null; Write-Paso "Creada $d" }
}

# 1) Detener servicios para que no tengan archivos abiertos
foreach ($s in @($P.PgServicio, $P.MongoServicio)) {
    if (Get-Service $s -ErrorAction SilentlyContinue) { Stop-Service $s -Force; Write-Paso "Servicio $s detenido" }
}

$base = @($SID.SYSTEM, $SID.Administradores)

# 2) Datos de PostgreSQL: solo el motor
Set-PermisosExclusivos -Ruta $P.PgData -ControlTotal ($base + $P.CuentaPg)
foreach ($f in 'postgresql.conf', 'pg_hba.conf', 'postgresql.auto.conf') {
    Add-LecturaArchivo -Ruta (Join-Path $P.PgData $f) -Cuenta $P.CuentaRespaldo   # para respaldar configs
}

# 3) MongoDB: datos y bitacoras solo para el motor; llave y config solo lectura
Set-PermisosExclusivos -Ruta $P.MongoData      -ControlTotal ($base + $P.CuentaMongo)
Set-PermisosExclusivos -Ruta $P.MongoLog       -ControlTotal ($base + $P.CuentaMongo)
Set-PermisosExclusivos -Ruta $P.MongoSeguridad -ControlTotal $base -Lectura $P.CuentaMongo
Set-PermisosExclusivos -Ruta $P.MongoCfg       -ControlTotal $base -Lectura @($P.CuentaMongo, $P.CuentaRespaldo)

# 4) Carpetas del equipo: scripts y configs maestras de solo lectura para svc_respaldo
Set-PermisosExclusivos -Ruta $P.RaizDBA     -ControlTotal $base -Lectura $P.CuentaRespaldo
Set-PermisosExclusivos -Ruta $P.Secretos    -ControlTotal $base -Lectura $P.CuentaRespaldo
# Credenciales para RESTAURAR (postgres, restaurador): ni svc_respaldo puede leerlas
Set-PermisosExclusivos -Ruta $P.SecretosAdmin -ControlTotal $base
Set-PermisosExclusivos -Ruta $P.LogsScripts -ControlTotal ($base + $P.CuentaRespaldo)

# 5) Respaldos: escribe svc_respaldo; el archivo WAL lo escribe el propio PostgreSQL
Set-PermisosExclusivos -Ruta $P.Respaldos -ControlTotal ($base + $P.CuentaRespaldo)
Set-PermisosExclusivos -Ruta (Join-Path $P.Respaldos 'wal') -ControlTotal ($base + $P.CuentaPg + $P.CuentaRespaldo)

# 6) Evidencia para el reporte
Write-Host "`n--- Evidencia: permisos resultantes (icacls) ---" -ForegroundColor Cyan
foreach ($r in @($P.PgData, $P.MongoData, $P.MongoLog, $P.MongoCfg, $P.Secretos, $P.Respaldos)) {
    if (Test-Path -LiteralPath $r) { icacls $r; Write-Host '' }
}
Write-Paso 'Siguiente paso: 03_asignar_cuentas_servicios.ps1' 'INFO'
