<#
.SYNOPSIS
  Restaura MongoDB desde el ultimo respaldo (toda la instancia o una sola coleccion) y mide el RTO.

.DESCRIPTION
  -Coleccion alimentos_web.clientes_web  restaura SOLO esa coleccion (--nsInclude) con --drop: es lo
                                         mas rapido cuando alguien borro o vacio una coleccion.
  sin -Coleccion                         restaura todas las colecciones de alimentos_web con --drop.
  -ConOplog                              aplica tambien el oplog del respaldo (--oplogReplay) para que todo
                                         quede consistente al mismo instante. Exige un usuario con todos los
                                         privilegios: pide la contraseña de root_emergencia en ese momento.
  Despues compara documentos por coleccion contra el manifiesto.

  Credenciales: restaurador (rol restore, solo local), en C:\DBA\secretos\admin\mongo_restaurador.yaml
  (password: "<contraseña>"), carpeta que solo pueden leer los Administradores.
#>
param([string]$Respaldo, [string]$Coleccion, [switch]$ConOplog)
. (Join-Path $PSScriptRoot '..\00_parametros.ps1')
Assert-Administrador
$ErrorActionPreference = 'Stop'
$reloj = [Diagnostics.Stopwatch]::StartNew()

$carpeta = if ($Respaldo) { Get-Item (Join-Path (Join-Path $P.Respaldos 'mongodb') $Respaldo) } else { Get-RespaldoMasReciente 'mongodb' }
if (-not $carpeta) { throw 'No hay respaldos de MongoDB' }
$archivo = Join-Path $carpeta.FullName 'mongodb.archive.gz'
$manifiesto = Get-Content (Join-Path $carpeta.FullName 'manifiesto.json') -Raw | ConvertFrom-Json
if ((Get-FileHash $archivo -Algorithm SHA256).Hash -ne $manifiesto.archivos[0].sha256) { throw 'El SHA-256 del respaldo no coincide: archivo dañado' }
Write-Paso "Restaurando desde $($carpeta.Name) (respaldo del $($manifiesto.fecha))" 'AVISO'

$usuario = 'restaurador'; $config = Join-Path $P.SecretosAdmin 'mongo_restaurador.yaml'; $temporal = $null
if ($ConOplog) {
    $usuario = 'root_emergencia'
    $s = Read-Host 'Contraseña de root_emergencia' -AsSecureString
    $temporal = Join-Path $P.SecretosAdmin ("tmp_{0}.yaml" -f [guid]::NewGuid().ToString('N'))
    $plano = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
    Set-Content -Path $temporal -Value "password: `"$plano`"" -Encoding ASCII
    $config = $temporal; $plano = $null
}
$uri = "mongodb://$usuario@127.0.0.1:$($P.MongoPuerto)/?authSource=admin&directConnection=true"
$argumentos = @('--uri', $uri, '--config', $config, "--archive=$archivo", '--gzip', '--drop', '--quiet')
if ($Coleccion) { $argumentos += "--nsInclude=$Coleccion" } else { $argumentos += "--nsInclude=$($P.MongoBase).*" }
if ($ConOplog -and -not $Coleccion) { $argumentos += '--oplogReplay' }

try {
    & (Join-Path $P.MongoTools 'mongorestore.exe') @argumentos
    if ($LASTEXITCODE -ne 0) { throw "mongorestore fallo con codigo $LASTEXITCODE" }
} finally { if ($temporal) { Remove-Item $temporal -Force -ErrorAction SilentlyContinue } }

# Validacion: documentos por coleccion contra el manifiesto
# Se cuenta con el usuario respaldo (rol backup, puede leer); restaurador solo puede escribir
$env:MONGO_CLAVE = ((Get-Content (Join-Path $P.Secretos 'mongo_respaldo.yaml') -Raw) -replace '(?s).*password:\s*"?([^"\r\n]+)"?.*', '$1').Trim()
$env:MONGO_PUERTO = "$($P.MongoPuerto)"
$js = @'
const c = new Mongo('mongodb://respaldo:' + encodeURIComponent(process.env.MONGO_CLAVE) + '@127.0.0.1:' + process.env.MONGO_PUERTO + '/?authSource=admin&directConnection=true');
const d = c.getDB('alimentos_web'), r = {};
d.getCollectionInfos({ type: 'collection' }).forEach(x => { if (!x.name.startsWith('system.')) r['alimentos_web.' + x.name] = d.getCollection(x.name).countDocuments({}); });
print(JSON.stringify(r));
'@
$actual = (& $P.Mongosh --quiet --nodb --eval $js) | ConvertFrom-Json
Remove-Item Env:\MONGO_CLAVE
$diferencias = 0
foreach ($col in $manifiesto.conteos.PSObject.Properties) {
    if ($Coleccion -and $col.Name -ne $Coleccion) { continue }
    $n = $actual.($col.Name)
    $ok = ([long]$n -eq [long]$col.Value)
    if (-not $ok) { $diferencias++ }
    Write-Paso ("{0,-34} respaldo={1,9}  restaurado={2,9}  {3}" -f $col.Name, $col.Value, $n, $(if ($ok) { 'OK' } else { 'DIFERENTE' })) $(if ($ok) { 'OK' } else { 'AVISO' })
}
$reloj.Stop()
$rto = [math]::Round($reloj.Elapsed.TotalSeconds, 1)
$rpo = [math]::Round(((Get-Date) - [datetime]$manifiesto.fecha).TotalMinutes, 0)
$msg = "MongoDB restaurado ($(if ($Coleccion) { $Coleccion } else { 'instancia' })) desde $($carpeta.Name) en $rto s (RTO). Antigüedad del respaldo: $rpo min. Diferencias: $diferencias"
Write-EventoDBA -Mensaje $msg -Id 1100 -Tipo $(if ($diferencias) { 'Warning' } else { 'Information' })
Write-Paso $msg $(if ($diferencias) { 'AVISO' } else { 'OK' })
[pscustomobject]@{ Motor = 'MongoDB'; Respaldo = $carpeta.Name; RTO_s = $rto; RPO_min = $rpo; Diferencias = $diferencias }
