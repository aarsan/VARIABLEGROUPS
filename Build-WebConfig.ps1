<#
.SYNOPSIS
    Build a tokenized web.config from config/common.json + config/<Environment>.json.

.DESCRIPTION
    config/common.json is the schema. It supplies:
      - appSettings:        names of keys known to the app (string array).
                            These are always emitted as #{Key}# tokens and are
                            resolved at pipeline time from the `webconfig-common`
                            and `webconfig-common-secrets` variable groups.
      - connectionStrings:  structural metadata (providerName) for known
                            connections (object keyed by name).

    config/<env>.json declares which keys/connections apply to that
    environment:
      {
        "appSettings":       [ "<key>", ... ],   # env overrides for common keys
        "connectionStrings": [ "<name>", ... ]   # connection strings this env uses
      }

    Rules:
      * Every appSetting from common.json is emitted as <add key="X" value="#{X}#" />.
      * Any appSetting only in <env>.json is appended (also as #{Token}#).
        Env-only keys are resolved from `webconfig-<env>` / `webconfig-<env>-secrets`.
      * Common keys that also appear in <env>.json are resolved from the env
        group at pipeline time (variable groups are applied in order; common is
        listed first, env second, so env wins).
      * A connectionString listed in <env>.json is emitted with
        connectionString="#{Name}#" and providerName from common.json.
        Referencing a connection string that isn't declared in common.json is
        an error — add the providerName there first.

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

$commonAppKeys     = @($common.appSettings)
$commonConnStrings = ConvertTo-OrderedHash $common.connectionStrings

$envAppKeys  = @($envCfg.appSettings)
$envConnKeys = @($envCfg.connectionStrings)

# --- Build merged appSettings (every key is a token; common order first, then env-only) ---
$appSettings = [ordered]@{}
foreach ($k in $commonAppKeys) { $appSettings[$k] = "#{$k}#" }
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
