<#
.SYNOPSIS
    Upload environment-specific secrets to Azure Key Vault for use by the
    web.config build pipeline.

.DESCRIPTION
    Reads values.<Environment>.json and uploads each key listed in
    -SecretNames as a Key Vault secret named "<Environment>-<Key>".

    The pipeline (azure-pipelines.yml) pulls secrets with the prefix
    "<env>-*" via AzureKeyVault@2 and re-aliases them to their bare names
    before the token-replacement step.

.PARAMETER Environment
    Environment name (matches values.<Environment>.json).

.PARAMETER VaultName
    Target Azure Key Vault name.

.PARAMETER SecretNames
    Keys in values.<env>.json that should be uploaded to Key Vault.
    Anything not listed here is left in the local file (for the ADO
    variable group publisher to pick up as non-secret).

.PARAMETER ValuesFile
    Path to the JSON file containing the values. Defaults to
    values.<Environment>.json next to this script.

.EXAMPLE
    .\Publish-VaultSecret.ps1 -Environment prod -VaultName Progger `
        -SecretNames DefaultConnection,StorageConnection
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$Environment,
    [Parameter(Mandatory)] [string]$VaultName,
    [Parameter(Mandatory)] [string[]]$SecretNames,

    [string]$ValuesFile = (Join-Path $PSScriptRoot "values.$Environment.json")
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI (az) not found. Install it from https://aka.ms/azure-cli."
}
if (-not (Test-Path -LiteralPath $ValuesFile)) {
    throw "Values file not found: $ValuesFile"
}

$values = Get-Content -LiteralPath $ValuesFile -Raw | ConvertFrom-Json

foreach ($name in $SecretNames) {
    $value = $values.$name
    if (-not $value) {
        throw "Secret '$name' is not present in $ValuesFile."
    }
    $secretName = "$Environment-$name"
    Write-Host "Uploading $secretName to vault '$VaultName'..." -ForegroundColor Cyan
    az keyvault secret set `
        --vault-name $VaultName `
        --name $secretName `
        --value $value `
        --query "id" -o tsv | Out-Null
}

Write-Host "Uploaded $($SecretNames.Count) secret(s) to '$VaultName'." -ForegroundColor Green
