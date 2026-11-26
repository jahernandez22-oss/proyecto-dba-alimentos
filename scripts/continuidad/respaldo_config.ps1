<#
.SYNOPSIS
  Copia con fecha de las configuraciones de ambos motores (para poder volver a cualquier dia).

.DESCRIPTION
  Copia postgresql.conf, pg_hba.conf, postgresql.auto.conf y mongod.cfg a
  E:\Respaldos\config\<yyyyMMdd_HHmmss>\ con sus SHA-256. No copia llaves ni certificados privados
  (server.key, mongo.key): esos se regeneran o viven en el gestor de contraseñas.
  svc_respaldo tiene lectura explicita sobre estos archivos (02_permisos_ntfs.ps1).
#>
param([string]$Destino)
. (Join-Path $PSScriptRoot '..\00_parametros.ps1')
$ErrorActionPreference = 'Stop'
if (-not $Destino) { $Destino = Join-Path (Join-Path $P.Respaldos 'config') (Get-Date -Format 'yyyyMMdd_HHmmss') }
New-Item -ItemType Directory -Path $Destino -Force | Out-Null

$origenes = @((Join-Path $P.PgData 'postgresql.conf'), (Join-Path $P.PgData 'pg_hba.conf'),
              (Join-Path $P.PgData 'postgresql.auto.conf'), $P.MongoCfg)
$lista = foreach ($o in $origenes) {
    Copy-Item -LiteralPath $o -Destination $Destino -Force
    [ordered]@{ archivo = (Split-Path $o -Leaf); origen = $o; sha256 = (Get-FileHash -LiteralPath $o -Algorithm SHA256).Hash }
}
$lista | ConvertTo-Json | Set-Content (Join-Path $Destino 'huellas.json') -Encoding UTF8
Write-Paso "Configuraciones copiadas a $Destino" 'OK'
[pscustomobject]@{ Motor = 'Configuraciones'; Carpeta = $Destino; MB = 0; Segundos = 0 }
