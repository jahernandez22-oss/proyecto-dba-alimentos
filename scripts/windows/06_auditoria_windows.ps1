<#
.SYNOPSIS
  Auditoria del lado de Windows: inicios de sesion, cambios de cuentas, cambios a los
  archivos de configuracion de los motores y bitacoras de PostgreSQL en el Visor de eventos.

.DESCRIPTION
  Por que: la base registra lo que pasa DENTRO del motor; Windows registra quien entro al
  servidor y quien toco un postgresql.conf o un mongod.cfg. Si el docente "altera una
  configuracion" en la defensa, el evento 4663 dice que cuenta lo hizo y a que hora.

  Que hace:
    1. Activa la auditoria avanzada por GUID (funciona igual con Windows en espanol).
    2. Pone una SACL (lista de auditoria) en postgresql.conf, pg_hba.conf, postgresql.auto.conf
       y mongod.cfg: toda escritura, borrado o cambio de permisos genera el evento 4663.
    3. Registra el origen "PostgreSQL" (pgevent.dll) para que sus mensajes se lean bien en el
       Visor de eventos, y el origen "AlimentosDBA" para nuestros scripts de respaldo.
    4. Agranda los registros Security y Application para que no se pierdan eventos.
    5. Crea la vista personalizada "Alimentos del Valle - Seguridad BD" en el Visor de eventos.
  Ejecutar como Administrador.
#>
. (Join-Path $PSScriptRoot '..\00_parametros.ps1')
Assert-Administrador

# 1) Directiva de auditoria avanzada
$subcategorias = [ordered]@{
    'Inicio de sesion (4624, 4625)'           = '{0CCE9215-69AE-11D9-BED3-505054503030}'
    'Bloqueo de cuenta'                       = '{0CCE9217-69AE-11D9-BED3-505054503030}'
    'Validacion de credenciales (4776)'       = '{0CCE923F-69AE-11D9-BED3-505054503030}'
    'Administracion de cuentas (4720-4740)'   = '{0CCE9235-69AE-11D9-BED3-505054503030}'
    'Administracion de grupos de seguridad'   = '{0CCE9237-69AE-11D9-BED3-505054503030}'
    'Cambio de directiva de auditoria (4719)' = '{0CCE922F-69AE-11D9-BED3-505054503030}'
    'Sistema de archivos (4663)'              = '{0CCE921D-69AE-11D9-BED3-505054503030}'
}
foreach ($s in $subcategorias.GetEnumerator()) {
    auditpol /set /subcategory:"$($s.Value)" /success:enable /failure:enable | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Paso "Auditoria activada: $($s.Key)" 'OK' }
    else { Write-Paso "No se pudo activar $($s.Key). Revisen: auditpol /list /subcategory:* /v" 'AVISO' }
}

# 2) SACL sobre los archivos de configuracion (quien los modifica queda registrado)
$archivos = @((Join-Path $P.PgData 'postgresql.conf'), (Join-Path $P.PgData 'pg_hba.conf'),
              (Join-Path $P.PgData 'postgresql.auto.conf'), $P.MongoCfg)
$todos = Get-Identidad $SID.Todos
foreach ($f in $archivos) {
    if (-not (Test-Path -LiteralPath $f)) { Write-Paso "No existe $f" 'AVISO'; continue }
    $item = Get-Item -LiteralPath $f
    $sacl = $item.GetAccessControl('Audit')
    $regla = New-Object Security.AccessControl.FileSystemAuditRule($todos,
        'Write, Delete, ChangePermissions, TakeOwnership', 'None', 'None', 'Success, Failure')
    $sacl.AddAuditRule($regla)
    $item.SetAccessControl($sacl)
    Write-Paso "SACL de escritura aplicada a $f" 'OK'
}

# 3) Origenes del Visor de eventos
$pgevent = Join-Path (Split-Path $P.PgBin -Parent) 'lib\pgevent.dll'
if (Test-Path $pgevent) {
    regsvr32 /s /n /i:PostgreSQL "$pgevent"
    Write-Paso 'Origen PostgreSQL registrado (pgevent.dll)' 'OK'
} else { Write-Paso "No se encontro $pgevent" 'AVISO' }
if (-not [Diagnostics.EventLog]::SourceExists($P.FuenteEventos)) {
    New-EventLog -LogName Application -Source $P.FuenteEventos
    Write-Paso "Origen $($P.FuenteEventos) registrado en Aplicacion" 'OK'
}

# 4) Tamaño de los registros: Security 512 MB, Application 128 MB (se sobrescriben los mas viejos)
wevtutil sl Security /ms:536870912
wevtutil sl Application /ms:134217728
Write-Paso 'Registros Security (512 MB) y Application (128 MB) ampliados' 'OK'

# 5) Vista personalizada en el Visor de eventos
$vista = @"
<ViewerConfig><QueryConfig><QueryParams><UserQuery /></QueryParams><QueryNode>
<Name>Alimentos del Valle - Seguridad BD</Name>
<Description>Accesos fallidos, bloqueos, cambios a configuraciones, PostgreSQL y respaldos</Description>
<QueryList><Query Id="0">
<Select Path="Application">*[System[Provider[@Name='PostgreSQL' or @Name='$($P.FuenteEventos)']]]</Select>
<Select Path="Security">*[System[(EventID=4625 or EventID=4740 or EventID=4663 or EventID=4719 or EventID=4720 or EventID=4724)]]</Select>
</Query></QueryList></QueryNode></QueryConfig></ViewerConfig>
"@
$carpeta = Join-Path $env:ProgramData 'Microsoft\Event Viewer\Views'
New-Item -ItemType Directory -Path $carpeta -Force | Out-Null
Set-Content -Path (Join-Path $carpeta 'AlimentosDBA_Seguridad.xml') -Value $vista -Encoding UTF8
Write-Paso 'Vista personalizada creada: Visor de eventos > Vistas personalizadas' 'OK'

Write-Host "`n--- Evidencia: auditoria activa ---" -ForegroundColor Cyan
auditpol /get /category:* | Select-String -Pattern 'Correcto|Error|Success|Failure' | Select-Object -First 25
