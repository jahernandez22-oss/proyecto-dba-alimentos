<#
.SYNOPSIS
  Regresa las configuraciones a la copia maestra sellada y reinicia los motores. Es la respuesta a
  "el docente altero una configuracion" de la prueba en vivo.

.DESCRIPTION
  1. Corre verificar_integridad.ps1 para mostrar QUE archivo cambio y QUIEN lo cambio (evento 4663).
  2. Copia la version buena desde C:\DBA\config sobre cada archivo ALTERADO (solo esos).
  3. Reinicia el motor afectado y comprueba que escuche en su puerto.
  4. Vuelve a verificar: todo debe quedar OK.
  Uso: .\restaurar_config.ps1            (detecta y corrige)
       .\restaurar_config.ps1 -Todo      (copia las cuatro configuraciones aunque no se detecte cambio)
#>
param([switch]$Todo)
. (Join-Path $PSScriptRoot '..\00_parametros.ps1')
Assert-Administrador
$reloj = [Diagnostics.Stopwatch]::StartNew()

$destinos = [ordered]@{
    'postgresql.conf'      = @{ Ruta = (Join-Path $P.PgData 'postgresql.conf');      Servicio = $P.PgServicio;    Puerto = $P.PgPuerto }
    'pg_hba.conf'          = @{ Ruta = (Join-Path $P.PgData 'pg_hba.conf');          Servicio = $P.PgServicio;    Puerto = $P.PgPuerto }
    'postgresql.auto.conf' = @{ Ruta = (Join-Path $P.PgData 'postgresql.auto.conf'); Servicio = $P.PgServicio;    Puerto = $P.PgPuerto }
    'mongod.cfg'           = @{ Ruta = $P.MongoCfg;                                 Servicio = $P.MongoServicio; Puerto = $P.MongoPuerto }
}
$huellas = Get-Content (Join-Path $P.ConfigMaestra 'huellas.json') -Raw | ConvertFrom-Json

& (Join-Path $PSScriptRoot 'verificar_integridad.ps1')
$reiniciar = @{}
foreach ($d in $destinos.GetEnumerator()) {
    $actual = if (Test-Path -LiteralPath $d.Value.Ruta) { (Get-FileHash -LiteralPath $d.Value.Ruta -Algorithm SHA256).Hash } else { '' }
    if ($Todo -or $actual -ne $huellas.($d.Key)) {
        # Se sobrescribe el CONTENIDO del archivo existente: conserva sus permisos y su SACL de auditoria
        [IO.File]::WriteAllBytes($d.Value.Ruta, [IO.File]::ReadAllBytes((Join-Path $P.ConfigMaestra $d.Key)))
        $reiniciar[$d.Value.Servicio] = $d.Value.Puerto
        Write-Paso "Restaurado $($d.Key) desde la copia maestra" 'OK'
    }
}
foreach ($s in $reiniciar.GetEnumerator()) {
    Restart-Service $s.Key -Force
    (Get-Service $s.Key).WaitForStatus('Running', '00:01:00')
    $escucha = $null
    for ($i = 0; $i -lt 20 -and -not $escucha; $i++) {
        Start-Sleep -Seconds 1
        $escucha = Get-NetTCPConnection -State Listen -LocalPort $s.Value -ErrorAction SilentlyContinue
    }
    Write-Paso "$($s.Key) reiniciado; escuchando en $($s.Value): $([bool]$escucha)" $(if ($escucha) { 'OK' } else { 'ERROR' })
}
& (Join-Path $PSScriptRoot 'verificar_integridad.ps1')
$reloj.Stop()
$msg = "Configuraciones restauradas en $([math]::Round($reloj.Elapsed.TotalSeconds, 1)) s (RTO). Servicios reiniciados: $($reiniciar.Keys -join ', ')"
Write-EventoDBA -Mensaje $msg -Id 1100
Write-Paso $msg 'OK'
