<#
.SYNOPSIS
  Junta en CSV la evidencia de auditoria de las ultimas horas: PostgreSQL, MongoDB, Windows y
  Firewall. Es la materia prima de la Seccion 3 del reporte ("Bitacora de Auditoria").

.DESCRIPTION
  Crea C:\DBA\logs\evidencias_<fecha>\ con:
    postgresql_eventos.csv   accesos fallidos, rechazos de pg_hba, DDL y cambios de contraseña
    postgresql_visor.csv     lo mismo, visto desde el Visor de eventos (origen PostgreSQL)
    mongodb_auditoria.csv    autenticaciones, DDL y cambios de usuarios del audit.json
    windows_seguridad.csv    4625 (inicio fallido), 4740 (bloqueo), 4663 (cambio a un config), 4719
    firewall_descartes.csv   paquetes descartados por IP de origen y puerto
  y muestra un resumen. Ejecutar como Administrador. Uso: .\09_recolectar_evidencias.ps1 -Horas 24
#>
param([int]$Horas = 24)
. (Join-Path $PSScriptRoot '..\00_parametros.ps1')
Assert-Administrador
$desde = (Get-Date).AddHours(-$Horas)
$salida = Join-Path $P.LogsScripts ("evidencias_{0}" -f (Get-Date -Format 'yyyyMMdd_HHmm'))
New-Item -ItemType Directory -Path $salida -Force | Out-Null
$resumen = [ordered]@{}

# ---------- PostgreSQL: archivos de log ----------
$patrones = [ordered]@{
    'Acceso fallido (contraseña)'   = 'password authentication failed|autentificaci.n password fall'
    'Rechazo por pg_hba.conf'       = 'no pg_hba.conf entry|pg_hba.conf rejects'
    'Cambio de contraseña'          = 'statement: ALTER (ROLE|USER) .* PASSWORD'
    'DDL'                           = 'statement: (CREATE|ALTER|DROP|GRANT|REVOKE|TRUNCATE|COMMENT)'
    'Conexion autorizada'           = 'connection authorized'
    'Consulta lenta'                = 'duration: \d+'
}
$logsPg = Get-ChildItem (Join-Path $P.PgData 'log') -Filter '*.log' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -ge $desde }
$filasPg = foreach ($f in $logsPg) {
    foreach ($linea in (Get-Content $f.FullName -Encoding UTF8)) {
        foreach ($pat in $patrones.GetEnumerator()) {
            if ($linea -match $pat.Value) {
                [pscustomobject]@{ Archivo = $f.Name; Tipo = $pat.Key; Linea = $linea.Trim() }
                break
            }
        }
    }
}
$filasPg | Export-Csv (Join-Path $salida 'postgresql_eventos.csv') -NoTypeInformation -Encoding UTF8
foreach ($g in ($filasPg | Group-Object Tipo)) { $resumen["PostgreSQL · $($g.Name)"] = $g.Count }

# ---------- PostgreSQL: Visor de eventos ----------
$visor = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'PostgreSQL'; StartTime = $desde } -ErrorAction SilentlyContinue |
    Where-Object { $_.Message -match 'authentication failed|pg_hba|statement:' } |
    Select-Object TimeCreated, Id, LevelDisplayName, @{ n = 'Mensaje'; e = { $_.Message.Trim() } }
$visor | Export-Csv (Join-Path $salida 'postgresql_visor.csv') -NoTypeInformation -Encoding UTF8
$resumen['Visor de eventos · PostgreSQL (seguridad)'] = @($visor).Count

# ---------- MongoDB: audit.json ----------
$audit = Join-Path $P.MongoLog 'audit.json'
$filasMo = @()
if (Test-Path $audit) {
    $filasMo = Get-Content $audit -Tail 20000 -Encoding UTF8 | ForEach-Object {
        try { $e = $_ | ConvertFrom-Json } catch { return }
        $momento = [datetime]$e.ts.'$date'
        if ($momento -lt $desde) { return }
        $usuario = if ($e.param.user) { "$($e.param.user)@$($e.param.db)" } elseif ($e.users) { ($e.users | ForEach-Object { "$($_.user)@$($_.db)" }) -join ',' } else { '' }
        [pscustomobject]@{
            Momento   = $momento
            Evento    = $e.atype
            Usuario   = $usuario
            IPOrigen  = $e.remote.ip
            Resultado = $(if ($e.result -eq 0) { 'OK' } elseif ($e.result -eq 18) { 'FALLO: credenciales' } else { "codigo $($e.result)" })
            Detalle   = ($e.param | ConvertTo-Json -Compress -Depth 4)
        }
    }
}
$filasMo | Export-Csv (Join-Path $salida 'mongodb_auditoria.csv') -NoTypeInformation -Encoding UTF8
foreach ($g in ($filasMo | Group-Object Evento, Resultado)) { $resumen["MongoDB · $($g.Name)"] = $g.Count }

# ---------- Windows: registro Security ----------
$nombres = @{ 4625 = 'Inicio de sesion fallido'; 4740 = 'Cuenta bloqueada'; 4663 = 'Acceso a archivo auditado'; 4719 = 'Cambio de directiva de auditoria' }
$seg = Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4625, 4740, 4663, 4719; StartTime = $desde } -ErrorAction SilentlyContinue |
    ForEach-Object {
        $d = @{}; ([xml]$_.ToXml()).Event.EventData.Data | ForEach-Object { $d[$_.Name] = $_.'#text' }
        [pscustomobject]@{
            Momento  = $_.TimeCreated
            Id       = $_.Id
            Evento   = $nombres[$_.Id]
            Cuenta   = $(if ($d.TargetUserName) { $d.TargetUserName } else { $d.SubjectUserName })
            Origen   = $d.IpAddress
            Objeto   = $d.ObjectName
            Proceso  = $d.ProcessName
        }
    }
$seg | Export-Csv (Join-Path $salida 'windows_seguridad.csv') -NoTypeInformation -Encoding UTF8
foreach ($g in ($seg | Group-Object Evento)) { $resumen["Windows · $($g.Name)"] = $g.Count }

# ---------- Firewall: paquetes descartados ----------
$fw = Join-Path $env:SystemRoot 'System32\LogFiles\Firewall\pfirewall.log'
$descartes = @()
if (Test-Path $fw) {
    $descartes = Get-Content $fw | Where-Object { $_ -match ' DROP ' } | ForEach-Object {
        $c = $_ -split ' '
        [pscustomobject]@{ Fecha = "$($c[0]) $($c[1])"; Protocolo = $c[3]; IPOrigen = $c[4]; IPDestino = $c[5]; PuertoDestino = $c[7] }
    } | Where-Object { [datetime]$_.Fecha -ge $desde }
}
$descartes | Group-Object IPOrigen, PuertoDestino | Sort-Object Count -Descending |
    Select-Object @{ n = 'IPOrigen_Puerto'; e = { $_.Name } }, Count |
    Export-Csv (Join-Path $salida 'firewall_descartes.csv') -NoTypeInformation -Encoding UTF8
$resumen['Firewall · paquetes descartados'] = @($descartes).Count

# ---------- Resumen ----------
Write-Host "`n=== Evidencia de auditoria de las ultimas $Horas horas ===" -ForegroundColor Cyan
$resumen.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Fuente = $_.Key; Eventos = $_.Value } } | Format-Table -AutoSize
Write-Paso "CSV guardados en $salida" 'OK'
