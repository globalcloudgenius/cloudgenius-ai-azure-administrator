# CloudGenius AI Azure Administrator

AI-powered Azure infrastructure administration using Microsoft Foundry, GPT function calling, PowerShell, and Azure CLI. Demonstrates human-approved infrastructure deployment, security enforcement, and automated resource verification.

> **Status:** Working proof of concept, not a production autonomous administrator. Tested successfully in Windows PowerShell / VS Code on 2026-10-16. Deploying resources can incur Azure charges.

## What this repository provides

Two scripts that implement the complete, reproducible demonstration:

| Order | Script | What it does |
| --- | --- | --- |
| 1 | [01-Deploy-CloudGeniusFoundry.ps1](scripts/01-Deploy-CloudGeniusFoundry.ps1) | Creates/verifies the resource group, VNet, subnet, Microsoft Foundry AIServices account, Foundry project and GPT-5-mini deployment; saves non-secret local configuration |
| 2 | [02-GPT-Deploy-SecureStorage.ps1](scripts/02-GPT-Deploy-SecureStorage.ps1) | Sends a tool definition and deployment request to GPT, validates GPT's function call, asks for your explicit approval, executes a secure Azure CLI storage deployment, independently verifies the resource and sends the result back to GPT |

**Important distinction:** GPT *requested* the operation by emitting a function call. GPT did **not** execute Azure CLI or directly create Azure resources. PowerShell is the trusted execution/approval boundary; Azure Resource Manager actually provisions the resource.

## Prerequisites

- Windows PowerShell 5.1+ or PowerShell 7+; Visual Studio Code with a PowerShell terminal is optional.
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) installed; confirm with `az version`.
- Sign in interactively: `az login`.
- Permission to create resource groups, networks, Microsoft.CognitiveServices AIServices resources/projects/model deployments, Storage accounts and to list Foundry account keys.
- A subscription with GPT-5-mini **GlobalStandard** quota in East US. The demonstrated environment had capacity 10 (10,000 tokens/minute), but quota/availability depend on your subscription.
- **Configure your own subscription ID** at the top of Script 1 before running. The committed sample ID is the original demonstration subscription, **not** a shared subscription you can deploy to. Script 2 reads the ID from the JSON file created by Script 1.
- Azure resources incur costs. Review usage and clean up after the demo.

## Quick start — copy, configure and run

In PowerShell:

~~~powershell
git clone https://github.com/globalcloudgenius/cloudgenius-ai-azure-administrator.git
cd cloudgenius-ai-azure-administrator
az login
~~~

Open `scripts/01-Deploy-CloudGeniusFoundry.ps1` and replace the `$SubscriptionId` value with **your own** Azure subscription ID. Check region, naming and requested quota before continuing.

Run **Script 1**:

~~~powershell
& ".\scripts\01-Deploy-CloudGeniusFoundry.ps1"
~~~

After `SUCCESS: Azure/Foundry environment verified` appears, run **Script 2**:

~~~powershell
& ".\scripts\02-GPT-Deploy-SecureStorage.ps1"
~~~

When Script 2 displays the resource name, region and security settings, it waits for the literal confirmation **APPROVE**. Without it, no storage creation command is executed.

### Script execution policy

If you receive `cannot be loaded ... not digitally signed`, inspect the scripts and their source first. For downloaded scripts you trust, run:

~~~powershell
Get-ChildItem ".\scripts\*.ps1" | Unblock-File
~~~

If an authorized local environment still blocks them, a temporary **process-scoped** policy may help (organization-managed policy can still override it):

~~~powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
~~~

Never globally weaken an organization's script execution controls.

## Expected Azure resource configuration

| Resource / setting | Value |
| --- | --- |
| Resource group | `rg-cloudgenius-ai-dev` |
| Region | `eastus` |
| VNet | `vnet-cloudgenius-ai`, `10.50.0.0/16` |
| Reserved subnet | `snet-ai-private-endpoints`, `10.50.1.0/24` |
| Foundry resource | Generated unique name, e.g. `cgfoundry170463` |
| Foundry project | `cloudgenius-ai-project` |
| Model deployment | `cg-gpt-5-mini` |
| Model | `gpt-5-mini`, version `2025-08-07`, GlobalStandard, capacity 10 |
| Storage name | Generated unique name, e.g. `cgaistore610655` |
| Storage SKU/type | `Standard_LRS` / `StorageV2` |
| HTTPS only | `true` |
| Minimum TLS | `TLS1_2` |
| Allow anonymous blob access | `false` |
| Public network access | `Disabled` |
| Allow Shared Key authentication | `false` |

