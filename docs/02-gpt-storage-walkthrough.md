# Script 2: GPT-initiated Azure Storage deployment — annotated walkthrough

Source: [02-GPT-Deploy-SecureStorage.ps1](../scripts/02-GPT-Deploy-SecureStorage.ps1).

**Answer to “Did GPT create the Storage account?”** GPT-5-mini **initiated** deployment by returning a structured `deploy_storage_account` function call. The locally running PowerShell script required human approval and executed Azure CLI. **Azure Resource Manager actually created** the account.

## Architecture and trust boundary

~~~text
Operator -> PowerShell Script 2
                   |
                   +-- load config saved by Script 1
                   +-- generate unique Storage candidate
                   +-- invoke Foundry Responses API with tool schema
                   |
                   v
              GPT-5-mini
                   |
                   +-- function_call: deploy_storage_account
                       {"storage_name":"cgaistore610655"}
                   |
                   v
             PowerShell executor
                   +-- validate exact name + Azure availability
                   +-- display fixed security policy
                   +-- require human APPROVE
                   +-- az storage account create
                   +-- az storage account show + property comparisons
                   |
                   +-- function_call_output tied to call_id
                   v
              GPT-5-mini
                   |
                   +-- narrative report
~~~

Neither a hosted Foundry Agent Service agent nor an Azure Function App is required for this proof of concept.

## How the script works, section by section

| Script expression / command | Why it exists |
| --- | --- |
| `#Requires -Version 5.1` | Require a suitable PowerShell version. |
| `$ErrorActionPreference = 'Stop'`; `Set-StrictMode -Version Latest` | Stop on script errors and catch variable mistakes. |
| `Join-Path $PSScriptRoot 'cloudgenius-ai-config.json'` | Locate the local config written by Script 1. |
| `Test-Path`, `Get-Content -Raw | ConvertFrom-Json` | Require and parse config rather than guessing a Foundry resource name. |
| `Invoke-AzCli` | Run Azure CLI safely with an argument array; reject nonzero exit codes. |
| `Get-AIText` | Extract `output_text` from Foundry's response `message.content` objects. |
| `az account set` and `az account show` | Select and verify the intended subscription from the config. |
| `'cgaistore' + Get-Random` | Produce a candidate name for a new Storage account. |
| `az cognitiveservices account show --query properties.endpoint` | Discover the Foundry endpoint dynamically. |
| `az cognitiveservices account keys list --query key1` | Retrieve an API key **only into PowerShell memory**. This is a POC convenience, not preferred production authentication. |
| `$uri = $endpoint.TrimEnd('/') + '/openai/v1/responses'` | Address the deployed model's Responses API endpoint. |
| `$headers` | Include local Foundry key and JSON content type for the HTTPS request. |

### Function declaration — *not executable code*

The `$tools` array describes a strict callable interface:

~~~json
{
  "type": "function",
  "name": "deploy_storage_account",
  "description": "Request deployment of one secure Azure Storage account after human approval.",
  "parameters": {
    "type": "object",
    "properties": {
      "storage_name": {
        "type": "string",
        "description": "Unique lowercase Azure Storage account name (3-24 characters)"
      }
    },
    "required": ["storage_name"],
    "additionalProperties": false
  },
  "strict": true
}
~~~

The real description text is in the script. The key behavior is the same: GPT may return **only** the required `storage_name` parameter and cannot directly specify location, subscription or weaken fixed security options.

### Initial GPT request

The `$instructions` system-style instruction tells GPT to invoke the tool once, avoid fictitious approvals/rollback and report success only if the tool says `verified`.

The `$body` PowerShell hashtable contains:

| Field | Meaning |
| --- | --- |
| `model` | The deployment alias `cg-gpt-5-mini`, **not** simply the model family name. |
| `reasoning.effort = low` | Reduces unnecessary reasoning-token consumption for this narrow task. |
| `instructions` | Behavioral rules for GPT responses. |
| `tools` | One callable function schema. |
| `tool_choice = auto` | GPT can select that tool; the script rejects output that isn't exactly one correct call. |
| `input` | Your secure Storage deployment request with a predetermined generated name. |
| `max_output_tokens = 2000` | Provides budget for tool-calling output. |

`ConvertTo-Json -Depth 20` preserves nested objects. `Invoke-RestMethod -Method Post -Headers $headers -Body $body` submits the HTTPS request.

### GPT's actual function call

A successful response has the logical structure:

