<#
.SYNOPSIS
  Simulacro de desastre con cronometro: provoca una falla controlada, ejecuta la restauracion que
  corresponde, valida y registra RTO y RPO en C:\DBA\logs\simulacros.csv (tabla de la Seccion 5).

.DESCRIPTION
  Escenarios:
    pg-borrado       DROP de nomina.empleados y vaciado de pagos y detalle de facturas
                     -> restaurar_postgres.ps1 (ultimo pg_dump)
    pg-pitr          igual que pg-borrado, pero se recupera al segundo previo con base + WAL
                     -> pitr_restaurar_postgres.ps1
    mongo-coleccion  drop de alimentos_web.clientes_web
                     -> restaurar_mongodb.ps1 -Coleccion alimentos_web.clientes_web
    config-pg        pg_hba.conf con una linea "trust" para todos (un hueco de seguridad)
                     -> restaurar_config.ps1
    config-mongo     mongod.cfg con authorization: disabled
                     -> restaurar_config.ps1
  RTO = desde que se empieza a restaurar hasta que el servicio esta validado.
  RPO = cuanto tiempo de datos se pierde: antiguedad del respaldo usado (o segundos en pg-pitr).
  Ejecutar como Administrador, SOLO en la VM del proyecto. Pide escribir SIMULACRO para confirmar.
#>
param([Parameter(Mandatory)][ValidateSet('pg-borrado', 'pg-pitr', 'mongo-coleccion', 'config-pg', 'config-mongo')][string]$Escenario)
. (Join-Path $PSScriptRoot '..\00_parametros.ps1')
Assert-Administrador
if ((Read-Host "Esto va a DAÑAR la base a proposito ($Escenario). Escribe SIMULACRO para continuar") -ne 'SIMULACRO') { return }
$env:PGPASSFILE = Join-Path $P.SecretosAdmin 'pgpass_admin.conf'
$psql = Join-Path $P.PgBin 'psql.exe'
$c = @('-h', '127.0.0.1', '-p', "$($P.PgPuerto)", '-U', 'postgres', '-w', '-d', $P.PgBase)

# ---------- 1) Provocar la falla ----------
$momentoFalla = Get-Date
switch -Wildcard ($Escenario) {
    'pg-*' {
        Start-Sleep -Seconds 2   # deja un margen claro entre el ultimo dato bueno y el borrado
        $antesDeFalla = Get-Date
        & $psql @c -q -c "DROP TABLE nomina.empleados CASCADE; DELETE FROM erp.pagos; TRUNCATE erp.detalle_factura CASCADE;"
        Write-Paso 'FALLA: nomina.empleados borrada, pagos y detalle de facturas vaciados' 'ERROR'
    }
    'mongo-coleccion' {
        $env:MONGO_CLAVE = ((Get-Content (Join-Path $P.SecretosAdmin 'mongo_restaurador.yaml') -Raw) -replace '(?s).*password:\s*"?([^"\r\n]+)"?.*', '$1').Trim()
        $env:MONGO_PUERTO = "$($P.MongoPuerto)"
        & $P.Mongosh --quiet --nodb --eval "new Mongo('mongodb://restaurador:' + encodeURIComponent(process.env.MONGO_CLAVE) + '@127.0.0.1:' + process.env.MONGO_PUERTO + '/?authSource=admin&directConnection=true').getDB('alimentos_web').clientes_web.drop()"
        Remove-Item Env:\MONGO_CLAVE
        Write-Paso 'FALLA: coleccion alimentos_web.clientes_web eliminada' 'ERROR'
    }
    'config-pg' {
        $hba = Join-Path $P.PgData 'pg_hba.conf'
        $contenido = Get-Content $hba -Raw
        [IO.File]::WriteAllText($hba, "host all all 0.0.0.0/0 trust`r`n" + $contenido)
        & $psql @c -q -c 'SELECT pg_reload_conf();' | Out-Null
        Write-Paso 'FALLA: pg_hba.conf acepta a cualquiera sin contraseña (trust)' 'ERROR'
    }
    'config-mongo' {
        $cfg = Get-Content $P.MongoCfg -Raw
        [IO.File]::WriteAllText($P.MongoCfg, ($cfg -replace 'authorization:\s*enabled', 'authorization: disabled'))
        Restart-Service $P.MongoServicio -Force
        Write-Paso 'FALLA: MongoDB reiniciado sin autorizacion' 'ERROR'
    }
}
Read-Host 'Falla provocada. Presiona Enter para iniciar el cronometro y restaurar'

# ---------- 2) Restaurar con cronometro ----------
$reloj = [Diagnostics.Stopwatch]::StartNew()
$detalle = switch ($Escenario) {
    'pg-borrado'      { & (Join-Path $PSScriptRoot 'restaurar_postgres.ps1') }
    'pg-pitr'         { & (Join-Path $PSScriptRoot 'pitr_restaurar_postgres.ps1') -Hasta $antesDeFalla }
    'mongo-coleccion' { & (Join-Path $PSScriptRoot 'restaurar_mongodb.ps1') -Coleccion 'alimentos_web.clientes_web' }
    default           { & (Join-Path $PSScriptRoot 'restaurar_config.ps1') }
}
$reloj.Stop()
$rto = [math]::Round($reloj.Elapsed.TotalSeconds, 1)
$respaldoUsado = ($detalle | Where-Object { $_.PSObject.Properties.Name -contains 'RPO_min' } | Select-Object -Last 1)
$rpo = switch -Wildcard ($Escenario) {
    'pg-pitr'  { '< 1 min (PITR)' }
    'config-*' { '0 (configuracion maestra)' }
    default    { if ($respaldoUsado) { "$($respaldoUsado.RPO_min) min" } else { 'ver bitacora' } }
}

# ---------- 3) Registrar el resultado ----------
$fila = [pscustomobject]@{
    Fecha     = $momentoFalla.ToString('yyyy-MM-dd HH:mm')
    Escenario = $Escenario
    RTO_s     = $rto
    Cumple_RTO_5min = $(if ($rto -lt 300) { 'SI' } else { 'NO' })
    RPO       = $rpo
    Diferencias_validacion = $(if ($respaldoUsado) { $respaldoUsado.Diferencias } else { '' })
}
$fila | Format-List
$fila | Export-Csv (Join-Path $P.LogsScripts 'simulacros.csv') -NoTypeInformation -Encoding UTF8 -Append
Write-Paso "Simulacro registrado en $(Join-Path $P.LogsScripts 'simulacros.csv')" 'OK'
