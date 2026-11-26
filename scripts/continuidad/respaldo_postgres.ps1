<#
.SYNOPSIS
  Respaldo logico de PostgreSQL con pg_dump (formato custom) + roles + manifiesto de validacion.

.DESCRIPTION
  Que deja en E:\Respaldos\postgresql\<yyyyMMdd_HHmmss>\:
    alimentos_erp.dump   pg_dump -Fc: comprimido, permite restaurar en paralelo (-j) o por tabla
    globales.sql         roles y membresias (pg_dumpall --globals-only, SIN contraseñas)
    manifiesto.json      conteo de filas por tabla y SHA-256 de cada archivo, para validar la restauracion
  Por que formato custom y no .sql plano: pg_restore puede paralelizar y elegir objetos; con un .sql
  plano la restauracion es secuencial y mas lenta (afecta el RTO).

  Se conecta como el rol "respaldo" (pg_read_all_data: lee todo, no modifica nada) y lee la
  contraseña de C:\DBA\secretos\pgpass.conf (variable PGPASSFILE), nunca de la linea de comandos.
  Normalmente lo llama respaldo_completo.ps1 desde el Programador de tareas (cuenta svc_respaldo).
#>
param([string]$Destino)
. (Join-Path $PSScriptRoot '..\00_parametros.ps1')
$ErrorActionPreference = 'Stop'

$env:PGPASSFILE = Join-Path $P.Secretos 'pgpass.conf'
$sello = Get-Date -Format 'yyyyMMdd_HHmmss'
if (-not $Destino) { $Destino = Join-Path (Join-Path $P.Respaldos 'postgresql') $sello }
New-Item -ItemType Directory -Path $Destino -Force | Out-Null
$bin = $P.PgBin
$conexion = @('-h', '127.0.0.1', '-p', "$($P.PgPuerto)", '-U', 'respaldo', '-w')
$reloj = [Diagnostics.Stopwatch]::StartNew()

# 1) Conteo de filas ANTES del respaldo (queda en el manifiesto para comparar al restaurar)
$sqlConteo = @"
SELECT json_object_agg(t, n) FROM (
  SELECT 'erp.facturas' t, count(*) n FROM erp.facturas UNION ALL
  SELECT 'erp.detalle_factura', count(*) FROM erp.detalle_factura UNION ALL
  SELECT 'erp.clientes', count(*) FROM erp.clientes UNION ALL
  SELECT 'erp.productos', count(*) FROM erp.productos UNION ALL
  SELECT 'erp.pagos', count(*) FROM erp.pagos UNION ALL
  SELECT 'nomina.empleados', count(*) FROM nomina.empleados UNION ALL
  SELECT 'seguridad.tarjetas_vip', count(*) FROM seguridad.tarjetas_vip UNION ALL
  SELECT 'auditoria.bitacora_cambios', count(*) FROM auditoria.bitacora_cambios) x;
"@
$conteo = & (Join-Path $bin 'psql.exe') @conexion -d $P.PgBase -At -c $sqlConteo
if ($LASTEXITCODE -ne 0) { throw "No se pudo contar filas (psql salio con $LASTEXITCODE)" }

# 2) La base completa
$dump = Join-Path $Destino "$($P.PgBase).dump"
& (Join-Path $bin 'pg_dump.exe') @conexion -d $P.PgBase -Fc -Z 6 -f $dump
if ($LASTEXITCODE -ne 0) { throw "pg_dump fallo con codigo $LASTEXITCODE" }

# 3) Roles y membresias (las contraseñas no se respaldan: se reasignan desde el gestor)
$globales = Join-Path $Destino 'globales.sql'
& (Join-Path $bin 'pg_dumpall.exe') @conexion -l postgres --globals-only --no-role-passwords -f $globales
if ($LASTEXITCODE -ne 0) { throw "pg_dumpall --globals-only fallo con codigo $LASTEXITCODE" }

# 4) Verificacion: el archivo se puede leer de punta a punta (lista su contenido)
$objetos = & (Join-Path $bin 'pg_restore.exe') -l $dump
if ($LASTEXITCODE -ne 0 -or -not $objetos) { throw 'El archivo de respaldo no se puede leer con pg_restore -l' }

# 5) Manifiesto
$reloj.Stop()
$manifiesto = [ordered]@{
    motor        = 'postgresql'
    fecha        = (Get-Date).ToString('o')
    base         = $P.PgBase
    duracion_s   = [math]::Round($reloj.Elapsed.TotalSeconds, 1)
    objetos      = @($objetos | Where-Object { $_ -and $_ -notmatch '^;' }).Count
    conteos      = ($conteo | ConvertFrom-Json)
    archivos     = @(Get-ChildItem $Destino -File | ForEach-Object {
                    [ordered]@{ nombre = $_.Name; bytes = $_.Length; sha256 = (Get-FileHash $_.FullName -Algorithm SHA256).Hash } })
}
$manifiesto | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $Destino 'manifiesto.json') -Encoding UTF8

$mb = [math]::Round(((Get-ChildItem $Destino -File | Measure-Object Length -Sum).Sum / 1MB), 1)
Write-Paso "PostgreSQL respaldado en $Destino ($mb MB, $($manifiesto.duracion_s) s)" 'OK'
[pscustomobject]@{ Motor = 'PostgreSQL'; Carpeta = $Destino; MB = $mb; Segundos = $manifiesto.duracion_s }
