<#
.SYNOPSIS
  Restaura alimentos_erp desde el ultimo respaldo logico (o uno elegido) y mide el RTO.

.DESCRIPTION
  Estrategia "renombrar y restaurar":
    1. Corta las conexiones y RENOMBRA la base dañada a alimentos_erp_danada_<fecha> (no se borra:
       es evidencia para saber que paso; se elimina despues del analisis).
    2. pg_restore --create -j 4: crea la base con su dueño, permisos y ajustes, y carga en paralelo.
    3. Valida: compara el conteo de filas contra el manifiesto del respaldo.
  Con -InstanciaLimpia (servidor nuevo, sin roles): primero aplica globales.sql (roles y membresias)
  y recuerda reasignar contraseñas con \password.

  Credenciales: postgres, desde C:\DBA\secretos\admin\pgpass_admin.conf (solo Administradores).
  Uso:  .\restaurar_postgres.ps1                       (ultimo respaldo)
        .\restaurar_postgres.ps1 -Respaldo 20261210_233000
        .\restaurar_postgres.ps1 -InstanciaLimpia
#>
param([string]$Respaldo, [switch]$InstanciaLimpia, [int]$Hilos = 4)
. (Join-Path $PSScriptRoot '..\00_parametros.ps1')
Assert-Administrador
$ErrorActionPreference = 'Stop'
$reloj = [Diagnostics.Stopwatch]::StartNew()
$env:PGPASSFILE = Join-Path $P.SecretosAdmin 'pgpass_admin.conf'
$psql = Join-Path $P.PgBin 'psql.exe'
$c = @('-h', '127.0.0.1', '-p', "$($P.PgPuerto)", '-U', 'postgres', '-w')

$carpeta = if ($Respaldo) { Get-Item (Join-Path (Join-Path $P.Respaldos 'postgresql') $Respaldo) } else { Get-RespaldoMasReciente 'postgresql' }
if (-not $carpeta) { throw 'No hay respaldos de PostgreSQL' }
$dump = Join-Path $carpeta.FullName "$($P.PgBase).dump"
$manifiesto = Get-Content (Join-Path $carpeta.FullName 'manifiesto.json') -Raw | ConvertFrom-Json
Write-Paso "Restaurando desde $($carpeta.Name) (respaldo del $($manifiesto.fecha))" 'AVISO'

# Integridad del archivo antes de tocar nada
$hashEsperado = ($manifiesto.archivos | Where-Object nombre -eq "$($P.PgBase).dump").sha256
if ((Get-FileHash $dump -Algorithm SHA256).Hash -ne $hashEsperado) { throw 'El SHA-256 del respaldo no coincide: archivo dañado' }

if ($InstanciaLimpia) {
    & $psql @c -d postgres -q -f (Join-Path $carpeta.FullName 'globales.sql') 2>&1 | Where-Object { $_ -match 'ERROR' -and $_ -notmatch 'already exists' }
    Write-Paso 'Roles aplicados desde globales.sql (recuerden reasignar contraseñas con \password)' 'AVISO'
}

# 1) Apartar la base dañada (si existe)
$existe = & $psql @c -d postgres -At -c "SELECT 1 FROM pg_database WHERE datname = '$($P.PgBase)'"
if ($existe -eq '1') {
    $apartada = "$($P.PgBase)_danada_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    & $psql @c -d postgres -q -c "ALTER DATABASE $($P.PgBase) WITH ALLOW_CONNECTIONS false;" | Out-Null
    & $psql @c -d postgres -q -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$($P.PgBase)' AND pid <> pg_backend_pid();" | Out-Null
    & $psql @c -d postgres -q -c "ALTER DATABASE $($P.PgBase) RENAME TO $apartada;"
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo apartar la base dañada (¿siguen conectados?)' }
    Write-Paso "Base dañada apartada como $apartada" 'INFO'
}

# 2) Restaurar en paralelo (crea la base con su dueño, permisos y ajustes por rol)
& (Join-Path $P.PgBin 'pg_restore.exe') @c -d postgres --create -j $Hilos $dump 2>&1 |
    Where-Object { $_ -match 'error' } | ForEach-Object { Write-Paso "pg_restore: $_" 'AVISO' }

# 3) Validacion contra el manifiesto
$errores = 0
foreach ($t in $manifiesto.conteos.PSObject.Properties) {
    $n = & $psql @c -d $P.PgBase -At -c "SELECT count(*) FROM $($t.Name)"
    $ok = ([long]$n -eq [long]$t.Value)
    if (-not $ok) { $errores++ }
    Write-Paso ("{0,-28} respaldo={1,10}  restaurado={2,10}  {3}" -f $t.Name, $t.Value, $n, $(if ($ok) { 'OK' } else { 'DIFERENTE' })) $(if ($ok) { 'OK' } else { 'ERROR' })
}
$reloj.Stop()
$rto = [math]::Round($reloj.Elapsed.TotalSeconds, 1)
$rpo = [math]::Round(((Get-Date) - [datetime]$manifiesto.fecha).TotalMinutes, 0)
$msg = "PostgreSQL restaurado desde $($carpeta.Name) en $rto s (RTO). Antigüedad del respaldo: $rpo min (RPO maximo de esta restauracion). Diferencias: $errores"
Write-EventoDBA -Mensaje $msg -Id 1100 -Tipo $(if ($errores) { 'Warning' } else { 'Information' })
Write-Paso $msg $(if ($errores) { 'AVISO' } else { 'OK' })
[pscustomobject]@{ Motor = 'PostgreSQL'; Respaldo = $carpeta.Name; RTO_s = $rto; RPO_min = $rpo; Diferencias = $errores }
