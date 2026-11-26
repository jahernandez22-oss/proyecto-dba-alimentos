<#
.SYNOPSIS
  Respaldo FISICO base de PostgreSQL (pg_basebackup) para recuperar a un punto en el tiempo (PITR).

.DESCRIPTION
  Como funciona el PITR: PostgreSQL escribe cada cambio primero en el WAL (diario de transacciones).
  Con archive_mode = on (Fase 4 del bloque de hardening) cada segmento de WAL se copia a
  E:\Respaldos\wal. Un respaldo base + todos los WAL posteriores permiten "reproducir" la historia
  hasta el segundo que elijamos, por ejemplo un minuto antes de un DELETE accidental.
  pg_dump (respaldo logico) es una foto; base + WAL es la pelicula completa.

  Que hace: pg_basebackup en formato plano a E:\Respaldos\postgresql_base\<fecha>, lo verifica con
  pg_verifybackup, conserva los 2 mas recientes y borra el WAL que ya no necesita ninguna base
  (pg_archivecleanup). Corre a diario desde el Programador de tareas (svc_respaldo).
  El usuario respaldo tiene el atributo REPLICATION y pg_hba.conf le permite "replication" solo local.
#>
param([int]$Conservar = 2)
. (Join-Path $PSScriptRoot '..\00_parametros.ps1')
$ErrorActionPreference = 'Stop'
$env:PGPASSFILE = Join-Path $P.Secretos 'pgpass.conf'
$raiz = Join-Path $P.Respaldos 'postgresql_base'
$sello = Get-Date -Format 'yyyyMMdd_HHmmss'
$destino = Join-Path $raiz $sello
New-Item -ItemType Directory -Path $raiz -Force | Out-Null
$reloj = [Diagnostics.Stopwatch]::StartNew()

& (Join-Path $P.PgBin 'pg_basebackup.exe') -h 127.0.0.1 -p $P.PgPuerto -U respaldo -w `
    -D $destino -Fp -X stream -c fast --label "base_$sello"
if ($LASTEXITCODE -ne 0) {
    Write-EventoDBA -Mensaje "Respaldo base de PostgreSQL FALLO (codigo $LASTEXITCODE)" -Id 1001 -Tipo Error
    throw "pg_basebackup fallo con codigo $LASTEXITCODE"
}
$verificador = Join-Path $P.PgBin 'pg_verifybackup.exe'
if (Test-Path $verificador) {
    & $verificador -n $destino | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'pg_verifybackup encontro diferencias en el respaldo base' }
}
$reloj.Stop()

# Retencion: las N bases mas recientes; el WAL anterior a la base mas vieja ya no sirve
$bases = Get-ChildItem $raiz -Directory | Where-Object { $_.Name -match '^\d{8}_\d{6}$' } | Sort-Object Name -Descending
$bases | Select-Object -Skip $Conservar | ForEach-Object { Remove-Item $_.FullName -Recurse -Force; Write-Paso "Base vieja borrada: $($_.Name)" }
$masVieja = $bases | Select-Object -First $Conservar | Select-Object -Last 1
$etiqueta = Get-Content (Join-Path $masVieja.FullName 'backup_label') -ErrorAction SilentlyContinue | Select-String 'START WAL LOCATION'
if ($etiqueta -and $etiqueta.Line -match '\(file ([0-9A-F]{24})\)') {
    & (Join-Path $P.PgBin 'pg_archivecleanup.exe') (Join-Path $P.Respaldos 'wal') $matches[1]
    Write-Paso "WAL anterior a $($matches[1]) depurado" 'INFO'
}

$mb = [math]::Round(((Get-ChildItem $destino -Recurse -File | Measure-Object Length -Sum).Sum / 1MB), 0)
$msg = "Respaldo base de PostgreSQL correcto: $destino ($mb MB, $([math]::Round($reloj.Elapsed.TotalSeconds)) s). Bases conservadas: $Conservar"
Write-EventoDBA -Mensaje $msg -Id 1000
Write-Paso $msg 'OK'
