# VariableGroups → web.config

A tiny configuration pipeline that turns two JSON files into a fully-populated
`web.config` for an ASP.NET app, using **Azure DevOps Variable Groups** for
non-secret config and **Azure Key Vault** for secrets.

It solves three problems at once:

1. **Single source of truth for schema** — `config/common.json` lists every
   appSetting and connection string the app understands (with default values
   and connection-string `providerName` metadata).
2. **Zero duplication per environment** — each `config/<env>.json` only declares
   *which* keys that environment cares about. Values live in ADO + Key Vault.
3. **Secrets stay in Key Vault** — the repo only contains tokenized config
   (`#{VarName}#`); connection strings are pulled from AKV at pipeline runtime.

```
config/common.json   ── defaults + connection providerName
config/dev.json      ── list of keys this env needs
config/prod.json     ── list of keys this env needs
        │
        ▼
Build-WebConfig.ps1  ── emits web.config with #{Tokens}#
        │
        ▼
ADO pipeline
  ├─ ADO variable group  (non-secret values)
  └─ AzureKeyVault@2     (env-prefixed secrets, e.g. `dev-DefaultConnection`)
        │
        ▼
Replace Tokens task
        │
        ▼
web.config artifact  ── ready to deploy
```

---

## Repository layout

| Path | Purpose |
| --- | --- |
| `config/common.json` | Shared defaults + connection-string metadata |
| `config/dev.json` | List of appSettings + connectionStrings used by `dev` |
| `config/prod.json` | List of appSettings + connectionStrings used by `prod` |
| `Build-WebConfig.ps1` | Generates a tokenized `web.config` for an environment |
| `Publish-VariableGroup.ps1` | Creates/updates the **non-secret** ADO variable group |
| `Publish-VaultSecret.ps1` | Uploads the **secret** values to Azure Key Vault |
| `values.<env>.json` | **Local-only** values for that environment (gitignored) |
| `azure-pipelines.yml` | Two-stage CI pipeline (Dev → Prod) |
| `pipeline/steps-build-webconfig.yml` | Reusable steps template |

---

## How the JSON files work together

### `config/common.json`

Holds defaults for keys that don't change per environment, plus structural
metadata (`providerName`) for every known connection string.

```json
{
  "appSettings": {
    "EnableFeatureX": "false",
    "CacheDurationMinutes": "30"
  },
  "connectionStrings": {
    "DefaultConnection": { "providerName": "System.Data.SqlClient" },
    "StorageConnection": { "providerName": "Custom" }
  }
}
```

### `config/<env>.json`

Lists which keys this environment overrides (appSettings) or uses
(connectionStrings). Anything listed here will become a `#{Token}#` in the
generated `web.config` and a variable in the ADO variable group.

```jsonc
// config/dev.json
{
  "appSettings": ["LogLevel", "EnableFeatureX", "DevPortalUrl"],
  "connectionStrings": ["DefaultConnection"]
}
```

```jsonc
// config/prod.json
{
  "appSettings": ["LogLevel", "CDNEndpoint"],
  "connectionStrings": ["DefaultConnection", "StorageConnection"]
}
```

### Rules the build script enforces

- An `appSetting` listed in the env file → emitted as `<add key="X" value="#{X}#" />`.
- An `appSetting` only in `common.json` → emitted with its literal default value.
- A `connectionString` listed in the env file → emitted with
  `connectionString="#{Name}#"` and `providerName` looked up in `common.json`.
- Referencing a connection string that isn't declared in `common.json` is an
  error — add the `providerName` there first.

---

## Local workflow

### 1. Generate a tokenized `web.config`

```powershell
# generate web.config for dev
.\Build-WebConfig.ps1 -Environment dev

# or for prod, into a custom path
.\Build-WebConfig.ps1 -Environment prod -OutputPath .\out\web.prod.config
```

Result (dev):

```xml
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <appSettings>
    <add key="EnableFeatureX" value="#{EnableFeatureX}#" />
    <add key="CacheDurationMinutes" value="30" />
    <add key="LogLevel" value="#{LogLevel}#" />
    <add key="DevPortalUrl" value="#{DevPortalUrl}#" />
  </appSettings>
  <connectionStrings>
    <add name="DefaultConnection"
         connectionString="#{DefaultConnection}#"
         providerName="System.Data.SqlClient" />
  </connectionStrings>
</configuration>
```

### 2. Provide values in a `values.<env>.json` file

These files are **gitignored** — they are your local copy of what gets
uploaded to the variable group. Use them as a worksheet before pushing.

```jsonc
// values.dev.json
{
  "LogLevel": "Debug",
  "EnableFeatureX": "true",
  "DevPortalUrl": "https://dev.portal.example.com",
  "DefaultConnection": "Server=devsql.example.com;Database=AppDev;User Id=appuser;Password=REPLACE_ME;"
}
```

```jsonc
// values.prod.json
{
  "LogLevel": "Warning",
  "CDNEndpoint": "https://cdn.example.com",
  "DefaultConnection": "Server=prodsql.example.com;Database=AppProd;User Id=appuser;Password=REPLACE_ME;",
  "StorageConnection": "DefaultEndpointsProtocol=https;AccountName=prodstore;AccountKey=REPLACE_ME"
}
```

