<#
.SYNOPSIS
  Genera la llave (keyFile) del conjunto de replicas de MongoDB.

.DESCRIPTION
  El keyFile es una contraseña compartida entre los miembros de un conjunto de replicas.
  Con un solo nodo casi no se usa para hablar con otros, pero MongoDB lo exige cuando hay
  replicacion y autorizacion activas a la vez. Es un secreto: no va a Git ni se comparte.
  Genera 756 bytes aleatorios en base64 (1008 caracteres, el maximo permitido es 1024).
  Ejecutar como Administrador. Despues, Jesus aplica permisos con 02_permisos_ntfs.ps1.
#>
. (Join-Path $PSScriptRoot '..\00_parametros.ps1')
Assert-Administrador

$ruta = Join-Path $P.MongoSeguridad 'mongo.key'
if (Test-Path $ruta) { Write-Paso "Ya existe $ruta; no se sobrescribe" 'AVISO'; return }
if (-not (Test-Path $P.MongoSeguridad)) { New-Item -ItemType Directory -Path $P.MongoSeguridad -Force | Out-Null }

$bytes = New-Object byte[] 756
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$rng.GetBytes($bytes)
[IO.File]::WriteAllText($ruta, [Convert]::ToBase64String($bytes), [Text.Encoding]::ASCII)
Write-Paso "keyFile creado en $ruta (1008 caracteres)" 'OK'