**Storage is not usable over the public endpoint** with public network access disabled. The reserved subnet is created by Script 1, but **no Private Endpoint, Private DNS integration, VNet client, or Storage Blob Data RBAC is deployed** in this proof of concept.

## Documentation

- [Foundation deployment — step-by-step command and variable explanations](docs/01-foundation-walkthrough.md)
- [GPT deployment — detailed function calling, approval, verification and tool response](docs/02-gpt-storage-walkthrough.md)
- [Security model, troubleshooting and operational notes](docs/03-security-operations.md)

## Deployment architecture

~~~text
Windows administrator / VS Code PowerShell
    |
    | Script 1: Azure CLI with signed-in administrator
    v
Azure Resource Manager
    +-- Resource Group / Virtual Network / Subnet
    +-- Microsoft Foundry AIServices / Project
    +-- GPT-5-mini deployment

Windows administrator / VS Code PowerShell
    |
    | Script 2: HTTPS request to Foundry Responses API
    v
GPT-5-mini
    |
    | returns function_call: deploy_storage_account
    | arguments: {"storage_name":"cgaistore..."}
    v
Local PowerShell executor
    +-- validates GPT-requested name matches approved candidate
    +-- checks global name availability
    +-- prompts human to type APPROVE
    +-- executes fixed-policy az storage account create
    +-- reads Azure resource and verifies all security values
    |
    | function_call_output includes actual verified Azure result
    v
GPT-5-mini -> final narrative report
~~~

## Independent verification

After Script 2 succeeds, retrieve the generated name from its console output, then run (replace the name with your own):

~~~powershell
az storage account show --name cgaistore610655 --resource-group rg-cloudgenius-ai-dev --query "{Name:name,State:provisioningState,HTTPS:enableHttpsTrafficOnly,TLS:minimumTlsVersion,AnonymousBlob:allowBlobPublicAccess,PublicNetwork:publicNetworkAccess,SharedKey:allowSharedKeyAccess}" --output json
~~~

Expected: `Succeeded`, `true`, `TLS1_2`, `false`, `Disabled`, `false`. Azure's actual API response is authoritative—not the model's prose.

## Safe repository usage and limitations

- **Do not commit** `cloudgenius-ai-config.json` if it contains environment identifiers you prefer to keep private; it contains no API key, but does contain subscription/resource metadata. It is gitignored by default.
- Never commit API keys, access tokens, credentials or full console transcripts that might contain secrets.
- Script 1 **does not delete or overwrite** existing infrastructure; it checks expected configuration where implemented. Script 2 intentionally generates a fresh storage name each run.
- Re-running Script 2 **creates another chargeable storage account** after approval; it is not storage-creation-idempotent.
- Original proof-of-concept authenticates Foundry calls with a locally retrieved account key and executes Azure CLI under your active `az login` permissions. Prefer managed identity, least-privilege RBAC, auditable approvals and credential-free inference for production.
- No fully hosted Foundry Agent Service agent is created; these are direct model tool calls orchestrated from PowerShell.
- Source history remains in GitHub; do not upload secrets, even if you later delete them.
- To remove demo resources, follow the Azure portal's resource group deletion flow **only after validating the group contains nothing important**. Deletion is irreversible for active resources. Foundry soft-delete/purge may require a separate authorized action.

## Learning outcomes

After a successful run you can explain the difference between **function declaration**, **model-generated function call**, **local function executor**, **human approval**, **Azure control-plane operation**, **independent verification** and **function-call output returned to the model**.

## Useful Microsoft documentation

- [Azure CLI documentation](https://learn.microsoft.com/cli/azure/)
- [Azure Storage security recommendations](https://learn.microsoft.com/azure/storage/common/security-recommendations)
- [Azure AI model inference and function calling](https://learn.microsoft.com/azure/ai-foundry/)
- [Azure Private Endpoint for Storage](https://learn.microsoft.com/azure/storage/common/storage-private-endpoints)

## License

No license is assigned by this README. All rights reserved unless the repository owner explicitly adds a license.
