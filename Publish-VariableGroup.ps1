<#
.SYNOPSIS
    Create or update an Azure DevOps Variable Group containing the values
    needed by the tokens in the generated web.config for a given environment.

.DESCRIPTION
    Reads config/common.json + config/<Environment>.json to determine which
    variable names the environment needs (every key listed in the env file
    becomes a variable, plus every connection string name). It then creates
    or updates an ADO variable group with those variables.

    Values can be supplied via:
      -ValuesFile  : a JSON file mapping { "VarName": "value", ... }
      -Values      : an inline hashtable @{ VarName = 'value'; ... }

    Variables whose name appears in -SecretNames are stored as secret.

.PARAMETER Environment
    Environment name (matches config/<Environment>.json).

.PARAMETER Organization
    Azure DevOps organization. Accepts either a short name (e.g. 'contoso')
    or a full URL (e.g. 'https://dev.azure.com/contoso').

.PARAMETER Project
    Azure DevOps project name.

.PARAMETER GroupName
    Variable group name. Defaults to "webconfig-<Environment>".

.PARAMETER ValuesFile
    Path to a JSON file containing variable values.

.PARAMETER Values
    Hashtable of variable values (alternative to -ValuesFile).

.PARAMETER SecretNames
    Names of variables that should be stored as secrets.

.EXAMPLE
    .\Publish-VariableGroup.ps1 `
        -Environment prod `
        -Organization https://dev.azure.com/contoso `
        -Project MyProject `
        -ValuesFile .\values.prod.json `
        -SecretNames DefaultConnection,StorageConnection
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$Environment,
    [Parameter(Mandatory)] [string]$Organization,  # short name or full URL
    [Parameter(Mandatory)] [string]$Project,

    [string]$GroupName    = "webconfig-$Environment",
    [string]$ValuesFile   = (Join-Path $PSScriptRoot "values.$Environment.json"),
    [hashtable]$Values    = @{},
    [string[]]$SecretNames = @(),

    [string]$ConfigDir = (Join-Path $PSScriptRoot 'config')
)

$ErrorActionPreference = 'Stop'

# --- Sanity checks ---
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI (az) not found. Install it from https://aka.ms/azure-cli."
}
$extList = az extension list --query "[?name=='azure-devops'].name" -o tsv 2>$null
if (-not $extList) {
    Write-Host "Installing azure-devops CLI extension..." -ForegroundColor Yellow
    az extension add --name azure-devops | Out-Null
}

# --- Determine required variable names from the env manifest ---
function Read-Json {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Config file not found: $Path" }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

$envCfg = Read-Json (Join-Path $ConfigDir "$Environment.json")
$required = @()
$required += @($envCfg.appSettings)
$required += @($envCfg.connectionStrings)
$required = $required | Where-Object { $_ } | Select-Object -Unique

if (-not $required) {
    throw "No tokenized variables found in $Environment.json."
}

# --- Merge values from file + inline ---
$allValues = @{}
if ($ValuesFile) {
    if (-not (Test-Path -LiteralPath $ValuesFile)) { throw "Values file not found: $ValuesFile" }
    $fileObj = Get-Content -LiteralPath $ValuesFile -Raw | ConvertFrom-Json
    foreach ($p in $fileObj.PSObject.Properties) { $allValues[$p.Name] = [string]$p.Value }
}
foreach ($k in $Values.Keys) { $allValues[$k] = [string]$Values[$k] }

# Variables listed in -SecretNames are stored in Azure Key Vault (see
# Publish-VaultSecret.ps1) and pulled by the pipeline at runtime, so they are
# excluded from the ADO variable group.
$groupVars = $required | Where-Object { $SecretNames -notcontains $_ }
if (-not $groupVars) {
    Write-Warning "All variables for '$Environment' are marked as secrets; nothing to publish to the ADO variable group."
    return
}

# --- Validate completeness (only for non-secret vars going into the group) ---
$missing = $groupVars | Where-Object { -not $allValues.ContainsKey($_) }
if ($missing) {
    throw "Missing values for required variables: $($missing -join ', ')"
}

# --- Normalize organization to a full URL ---
if ($Organization -notmatch '^https?://') {
    $Organization = "https://dev.azure.com/$Organization"
}

# --- Configure az defaults ---
az devops configure --defaults organization=$Organization project=$Project | Out-Null

# --- Find or create variable group ---
$existingId = az pipelines variable-group list `
    --group-name $GroupName `
    --query "[0].id" -o tsv 2>$null

if (-not $existingId) {
    Write-Host "Creating variable group '$GroupName'..." -ForegroundColor Cyan

    # az pipelines variable-group create requires at least one variable up-front.
    $first      = $groupVars[0]
    $firstValue = $allValues[$first]

    $createArgs = @(
        'pipelines','variable-group','create',
        '--name', $GroupName,
        '--variables', "$first=$firstValue",
        '--authorize','false'
    )
    $groupJson = az @createArgs | ConvertFrom-Json
    $groupId   = $groupJson.id

    foreach ($name in $groupVars | Select-Object -Skip 1) {
        az pipelines variable-group variable create `
            --group-id $groupId `
            --name $name `
            --value $allValues[$name] | Out-Null
    }
}
else {
    $groupId = $existingId
    Write-Host "Updating variable group '$GroupName' (id $groupId)..." -ForegroundColor Cyan

    $existingVars = (az pipelines variable-group variable list --group-id $groupId | ConvertFrom-Json).PSObject.Properties.Name

    # Add or update the non-secret vars.
    foreach ($name in $groupVars) {
        $val = $allValues[$name]
        if ($existingVars -contains $name) {
            az pipelines variable-group variable update `
                --group-id $groupId --name $name --value $val --secret false | Out-Null
        } else {
            az pipelines variable-group variable create `
                --group-id $groupId --name $name --value $val | Out-Null
        }
    }

    # Remove any variable named in -SecretNames that's still present in the
    # group (it now lives in Key Vault).
    foreach ($name in $SecretNames) {
        if ($existingVars -contains $name) {
            Write-Host "Removing '$name' from group (moved to Key Vault)." -ForegroundColor Yellow
            az pipelines variable-group variable delete `
                --group-id $groupId --name $name --yes | Out-Null
        }
    }
}

Write-Host "Variable group '$GroupName' is ready with $($groupVars.Count) variable(s)." -ForegroundColor Green
Write-Host "In group: $($groupVars -join ', ')"
if ($SecretNames) {
    Write-Host "In Key Vault (publish separately): $($SecretNames -join ', ')"
}