~~~json
{
  "type": "function_call",
  "name": "deploy_storage_account",
  "arguments": "{\"storage_name\":\"cgaistore610655\"}",
  "call_id": "call_<opaque-identifier>"
}
~~~

This is an **example of the output format**; the name and call ID vary each run. `$calls` filters the model's output for the exact function name. The script requires `Count -eq 1`.

`ConvertFrom-Json` extracts `storage_name` from the returned arguments. The exact name must match the locally generated candidate (`-cne` is case-sensitive) and match regex `^[a-z0-9]{3,24}$`.

GPT is **not trusted** to choose other names or resources.

### Safety gates before creation

1. `az storage account list --resource-group ...` makes sure the candidate is not already in the target group.
2. `az storage account check-name --name ...` checks global Azure Storage naming availability.
3. Console prints every deployment parameter, including region, SKU, HTTPS, TLS, anonymous blob settings, network access and Shared Key authentication.
4. `Read-Host` requires an explicit `APPROVE`; any other answer stops before resource creation.

### The actual Azure command

~~~powershell
az storage account create --name <approved-account> --resource-group rg-cloudgenius-ai-dev --location eastus --sku Standard_LRS --kind StorageV2 --https-only true --min-tls-version TLS1_2 --allow-blob-public-access false --public-network-access Disabled --allow-shared-key-access false --output none
~~~

| Switch | Azure effect |
| --- | --- |
| `--name` | Uses the validated GPT-requested account name. |
| `--resource-group` / `--location` | Uses fixed settings from trusted config. |
| `--sku Standard_LRS` | Locally redundant standard storage. |
| `--kind StorageV2` | General-purpose v2 storage. |
| `--https-only true` | Requires HTTPS to access Storage endpoints. |
| `--min-tls-version TLS1_2` | Requires TLS 1.2 or newer. |
| `--allow-blob-public-access false` | Disallows anonymous public blob/container access. |
| `--public-network-access Disabled` | Blocks public-endpoint network access; a private endpoint is required for private VNet data access. |
| `--allow-shared-key-access false` | Disables account-key-based Shared Key authorization for supported data operations. Use Entra-based access. |
| `--output none` | Keeps the console concise; failures still stop execution via the helper. |

The **local Azure CLI credential context** determines authorization. GPT does not have a cloud login.

### Independent verification

After `az storage account create`, the script calls:

~~~powershell
az storage account show --name <approved-account> --resource-group rg-cloudgenius-ai-dev --output json
~~~

Then compares all of these actual properties:

- `provisioningState == Succeeded`
- `enableHttpsTrafficOnly == true`
- `minimumTlsVersion == TLS1_2`
- `allowBlobPublicAccess == false`
- `publicNetworkAccess == Disabled`
- `allowSharedKeyAccess == false`
- `kind == StorageV2`
- `sku.name == Standard_LRS`

The status is `verified` only if every condition passes; otherwise `verification_failed`, with an error raised after attempting to report back to GPT.

### Returning results to GPT

The local script creates a JSON `$toolResult` containing the retrieved resource ID, all security properties, `status`, and `human_approval='granted_before_execution'`. This is **not** a fabricated AI response.

It then makes another Responses API request with:

~~~json
{
  "model": "cg-gpt-5-mini",
  "previous_response_id": "<initial response id>",
  "input": [{
    "type": "function_call_output",
    "call_id": "<same GPT call id>",
    "output": "<JSON string of the actual verified Azure result>"
  }]
}
~~~

`previous_response_id` ties the second request to the original model response. `call_id` matches the specific requested tool operation. GPT uses the trusted output to write a final, readable deployment summary.

**Source of truth:** the Azure CLI `show` response and verified boolean comparisons. If GPT's final language differs, trust the actual Azure state.

## Expected successful output

~~~text
GPT called: deploy_storage_account with storage_name=cgaistore610655
Type APPROVE to CREATE storage account cgaistore610655: APPROVE
Executing Azure CLI deployment...
=== AZURE VERIFICATION ===
status                : verified
provisioning_state    : Succeeded
https_only            : True
minimum_tls           : TLS1_2
anonymous_blob_access : False
public_network_access : Disabled
shared_key_access     : False
=== FOUNDRY GPT REPORT ===
Deployment succeeded and verified.
SUCCESS: Azure Storage cgaistore610655 created and independently verified.
~~~

This is representative of the tested run; future names will differ. The script does not create a Private Endpoint or assign Blob Data RBAC.
