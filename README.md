# VariableGroups → web.config

A tiny configuration pipeline that turns a small set of JSON schema files into
a fully-tokenized `web.config` for an ASP.NET app, using **Azure DevOps
Variable Groups** for non-secret config and **Azure Key Vault** for secrets.

It solves three problems at once:

1. **Single source of truth for schema** — `config/common.json` lists every
   appSetting and connection string the app understands (key names + connection
   string `providerName` metadata). No values live here.
2. **One mechanism for every value** — every key is emitted as a `#{Token}#`
   in `web.config` and resolved at pipeline time from ADO + Key Vault. There
   are no committed values to worry about.
3. **Secrets stay in Key Vault** — the repo only contains tokenized config;
   common and env secrets alike are pulled from AKV at pipeline runtime via
   Key-Vault-linked variable groups.

```
config/common.json   ── schema: shared keys + connection providerName
config/dev.json      ── schema: keys this env adds/overrides
config/prod.json     ── schema: keys this env adds/overrides
        │
        ▼
values.common.json   ── publisher worksheet for shared values    (gitignored)
values.<env>.json    ── publisher worksheet for env-only values   (gitignored)
        │
        ▼
Build-WebConfig.ps1  ── emits web.config with #{Tokens}# everywhere
        │
        ▼
ADO pipeline (per stage, in this order — later groups override earlier)
  ├─ webconfig-common          (non-secret shared defaults)
  ├─ webconfig-common-secrets  (KV-linked, common-* secrets)
  ├─ webconfig-<env>           (non-secret env overrides)
  └─ webconfig-<env>-secrets   (KV-linked, <env>-* secrets)
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
| `config/common.json` | Schema: shared key names + connection-string `providerName` metadata |
| `config/dev.json` | Schema: appSettings + connectionStrings used by `dev` (in addition to common) |
| `config/prod.json` | Schema: appSettings + connectionStrings used by `prod` (in addition to common) |
| `Build-WebConfig.ps1` | Generates a tokenized `web.config` for an environment |
| `Publish-VariableGroup.ps1` | Creates/updates a **non-secret** ADO variable group (`common` or `<env>`) |
| `Publish-VaultSecret.ps1` | Uploads **secret** values to Azure Key Vault (`common` or `<env>` prefix) |
| `values.common.json` | **Local-only** publisher worksheet for shared values (gitignored) |
| `values.<env>.json` | **Local-only** publisher worksheet for env values (gitignored) |
| `azure-pipelines.yml` | Two-stage CI pipeline (Dev → Prod) |
| `pipeline/steps-build-webconfig.yml` | Reusable steps template |

---

## How the JSON files work together

### `config/common.json`

The schema for keys that exist in every environment. Lists `appSetting` names
and, for every known connection string, its structural metadata (`providerName`).
No values live here. Every key listed here becomes a `#{Token}#` in the
generated `web.config` and is resolved from the `webconfig-common(-secrets)`
variable groups at pipeline time.

```json
{
  "appSettings": ["EnableFeatureX", "CacheDurationMinutes"],
  "connectionStrings": {
    "DefaultConnection": { "providerName": "System.Data.SqlClient" },
    "StorageConnection": { "providerName": "Custom" }
  }
}
```

### `config/<env>.json`

Keys this environment adds on top of common, or overrides. Anything listed
here is also emitted as a `#{Token}#` and resolved from `webconfig-<env>(-secrets)`.
Because the env group is applied **after** the common group, env values win on
overlapping keys.

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

Note: connection strings are always env-specific in this design — there's no
shared connection string list. If two envs happen to use the same name (e.g.
`DefaultConnection`), each env's value comes from its own `webconfig-<env>-secrets`
entry.

### Rules the build script enforces

- Every `appSetting` from `common.json` is emitted as `<add key="X" value="#{X}#" />`.
- Every `appSetting` from `<env>.json` is appended (also tokenized) unless it
  already appeared via common.
- A `connectionString` listed in `<env>.json` is emitted with
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
    <add key="CacheDurationMinutes" value="#{CacheDurationMinutes}#" />
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

Every key is a token. None of the values are committed anywhere.

### 2. Provide values in `values.common.json` and `values.<env>.json`

These files are **gitignored** — they're your local worksheet for what gets
uploaded to the variable groups + Key Vault. Symmetric shape: a flat map of
`{ "VarName": "value", "…": "…" }`.

```jsonc
// values.common.json  — values for keys in config/common.json's appSettings
{
  "EnableFeatureX": "false",
  "CacheDurationMinutes": "30"
}
```

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

`Publish-VariableGroup.ps1` will refuse to publish if any required key for
that scope is missing from the corresponding values file.
### 3. Publish: non-secrets to ADO, secrets to Key Vault

The local workflow uses two scripts, run once per scope (`common`, `dev`, `prod`):

```powershell
# one-time: log in
az login
az devops login   # (or rely on AZURE_DEVOPS_EXT_PAT env var)

# --- common scope (shared defaults) ---
# Push shared non-secret values into the ADO variable group `webconfig-common`.
.\Publish-VariableGroup.ps1 `
    -Environment  common `
    -Organization aarsan-nw `
    -Project      Infrastructure

# (No common secrets yet — skip the next call until you add some.)
# .\Publish-VaultSecret.ps1 -Environment common -VaultName Progger -SecretNames SharedApiKey

# --- dev scope ---
# Push dev non-secret values; anything in -SecretNames is EXCLUDED from the group
# (it goes to AKV instead).
.\Publish-VariableGroup.ps1 `
    -Environment  dev `
    -Organization aarsan-nw `
    -Project      Infrastructure `
    -SecretNames  DefaultConnection

