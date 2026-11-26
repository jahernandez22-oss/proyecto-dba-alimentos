<#
.SYNOPSIS
  Reproduce la "crisis de temporada alta" y la mide desde Windows: corre el reporte mensual
  mientras las cajas cobran, y registra CPU, transacciones por segundo y latencia de las cajas.

.DESCRIPTION
  Antes de la optimizacion, el reporte usa varios nucleos al 100 % y la latencia de las cajas
  sube. Despues (indices + vista materializada + limites por rol) el reporte tarda milisegundos
  y las cajas no lo notan. Esta comparacion es la evidencia de Windows para la Seccion 4.

  Las cajas se simulan con pgbench (viene con PostgreSQL): 4 conexiones como app_ventas
  consultando precios y existencias durante -Segundos.

  Requiere C:\DBA\secretos\pgpass_pruebas.conf con dos lineas (formato pgpass):
      127.0.0.1:15432:alimentos_erp:app_ventas:<contraseña>
      127.0.0.1:15432:alimentos_erp:app_reportes:<contraseña>
  Uso:
      .\10_medir_cpu.ps1 -Escenario antes      (despues de 08_datos_masivos.sql, ANTES de 10_optimizacion.sql)
      .\10_medir_cpu.ps1 -Escenario despues    (despues de 10_optimizacion.sql)
#>
param([ValidateSet('antes', 'despues')][string]$Escenario = 'antes', [int]$Segundos = 45)
. (Join-Path $PSScriptRoot '..\00_parametros.ps1')
$pgpass = Join-Path $P.Secretos 'pgpass_pruebas.conf'
if (-not (Test-Path $pgpass)) { throw "Falta $pgpass (ver la ayuda del script)" }
$env:PGPASSFILE = $pgpass
$psql = Join-Path $P.PgBin 'psql.exe'
$pgbench = Join-Path $P.PgBin 'pgbench.exe'

$sqlReporte = if ($Escenario -eq 'antes') {
@"
SELECT s.nombre, p.categoria, count(DISTINCT f.id), sum(d.cantidad), sum(d.importe)
FROM erp.facturas f JOIN erp.detalle_factura d ON d.factura_id = f.id
JOIN erp.productos p ON p.id = d.producto_id JOIN erp.sucursales s ON s.id = f.sucursal_id
WHERE to_char(f.fecha, 'YYYY-MM') = to_char(now() - interval '1 month', 'YYYY-MM') AND f.estado <> 'CANCELADA'
GROUP BY s.nombre, p.categoria ORDER BY 5 DESC;
"@ } else {
@"
SELECT sucursal, categoria, facturas, piezas, venta FROM reportes.mv_ventas_mensuales
WHERE mes = date_trunc('month', now() - interval '1 month')::date ORDER BY venta DESC;
"@ }

# Carga de las cajas: consultas cortas, como las de un punto de venta
$caja = Join-Path $env:TEMP 'caja_pgbench.sql'
Set-Content -Path $caja -Encoding ASCII -Value @'
\set prod random(1, 2000)
\set fac random(1, 100000)
SELECT nombre, precio_lista FROM erp.productos WHERE id = :prod;
SELECT folio, total, estado FROM erp.facturas WHERE id = :fac;
'@

Write-Paso "Escenario $($Escenario.ToUpper()): $Segundos s de cajas cobrando mientras corre el reporte" 'INFO'

# 1) Muestreo de CPU cada segundo (WMI: no depende del idioma de Windows)
$cpu = Start-Job -ArgumentList ($Segundos + 5) -ScriptBlock {
    param($n)
    1..$n | ForEach-Object {
        (Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime
        Start-Sleep -Seconds 1
    }
}
# 2) El reporte, una y otra vez, como app_reportes
$reporte = Start-Job -ArgumentList $psql, $pgpass, $sqlReporte, $Segundos, $P.PgPuerto, $P.PgBase -ScriptBlock {
    param($psql, $pgpass, $sql, $seg, $puerto, $base)
    $env:PGPASSFILE = $pgpass
    $fin = (Get-Date).AddSeconds($seg)
    while ((Get-Date) -lt $fin) {
        (Measure-Command { & $psql -h 127.0.0.1 -p $puerto -U app_reportes -d $base -q -c $sql | Out-Null }).TotalMilliseconds
    }
}
Start-Sleep -Seconds 2
# 3) Las cajas (pgbench) durante el mismo tiempo
$salidaBench = & $pgbench -h 127.0.0.1 -p $P.PgPuerto -U app_ventas -d $P.PgBase -n -c 4 -j 2 -T ($Segundos - 4) -f $caja 2>&1 | Out-String

$muestras = Receive-Job $cpu -Wait -AutoRemoveJob
$tiempos = Receive-Job $reporte -Wait -AutoRemoveJob
$tps = if ($salidaBench -match 'tps = ([\d.]+)') { [double]$matches[1] } else { $null }
$lat = if ($salidaBench -match 'latency average = ([\d.]+) ms') { [double]$matches[1] } else { $null }

$fila = [pscustomobject]@{
    Escenario            = $Escenario
    CPU_promedio_pct     = [math]::Round((($muestras | Measure-Object -Average).Average), 1)
    CPU_maxima_pct       = ($muestras | Measure-Object -Maximum).Maximum
    Reportes_ejecutados  = @($tiempos).Count
    Reporte_promedio_ms  = [math]::Round((($tiempos | Measure-Object -Average).Average), 0)
    Cajas_tps            = $tps
    Cajas_latencia_ms    = $lat
}
$fila | Format-List
$csv = Join-Path $P.LogsScripts 'medicion_cpu_cajas.csv'
$fila | Export-Csv $csv -NoTypeInformation -Encoding UTF8 -Append
Write-Paso "Resultado agregado a $csv (corre ambos escenarios para tener la comparacion)" 'OK'
if (-not $tps) { Write-Host $salidaBench }
