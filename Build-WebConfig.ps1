<#
.SYNOPSIS
    Build a web.config from config/common.json + config/<Environment>.json.

.DESCRIPTION
    common.json supplies:
      - appSettings:        literal default values shared by all environments
      - connectionStrings:  structural metadata (providerName) for known connections

    <env>.json declares which keys/connections apply to that environment:
      {
        "appSettings":       [ "<key>", ... ],
        "connectionStrings": [ "<name>", ... ]
      }

    Rules:
      * An appSetting listed in the env file is emitted as #{Key}# (ADO token).
      * An appSetting NOT in the env file but present in common is emitted with
        the common literal value.
      * A connectionString listed in the env file is emitted with
        connectionString="#{Name}#" and providerName from common.json.
        New connection strings can be added by declaring their providerName
        in common.json first.

.PARAMETER Environment
    Environment name; resolves to config/<Environment>.json.

.EXAMPLE
    .\Build-WebConfig.ps1 -Environment prod
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Environment,

    [string]$OutputPath = (Join-Path $PSScriptRoot 'web.config'),
    [string]$ConfigDir  = (Join-Path $PSScriptRoot 'config')
)

$ErrorActionPreference = 'Stop'

function Read-Json {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Config file not found: $Path" }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function ConvertTo-OrderedHash {
    param($Object)
    $hash = [ordered]@{}
    if ($null -eq $Object) { return $hash }
    foreach ($prop in $Object.PSObject.Properties) { $hash[$prop.Name] = $prop.Value }
    return $hash
}

# --- Load ---
$common = Read-Json (Join-Path $ConfigDir 'common.json')
$envCfg = Read-Json (Join-Path $ConfigDir "$Environment.json")

$commonAppSettings = ConvertTo-OrderedHash $common.appSettings
$commonConnStrings = ConvertTo-OrderedHash $common.connectionStrings

$envAppKeys  = @($envCfg.appSettings)
$envConnKeys = @($envCfg.connectionStrings)

# --- Build merged appSettings (preserve common order, then append env-only keys) ---
$appSettings = [ordered]@{}
foreach ($k in $commonAppSettings.Keys) {
    if ($envAppKeys -contains $k) { $appSettings[$k] = "#{$k}#" }
    else                          { $appSettings[$k] = [string]$commonAppSettings[$k] }
}
foreach ($k in $envAppKeys) {
    if (-not $appSettings.Contains($k)) { $appSettings[$k] = "#{$k}#" }
}

# --- Build XML ---
$xml = New-Object System.Xml.XmlDocument
$null = $xml.AppendChild($xml.CreateXmlDeclaration('1.0', 'utf-8', $null))
$configuration = $xml.CreateElement('configuration')
$null = $xml.AppendChild($configuration)

$appSettingsEl = $xml.CreateElement('appSettings')
foreach ($key in $appSettings.Keys) {
    $add = $xml.CreateElement('add')
    $add.SetAttribute('key',   [string]$key)
    $add.SetAttribute('value', [string]$appSettings[$key])
    $null = $appSettingsEl.AppendChild($add)
}
$null = $configuration.AppendChild($appSettingsEl)

$connStringsEl = $xml.CreateElement('connectionStrings')
foreach ($name in $envConnKeys) {
    $meta = $commonConnStrings[$name]
    if ($null -eq $meta) {
        throw "Connection string '$name' is referenced by $Environment.json but is not defined in common.json."
    }
    $add = $xml.CreateElement('add')
    $add.SetAttribute('name',             [string]$name)
    $add.SetAttribute('connectionString', "#{$name}#")
    if ($meta.providerName) {
        $add.SetAttribute('providerName', [string]$meta.providerName)
    }
    $null = $connStringsEl.AppendChild($add)
}
$null = $configuration.AppendChild($connStringsEl)

# --- Save (pretty-printed) ---
$settings = New-Object System.Xml.XmlWriterSettings
$settings.Indent = $true
$settings.IndentChars = '  '
$settings.Encoding = [System.Text.UTF8Encoding]::new($false)

$writer = [System.Xml.XmlWriter]::Create($OutputPath, $settings)
try { $xml.Save($writer) } finally { $writer.Dispose() }

Write-Host "Generated $OutputPath for environment '$Environment'." -ForegroundColor Green
