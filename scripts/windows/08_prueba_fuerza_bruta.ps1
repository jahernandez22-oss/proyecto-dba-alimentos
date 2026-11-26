<#
.SYNOPSIS
  Simula un ataque de fuerza bruta controlado contra PostgreSQL, MongoDB y Windows para
  generar la evidencia de "accesos fallidos" que pide la Seccion 3 del reporte.

.DESCRIPTION
  Hace N intentos con contraseñas incorrectas. Despues, 09_recolectar_evidencias.ps1 los
  encuentra en: el log de PostgreSQL (y el Visor de eventos), el audit.json de MongoDB y el
  registro Security de Windows (4625 y, al pasar el umbral, 4740 "cuenta bloqueada").

  Para Windows usa una cuenta señuelo (prueba_fb), nunca una cuenta de servicio: bloquear
  svc_postgres impediria que el servicio vuelva a arrancar.
  Se puede correr en la VM (-Servidor 127.0.0.1) o desde el anfitrion si tiene psql y mongosh
  (-Servidor 192.168.56.10). Ejecutar como Administrador.
#>
param([string]$Servidor = '127.0.0.1', [int]$Intentos = 6)
. (Join-Path $PSScriptRoot '..\00_parametros.ps1')
Assert-Administrador
$psql = Join-Path $P.PgBin 'psql.exe'
if (-not (Test-Path $psql)) { $psql = 'psql' }

Write-Paso "PostgreSQL: $Intentos intentos fallidos como app_ventas contra $Servidor" 'AVISO'
for ($i = 1; $i -le $Intentos; $i++) {
    $env:PGPASSWORD = "incorrecta$i"
    & $psql "host=$Servidor port=$($P.PgPuerto) dbname=$($P.PgBase) user=app_ventas sslmode=prefer connect_timeout=5" -c 'SELECT 1' 2>&1 | Select-Object -First 1
}
Remove-Item Env:\PGPASSWORD

Write-Paso "MongoDB: $Intentos intentos fallidos como app_ecommerce contra $Servidor" 'AVISO'
for ($i = 1; $i -le $Intentos; $i++) {
    & $P.Mongosh --quiet "mongodb://app_ecommerce:incorrecta$i@$($Servidor):$($P.MongoPuerto)/alimentos_web?authSource=alimentos_web&directConnection=true&serverSelectionTimeoutMS=5000" --eval '1' 2>&1 | Select-Object -First 1
}

Write-Paso "Windows: $Intentos inicios de sesion fallidos con la cuenta señuelo prueba_fb" 'AVISO'
if (-not (Get-LocalUser -Name 'prueba_fb' -ErrorAction SilentlyContinue)) {
    $clave = ConvertTo-SecureString ('Senuelo-' + [guid]::NewGuid().ToString('N')) -AsPlainText -Force
    New-LocalUser -Name 'prueba_fb' -Password $clave -Description 'Cuenta señuelo para la prueba de fuerza bruta' | Out-Null
}
for ($i = 1; $i -le $Intentos; $i++) {
    net use \\127.0.0.1\IPC$ /user:prueba_fb "incorrecta$i" 2>&1 | Select-Object -First 1
}
net use \\127.0.0.1\IPC$ /delete 2>&1 | Out-Null

Write-Paso 'Listo. Ahora corre 09_recolectar_evidencias.ps1 para juntar lo que registraron los tres.' 'OK'
Write-Host 'La cuenta señuelo se desbloquea sola en 15 minutos (politica de bloqueo). Para hacerlo ya:' -ForegroundColor Yellow
Write-Host '  $u = [ADSI]"WinNT://./prueba_fb,user"; $u.IsAccountLocked = $false; $u.SetInfo()' -ForegroundColor Yellow
