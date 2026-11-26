<#
.SYNOPSIS
  Detecta si alguien altero postgresql.conf, pg_hba.conf, postgresql.auto.conf o mongod.cfg,
  comparando su SHA-256 contra la "copia maestra" sellada en C:\DBA\config.

.DESCRIPTION
  Uso:
    .\verificar_integridad.ps1 -Sellar   Guarda las configuraciones actuales como copia maestra
                                         (hacerlo cada vez que el equipo cambie una config A PROPOSITO).
    .\verificar_integridad.ps1           Compara; si algo cambio, lo muestra, escribe el evento 2001 en
                                         el Visor y dice quien lo modifico (evento 4663 de la Guia 2).
  restaurar_config.ps1 usa la copia maestra para regresar todo a su estado bueno.
#>
param([switch]$Sellar)
. (Join-Path $PSScriptRoot '..\00_parametros.ps1')
Assert-Administrador

$archivos = [ordered]@{
    'postgresql.conf'      = Join-Path $P.PgData 'postgresql.conf'
    'pg_hba.conf'          = Join-Path $P.PgData 'pg_hba.conf'
    'postgresql.auto.conf' = Join-Path $P.PgData 'postgresql.auto.conf'
    'mongod.cfg'           = $P.MongoCfg
}
$huellas = Join-Path $P.ConfigMaestra 'huellas.json'

if ($Sellar) {
    New-Item -ItemType Directory -Path $P.ConfigMaestra -Force | Out-Null
    $registro = [ordered]@{}
    foreach ($a in $archivos.GetEnumerator()) {
        Copy-Item -LiteralPath $a.Value -Destination (Join-Path $P.ConfigMaestra $a.Key) -Force
        $registro[$a.Key] = (Get-FileHash -LiteralPath $a.Value -Algorithm SHA256).Hash
    }
    $registro['sellado'] = (Get-Date).ToString('o')
    $registro | ConvertTo-Json | Set-Content $huellas -Encoding UTF8
    Write-Paso "Copia maestra sellada en $($P.ConfigMaestra)" 'OK'
    return
}

if (-not (Test-Path $huellas)) { throw 'No hay copia maestra. Corre primero: .\verificar_integridad.ps1 -Sellar' }
$esperado = Get-Content $huellas -Raw | ConvertFrom-Json
$resultado = foreach ($a in $archivos.GetEnumerator()) {
    $actual = if (Test-Path -LiteralPath $a.Value) { (Get-FileHash -LiteralPath $a.Value -Algorithm SHA256).Hash } else { 'NO EXISTE' }
    $quien = ''
    if ($actual -ne $esperado.($a.Key)) {
        $ev = Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4663 } -MaxEvents 300 -ErrorAction SilentlyContinue |
              Where-Object { $_.Message -match [regex]::Escape((Split-Path $a.Value -Leaf)) } | Select-Object -First 1
        if ($ev) {
            $d = @{}; ([xml]$ev.ToXml()).Event.EventData.Data | ForEach-Object { $d[$_.Name] = $_.'#text' }
            $quien = "$($d.SubjectDomainName)\$($d.SubjectUserName) con $(Split-Path $d.ProcessName -Leaf) a las $($ev.TimeCreated)"
        }
    }
    [pscustomobject]@{ Archivo = $a.Key; Estado = $(if ($actual -eq $esperado.($a.Key)) { 'OK' } else { 'ALTERADO' }); Modificado_por = $quien }
}
$resultado | Format-Table -AutoSize -Wrap
$alterados = @($resultado | Where-Object Estado -ne 'OK')
if ($alterados.Count) {
    $msg = "Configuracion alterada: " + (($alterados | ForEach-Object { "$($_.Archivo) [$($_.Modificado_por)]" }) -join '; ') +
           ". Para regresar al estado bueno: restaurar_config.ps1"
    Write-EventoDBA -Mensaje $msg -Id 2001 -Tipo Warning
    Write-Paso $msg 'AVISO'
    exit 2
}
Write-Paso 'Todas las configuraciones coinciden con la copia maestra' 'OK'
