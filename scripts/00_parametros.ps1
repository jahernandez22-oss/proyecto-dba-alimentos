<#
.SYNOPSIS
  Parametros compartidos del proyecto ("el contrato" del Plan maestro).

.DESCRIPTION
  Todos los scripts .ps1 del kit cargan este archivo con:
      . (Join-Path $PSScriptRoot '..\00_parametros.ps1')
  Si el equipo cambia un nombre, puerto o ruta, se cambia SOLO aqui y se avisa.
  Este archivo NO contiene contraseñas: esas viven en C:\DBA\secretos (fuera de Git).

  Compatible con Windows PowerShell 5.1 (el que trae Windows Server 2022).
  Guardado como UTF-8 con BOM para que PowerShell 5.1 lea bien los acentos.
#>

$P = [ordered]@{
    # ---------------- PostgreSQL ----------------
    PgVersion       = '18'
    PgBin           = 'C:\Program Files\PostgreSQL\18\bin'
    PgData          = 'C:\BD\PostgreSQL\18\data'
    PgServicio      = 'postgresql-x64-18'
    PgPuerto        = 15432
    PgBase          = 'alimentos_erp'

    # ---------------- MongoDB -------------------
    MongoBin        = 'C:\Program Files\MongoDB\Server\8.0\bin'
    MongoCfg        = 'C:\Program Files\MongoDB\Server\8.0\bin\mongod.cfg'
    MongoTools      = 'C:\Program Files\MongoDB\Tools\100\bin'
    Mongosh         = 'mongosh'                     # el MSI de mongosh lo agrega al PATH
    MongoData       = 'C:\BD\MongoDB\data'
    MongoLog        = 'C:\BD\MongoDB\log'
    MongoSeguridad  = 'C:\BD\MongoDB\seguridad'
    MongoServicio   = 'MongoDB'
    MongoPuerto     = 37017
    MongoBase       = 'alimentos_web'
    MongoReplicaSet = 'rs_alimentos'

    # ---------------- Red -----------------------
    IpServidor      = '192.168.56.10'               # IP fija de la VM (adaptador solo-anfitrion)
    IpsAutorizadas  = @('192.168.56.1')             # servidor de aplicaciones (el anfitrion)

    # ---------------- Cuentas de Windows --------
    CuentaPg        = 'svc_postgres'
    CuentaMongo     = 'svc_mongodb'
    CuentaRespaldo  = 'svc_respaldo'

    # ---------------- Carpetas del equipo -------
    RaizDBA         = 'C:\DBA'
    Repo            = 'C:\DBA\repo'                 # clon del repositorio del equipo
    Scripts         = 'C:\DBA\repo\scripts'
    ConfigMaestra   = 'C:\DBA\config'
    Secretos        = 'C:\DBA\secretos'               # lo lee svc_respaldo (respaldar)
    SecretosAdmin   = 'C:\DBA\secretos\admin'        # solo Administradores (restaurar)
    LogsScripts     = 'C:\DBA\logs'
    Respaldos       = 'E:\Respaldos'                # segundo disco; si no existe se usa C:
    RetencionDias   = 7
    FuenteEventos   = 'AlimentosDBA'                # origen en el Visor de eventos para nuestros scripts
}
if (-not (Test-Path 'E:\')) { $P.Respaldos = 'C:\Respaldos' }

# SIDs bien conocidos: funcionan igual en Windows en espanol o en ingles
$SID = @{
    SYSTEM          = 'S-1-5-18'
    Administradores = 'S-1-5-32-544'
    Usuarios        = 'S-1-5-32-545'
    Autenticados    = 'S-1-5-11'
    Todos           = 'S-1-1-0'
    NetworkService  = 'S-1-5-20'
}

function Test-EsAdministrador {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Administrador {
    if (-not (Test-EsAdministrador)) {
        throw 'Este script debe ejecutarse en una consola de PowerShell abierta como Administrador.'
    }
}

function Write-Paso {
    # Escribe en pantalla y en C:\DBA\logs\<script>.log con fecha y hora.
    param([Parameter(Mandatory)][string]$Mensaje, [ValidateSet('INFO','OK','AVISO','ERROR')][string]$Nivel = 'INFO')
    $linea = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Nivel, $Mensaje
    $color = @{ INFO = 'Gray'; OK = 'Green'; AVISO = 'Yellow'; ERROR = 'Red' }[$Nivel]
    Write-Host $linea -ForegroundColor $color
    if (Test-Path $P.LogsScripts) {
        $nombre = if ($MyInvocation.ScriptName) { [IO.Path]::GetFileNameWithoutExtension($MyInvocation.ScriptName) } else { 'consola' }
        Add-Content -Path (Join-Path $P.LogsScripts "$nombre.log") -Value $linea -Encoding UTF8
    }
}

function Get-Identidad {
    # Devuelve un IdentityReference a partir de un SID ('S-1-...') o de un nombre de cuenta.
    param([Parameter(Mandatory)][string]$Cuenta)
    if ($Cuenta -like 'S-1-*') { return New-Object Security.Principal.SecurityIdentifier($Cuenta) }
    return New-Object Security.Principal.NTAccount($Cuenta)
}

function Write-EventoDBA {
    # Deja constancia en el Visor de eventos (Aplicacion, origen AlimentosDBA).
    # 1000 = respaldo correcto, 1001 = respaldo con error, 1100 = restauracion,
    # 2001 = configuracion alterada, 3000 = mantenimiento de bitacoras.
    param([Parameter(Mandatory)][string]$Mensaje, [int]$Id = 1000,
          [ValidateSet('Information','Warning','Error')][string]$Tipo = 'Information')
    try {
        if ([Diagnostics.EventLog]::SourceExists($P.FuenteEventos)) {
            Write-EventLog -LogName Application -Source $P.FuenteEventos -EventId $Id -EntryType $Tipo -Message $Mensaje
        }
    } catch { Write-Host "No se pudo escribir en el Visor de eventos: $($_.Exception.Message)" -ForegroundColor Yellow }
}

function Get-RespaldoMasReciente {
    # Carpeta de respaldo mas reciente de un motor ('postgresql' o 'mongodb').
    param([Parameter(Mandatory)][string]$Motor)
    Get-ChildItem (Join-Path $P.Respaldos $Motor) -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d{8}_\d{6}$' } | Sort-Object Name -Descending | Select-Object -First 1
}