# Push dev secrets to AKV, prefixed with the scope (e.g. `dev-DefaultConnection`).
.\Publish-VaultSecret.ps1 `
    -Environment dev `
    -VaultName   Progger `
    -SecretNames DefaultConnection
```

Re-running either script updates values in place. `Publish-VariableGroup.ps1`
also deletes any leftover variable in the group that's now listed in
`-SecretNames` (because it should only live in AKV from now on).

#### Why prefix the AKV secret names?

One vault stores secrets for many scopes. Storing them as
`common-SharedApiKey` / `dev-DefaultConnection` / `prod-DefaultConnection`
keeps them separated. Each KV-linked variable group lists only the matching
prefix per scope, and the pipeline aliases each one back to its bare name
(`SharedApiKey`, `DefaultConnection`) before the token-replacement step. That
way the `#{Token}#` names in the generated `web.config` stay scope-agnostic.
---

## CI pipeline

`azure-pipelines.yml` runs two stages (Dev then Prod). Each stage references
**four** variable groups, applied in order so later groups override earlier:

1. `webconfig-common` — plain ADO group with shared non-secret values
   (created by `Publish-VariableGroup.ps1 -Environment common`).
2. `webconfig-common-secrets` — **Key-Vault-linked** group exposing `common-*`
   secrets from the vault.
3. `webconfig-<env>` — plain ADO group with env-specific non-secret values.
4. `webconfig-<env>-secrets` — **Key-Vault-linked** group exposing `<env>-*`
   secrets.

> **Why two groups per scope?** ADO's "link to Azure Key Vault" toggle is
> all-or-nothing per variable group: when it's on, *every* variable in the
> group must come from the vault and you can't add plain literal values
> alongside them. The standard pattern is therefore one plain group for
> non-secrets + one KV-linked group for secrets, both referenced together in
> the stage. They merge into the same variable scope at runtime, so steps
> just see `$(LogLevel)`, `$(common-CacheDurationMinutes)` and
> `$(dev-DefaultConnection)` side by side.

The template aliases each `common-*` and `<env>-*` secret to its bare name
(common first, env second — so env wins), then runs the
[`qetza.replacetokens`](https://marketplace.visualstudio.com/items?itemName=qetza.replacetokens-task)
marketplace task to substitute `#{Token}#` placeholders, and publishes the
result as an artifact (`webconfig-dev` / `webconfig-prod`).

```yaml
trigger:
  branches:
    include: [ main ]

pool:
  name: Default   # self-hosted

stages:
  - stage: Dev
    variables:
      - group: webconfig-common          # shared non-secret defaults
      - group: webconfig-common-secrets  # KV-linked shared secrets (common-*)
      - group: webconfig-dev             # dev-specific non-secrets (overrides common)
      - group: webconfig-dev-secrets     # KV-linked dev secrets (dev-*)
    jobs:
      - job: Build
        steps:
          - template: pipeline/steps-build-webconfig.yml
            parameters:
              environment: dev
              commonSecretNames: []      # add names here once common secrets exist
              secretNames:
                - DefaultConnection

  - stage: Prod
    dependsOn: Dev
    variables:
      - group: webconfig-common
      - group: webconfig-common-secrets
      - group: webconfig-prod
      - group: webconfig-prod-secrets
    jobs:
      - job: Build
        steps:
          - template: pipeline/steps-build-webconfig.yml
            parameters:
              environment: prod
              commonSecretNames: []
              secretNames:
                - DefaultConnection
                - StorageConnection
```

### Prerequisites in your ADO org / Azure

1. Install the **Replace Tokens** marketplace extension
   (`qetza.replacetokens`).
2. An ARM service connection in ADO whose service principal has the
   **Key Vault Secrets User** role on the target vault. This SC is what the
   Key-Vault-linked variable groups use to read secrets.
3. Your own user account needs **Key Vault Secrets Officer** (or higher) on
   the vault to run `Publish-VaultSecret.ps1`.
4. Either an MS-hosted parallelism grant, or a self-hosted agent in a pool
   called `Default`. The included pipeline targets the latter.
5. All six variable groups (`webconfig-common`, `webconfig-common-secrets`,
   `webconfig-dev`, `webconfig-dev-secrets`, `webconfig-prod`,
   `webconfig-prod-secrets`) must be authorized for the pipeline. Use the
   **Open access** toggle on each group (or it prompts on first run).

### Notes on PowerShell on ARM Windows

The pipeline template sets `PSModulePath: ''` for the `PowerShell@2` task and
uses `pwsh: true` to avoid loading Windows PowerShell 5.1 modules on top of
PowerShell 7. This is required on native ARM64 agents to avoid
`Microsoft.PowerShell.Security` load errors.

---

## End-to-end checklist

```text
1. Edit config/common.json    ── add new shared keys + providerName metadata
2. Edit config/<env>.json     ── list keys this env adds/overrides
3. Edit values.common.json    ── supply real shared values  (local only)
4. Edit values.<env>.json     ── supply real env values     (local only)
5. Publish-VariableGroup.ps1  ── push non-secrets to ADO (run per scope)
6. Publish-VaultSecret.ps1    ── push secrets to AKV    (run per scope, prefixed)
7. git push                   ── pipeline regenerates + publishes web.config
```

---

## Secrets hygiene

- All `values.*.json` files (including `values.common.json`), `web.config`,
  and `.env` are gitignored. No values — secret or otherwise — are committed.
- Anything listed in `-SecretNames` is **excluded from the ADO variable group**
  and pushed to Key Vault instead. The pipeline pulls it at runtime via the
  service connection's SP.
- `Publish-VariableGroup.ps1` also removes any stale variable from the ADO
  group that's now in `-SecretNames`, so it's safe to migrate a variable from
  ADO to AKV by simply re-running both publishers.
- Never commit a `.env` file — the repo's PAT or any other secret should live
  only on your machine.
