<#
.SYNOPSIS
  Genera el certificado TLS autofirmado de PostgreSQL (server.crt y server.key).

.DESCRIPTION
  Por que: sin TLS, la contraseña SCRAM viaja protegida pero los DATOS no (salarios, RFC,
  facturas). Con ssl = on y lineas hostssl en pg_hba.conf, todo lo que sale de la VM va cifrado.
  En produccion el certificado lo firma una autoridad; para el proyecto basta uno autofirmado.

  Usa el openssl.exe que trae Git para Windows. Ejecutar como Administrador en la VM.
  Despues: ssl = on en postgresql.conf (bloque de hardening) y reiniciar el servicio.
#>
. (Join-Path $PSScriptRoot '..\00_parametros.ps1')
Assert-Administrador

$openssl = @('C:\Program Files\Git\mingw64\bin\openssl.exe', 'C:\Program Files\Git\usr\bin\openssl.exe') |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $openssl) { throw 'No se encontro openssl.exe. Instala Git para Windows.' }

$tmp = Join-Path $env:TEMP 'pg_tls'
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
& $openssl req -new -x509 -days 365 -nodes -newkey rsa:2048 `
    -keyout (Join-Path $tmp 'server.key') -out (Join-Path $tmp 'server.crt') `
    -subj '/CN=bd.alimentosdelvalle.local/O=Alimentos del Valle' `
    -addext "subjectAltName=IP:$($P.IpServidor),IP:127.0.0.1,DNS:localhost"
if ($LASTEXITCODE -ne 0) { throw 'openssl no pudo generar el certificado' }

Copy-Item (Join-Path $tmp 'server.crt'), (Join-Path $tmp 'server.key') -Destination $P.PgData -Force
Remove-Item $tmp -Recurse -Force
Write-Paso "server.crt y server.key copiados a $($P.PgData) (heredan los permisos de la carpeta de datos)" 'OK'
& $openssl x509 -in (Join-Path $P.PgData 'server.crt') -noout -subject -dates
Write-Paso 'Siguiente: ssl = on en postgresql.conf y Restart-Service postgresql-x64-18' 'INFO'