The script will refuse to publish if any key listed in `config/<env>.json`
is missing from `values.<env>.json`.

### 3. Publish: non-secrets to ADO, secrets to Key Vault

The local workflow uses two scripts, one per destination:

```powershell
# one-time: log in
az login
az devops login   # (or rely on AZURE_DEVOPS_EXT_PAT env var)

# Push the non-secret variables into the ADO variable group.
# Anything listed in -SecretNames is EXCLUDED from the group (it goes to AKV).
.\Publish-VariableGroup.ps1 `
    -Environment  dev `
    -Organization aarsan-nw `
    -Project      Infrastructure `
    -SecretNames  DefaultConnection

# Push the secret values into Azure Key Vault, prefixed by environment
# (e.g. `dev-DefaultConnection`). The pipeline strips the prefix at runtime.
.\Publish-VaultSecret.ps1 `
    -Environment dev `
    -VaultName   Progger `
    -SecretNames DefaultConnection
```

Re-running either script updates values in place. `Publish-VariableGroup.ps1`
also deletes any leftover variable in the group that's now listed in
`-SecretNames` (because it should only live in AKV from now on).

#### Why env-prefix the AKV secret names?

One vault stores secrets for many environments. Storing them as
`dev-DefaultConnection` / `prod-DefaultConnection` keeps them separated. The
pipeline's `AzureKeyVault@2` task pulls only the matching prefix per stage
(`SecretsFilter: dev-*`), then aliases each one back to its bare name
(`DefaultConnection`) before the token-replacement step. That way the
`#{Token}#` names in the generated `web.config` stay environment-agnostic.

---

## CI pipeline

`azure-pipelines.yml` runs two stages (Dev then Prod). Each stage links the
matching `webconfig-<env>` variable group, pulls env-prefixed secrets from the
`Progger` Key Vault via the `AzureKeyVault@2` task, replaces tokens with both
sets of values via the
[`qetza.replacetokens`](https://marketplace.visualstudio.com/items?itemName=qetza.replacetokens-task)
marketplace task, and publishes the result as an artifact
(`webconfig-dev` / `webconfig-prod`).

```yaml
trigger:
  branches:
    include: [ main ]

pool:
  name: Default   # self-hosted

variables:
  KeyVaultName: Progger
  KeyVaultServiceConnection: 'ahmet-azure-sub (...)'

stages:
  - stage: Dev
    variables:
      - group: webconfig-dev
    jobs:
      - job: Build
        steps:
          - template: pipeline/steps-build-webconfig.yml
            parameters:
              environment: dev
              vaultName: $(KeyVaultName)
              serviceConnection: $(KeyVaultServiceConnection)
              secretNames:
                - DefaultConnection

  - stage: Prod
    dependsOn: Dev
    variables:
      - group: webconfig-prod
    jobs:
      - job: Build
        steps:
          - template: pipeline/steps-build-webconfig.yml
            parameters:
              environment: prod
              vaultName: $(KeyVaultName)
              serviceConnection: $(KeyVaultServiceConnection)
              secretNames:
                - DefaultConnection
                - StorageConnection
```

### Prerequisites in your ADO org / Azure

1. Install the **Replace Tokens** marketplace extension
   (`qetza.replacetokens`).
2. An ARM service connection in ADO whose service principal has the
   **Key Vault Secrets User** role on the target vault.
3. Your own user account needs **Key Vault Secrets Officer** (or higher) on
   the vault to run `Publish-VaultSecret.ps1`.
4. Either an MS-hosted parallelism grant, or a self-hosted agent in a pool
   called `Default`. The included pipeline targets the latter.
5. The variable groups (`webconfig-dev`, `webconfig-prod`) must be authorized
   for the pipeline (the first run prompts; permit once). The Key Vault task
   is authorized via the service connection.

### Notes on PowerShell on ARM Windows

The pipeline template sets `PSModulePath: ''` for the `PowerShell@2` task and
uses `pwsh: true` to avoid loading Windows PowerShell 5.1 modules on top of
PowerShell 7. This is required on native ARM64 agents to avoid
`Microsoft.PowerShell.Security` load errors.

---

## End-to-end checklist

```text
1. Edit config/common.json   ── add new keys + providerName metadata
2. Edit config/<env>.json    ── list keys this env should tokenize
3. Edit values.<env>.json    ── supply real values (local only)
4. Publish-VariableGroup.ps1 ── push non-secret values to ADO
5. Publish-VaultSecret.ps1   ── push secrets to Azure Key Vault (env-prefixed)
6. git push                  ── pipeline regenerates + publishes web.config
```

---

## Secrets hygiene

- `values.*.json`, `web.config`, and `.env` are gitignored.
- Anything listed in `-SecretNames` is **excluded from the ADO variable group**
  and pushed to Key Vault instead. The pipeline pulls it at runtime via the
  service connection's SP.
- `Publish-VariableGroup.ps1` also removes any stale variable from the ADO
  group that's now in `-SecretNames`, so it's safe to migrate a variable from
  ADO to AKV by simply re-running both publishers.
- Never commit a `.env` file — the repo's PAT or any other secret should live
  only on your machine.
