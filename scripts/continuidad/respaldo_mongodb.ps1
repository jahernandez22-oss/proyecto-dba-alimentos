<#
.SYNOPSIS
  Respaldo logico de MongoDB con mongodump --oplog en un solo archivo comprimido + manifiesto.

.DESCRIPTION
  Que deja en E:\Respaldos\mongodb\<yyyyMMdd_HHmmss>\:
    mongodb.archive.gz   mongodump --archive --gzip --oplog de toda la instancia (incluye usuarios y vistas)
    manifiesto.json      documentos por coleccion y SHA-256, para validar la restauracion
  Por que --oplog: mongodump lee las colecciones una tras otra; si alguien escribe mientras tanto, el
  respaldo mezclaria momentos distintos. Con --oplog guarda tambien los cambios ocurridos durante el
  respaldo y al restaurar (--oplogReplay) todo queda consistente a un mismo instante.
  Requiere el conjunto de replicas (Fase 1): sin replica no hay oplog.

  Usuario: respaldo (rol backup, solo desde 127.0.0.1). La contraseña esta en
  C:\DBA\secretos\mongo_respaldo.yaml (una linea:  password: "<contraseña>"), asi no aparece en la
  linea de comandos.
#>
param([string]$Destino)
. (Join-Path $PSScriptRoot '..\00_parametros.ps1')
$ErrorActionPreference = 'Stop'

$sello = Get-Date -Format 'yyyyMMdd_HHmmss'
if (-not $Destino) { $Destino = Join-Path (Join-Path $P.Respaldos 'mongodb') $sello }
New-Item -ItemType Directory -Path $Destino -Force | Out-Null
$config = Join-Path $P.Secretos 'mongo_respaldo.yaml'
if (-not (Test-Path $config)) { throw "Falta $config" }
$uri = "mongodb://respaldo@127.0.0.1:$($P.MongoPuerto)/?authSource=admin&directConnection=true"
$reloj = [Diagnostics.Stopwatch]::StartNew()

# 1) Conteo por coleccion (con el mismo usuario de respaldo; la contraseña llega por variable de entorno)
$env:MONGO_PUERTO = "$($P.MongoPuerto)"
$env:MONGO_CLAVE = ((Get-Content $config -Raw) -replace '(?s).*password:\s*"?([^"\r\n]+)"?.*', '$1').Trim()
$js = @'
const c = new Mongo('mongodb://respaldo:' + encodeURIComponent(process.env.MONGO_CLAVE) + '@127.0.0.1:' + process.env.MONGO_PUERTO + '/?authSource=admin&directConnection=true');
const d = c.getDB('alimentos_web'), r = {};
d.getCollectionInfos({ type: 'collection' }).forEach(x => { if (!x.name.startsWith('system.')) r['alimentos_web.' + x.name] = d.getCollection(x.name).countDocuments({}); });
print(JSON.stringify(r));
'@
$conteo = & $P.Mongosh --quiet --nodb --eval $js
Remove-Item Env:\MONGO_CLAVE
if ($LASTEXITCODE -ne 0) { throw "No se pudieron contar documentos (mongosh salio con $LASTEXITCODE)" }

# 2) La instancia completa, consistente gracias al oplog
$archivo = Join-Path $Destino 'mongodb.archive.gz'
& (Join-Path $P.MongoTools 'mongodump.exe') --uri $uri --config $config --oplog --gzip --archive=$archivo --quiet
if ($LASTEXITCODE -ne 0) { throw "mongodump fallo con codigo $LASTEXITCODE" }
if ((Get-Item $archivo).Length -lt 1KB) { throw 'El archivo de respaldo quedo vacio' }

# 3) Manifiesto
$reloj.Stop()
$manifiesto = [ordered]@{
    motor      = 'mongodb'
    fecha      = (Get-Date).ToString('o')
    duracion_s = [math]::Round($reloj.Elapsed.TotalSeconds, 1)
    conteos    = ($conteo | ConvertFrom-Json)
    archivos   = @([ordered]@{ nombre = 'mongodb.archive.gz'; bytes = (Get-Item $archivo).Length; sha256 = (Get-FileHash $archivo -Algorithm SHA256).Hash })
}
$manifiesto | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $Destino 'manifiesto.json') -Encoding UTF8

$mb = [math]::Round((Get-Item $archivo).Length / 1MB, 1)
Write-Paso "MongoDB respaldado en $Destino ($mb MB, $($manifiesto.duracion_s) s)" 'OK'
[pscustomobject]@{ Motor = 'MongoDB'; Carpeta = $Destino; MB = $mb; Segundos = $manifiesto.duracion_s }
