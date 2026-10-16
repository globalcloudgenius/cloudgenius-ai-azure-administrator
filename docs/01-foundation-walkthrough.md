# Script 1: Foundry foundation — annotated walkthrough

Source: [01-Deploy-CloudGeniusFoundry.ps1](../scripts/01-Deploy-CloudGeniusFoundry.ps1).

This guide explains the script *in execution order*, including each meaningful statement and each Azure CLI command. Comments and blank lines do not execute actions.

## Start and parameters

| Script line / symbol | Purpose |
| --- | --- |
| `#Requires -Version 5.1` | Requires a compatible PowerShell interpreter. |
| `$ErrorActionPreference = 'Stop'` | Converts PowerShell non-terminating errors into terminating ones where applicable. |
| `Set-StrictMode -Version Latest` | Catches unintended use of unset variables and other common mistakes. |
| `$SubscriptionId` | Azure subscription target. **Replace with your own subscription ID** before deploying. |
| `$ResourceGroup = 'rg-cloudgenius-ai-dev'` | All POC Azure resources are grouped here for organization and cleanup. |
| `$Location = 'eastus'` | Azure deployment region; model quotas and availability depend on region and subscription. |
| `$VNetName`, `$VNetCidr` | Set VNet name and address space `10.50.0.0/16`. |
| `$SubnetName`, `$SubnetCidr` | Subnet `snet-ai-private-endpoints` with range `10.50.1.0/24`. It is reserved for a future private endpoint; none is created by these scripts. |
| `$ProjectName` | Microsoft Foundry project name. |
| `$DeploymentName` | Deployment alias, not base model name. API calls use this alias. |
| `$ModelName`, `$ModelVersion` | GPT-5-mini, specific version `2025-08-07`. |
| `$Capacity = 10` | Requested GlobalStandard deployment capacity of ten 1,000-tokens/minute units (subject to quota). |
| `$ConfigPath = Join-Path $PSScriptRoot ...` | Writes runtime config beside Script 1 so Script 2 can discover the new Foundry name. |

### Helper functions

`Invoke-AzCli` receives an array of argument tokens, runs `az @Arguments 2>&1`, checks `$LASTEXITCODE` and throws if the Azure CLI command failed. `Out-String` and `Trim()` normalize output for comparisons or JSON conversion. Each command therefore stops the script if Azure CLI reports an error.

`Assert-True` throws when a required invariant is false. The script never treats a successful **create** command alone as sufficient evidence: it makes follow-up **show/list** requests.

## Authentication and subscription guard

1. `Get-Command az` confirms the CLI is installed.
2. `az account set --subscription <subscription-ID>` selects the target subscription.
3. `az account show --query id -o tsv` returns only the selected subscription ID.
4. `Assert-True` checks that the returned ID exactly matches the expected subscription.

This script does not call `az login` itself. Run `az login` interactively before starting.

## Foundry name and local config

- If `cloudgenius-ai-config.json` exists, it is parsed and checked against the subscription and resource group; the existing Foundry name is reused.
- Otherwise a candidate is generated: `'cgfoundry' + Get-Random` with a six-digit number.
- The regex `^cgfoundry[0-9]{6}$` rejects a malformed Foundry name.

The generated name changes on a clean installation. Do not blindly copy a Foundry resource name from someone else's deployment.

## Step 1: Resource group

~~~powershell
az group exists --name rg-cloudgenius-ai-dev
az group create --name rg-cloudgenius-ai-dev --location eastus --output none
~~~

`group exists` returns `true` or `false`. The script creates the group only if absent. `--output none` suppresses bulk JSON output but does not suppress errors.

## Step 2: Virtual network and subnet

~~~powershell
az network vnet list --resource-group rg-cloudgenius-ai-dev --query "[?name=='vnet-cloudgenius-ai'] | length(@)" --output tsv
az network vnet create --resource-group rg-cloudgenius-ai-dev --name vnet-cloudgenius-ai --location eastus --address-prefixes 10.50.0.0/16 --output none
az network vnet show --resource-group rg-cloudgenius-ai-dev --name vnet-cloudgenius-ai --output json
~~~

The list-query returns the count of same-name VNets. Creation occurs only for count zero. The **show** response is converted with `ConvertFrom-Json` and checked for `provisioningState == Succeeded` and the expected address prefix.

~~~powershell
az network vnet subnet list --resource-group rg-cloudgenius-ai-dev --vnet-name vnet-cloudgenius-ai --query "[?name=='snet-ai-private-endpoints'] | length(@)" --output tsv
az network vnet subnet create --resource-group rg-cloudgenius-ai-dev --vnet-name vnet-cloudgenius-ai --name snet-ai-private-endpoints --address-prefixes 10.50.1.0/24 --output none
az network vnet subnet show --resource-group rg-cloudgenius-ai-dev --vnet-name vnet-cloudgenius-ai --name snet-ai-private-endpoints --output json
~~~

The subnet is created only if absent; the script verifies its state and CIDR. **Creating the subnet does not create a Private Endpoint or connect any workloads to Storage.**

## Step 3: Foundry AIServices account

~~~powershell
az cognitiveservices account list --resource-group rg-cloudgenius-ai-dev --query "[?name=='<generated-name>'] | length(@)" --output tsv
az cognitiveservices account create --name <generated-name> --resource-group rg-cloudgenius-ai-dev --kind AIServices --sku S0 --location eastus --custom-domain <generated-name> --assign-identity --allow-project-management true --output none
az cognitiveservices account show --name <generated-name> --resource-group rg-cloudgenius-ai-dev --output json
~~~

- `--kind AIServices`: provisions the Foundry-capable Azure AI Services resource.
- `--sku S0`: selects the service tier used by this example.
- `--custom-domain`: sets account custom subdomain.
- `--assign-identity`: gives the resource a system-assigned managed identity; **it is not the identity used by the local Azure CLI execution**.
- `--allow-project-management true`: permits Foundry project management.
- Verification checks resource kind and location.

## Step 4: Foundry project

~~~powershell
az cognitiveservices account project list --name <foundry-name> --resource-group rg-cloudgenius-ai-dev --output json
az cognitiveservices account project create --name <foundry-name> --resource-group rg-cloudgenius-ai-dev --project-name cloudgenius-ai-project --location eastus --output none
~~~

The script creates the project only if missing, re-lists projects and matches either a fully-qualified `<foundry-name>/cloudgenius-ai-project` form or the project name.

## Step 5: Model deployment

~~~powershell
az cognitiveservices account deployment list --name <foundry-name> --resource-group rg-cloudgenius-ai-dev --output json
az cognitiveservices account deployment create --name <foundry-name> --resource-group rg-cloudgenius-ai-dev --deployment-name cg-gpt-5-mini --model-name gpt-5-mini --model-version 2025-08-07 --model-format OpenAI --sku-name GlobalStandard --sku-capacity 10 --output none
az cognitiveservices account deployment show --name <foundry-name> --resource-group rg-cloudgenius-ai-dev --deployment-name cg-gpt-5-mini --output json
~~~

GPT-6.1-sol was not available under the original subscription's quota; GPT-5-mini had quota and was proven to work. The script uses GPT-5-mini by default, then checks **Succeeded**, model name and model version.

A model being listed as available in a region is *not* proof that your subscription has deployment quota.

## Step 6: Local configuration for Script 2

`ConvertTo-Json` serializes names, region, subscription, deployment alias and model metadata; `Set-Content` writes `cloudgenius-ai-config.json` in the script directory. It contains **no API key**. Keep it local anyway, since it identifies your subscription and environment.

## Expected result

- Console ends with `SUCCESS: Azure/Foundry environment verified.`
- Your project config JSON is written.
- No Storage account exists solely as a result of Script 1.
- Script 2 can now run from the same clone.

### Common failures

- `az login` needed: credentials not cached/expired.
- Insufficient authorization: check role assignments, not just subscription visibility.
- `InsufficientQuota`: choose an authorized model/capacity/region or request more quota; don't assume a listed model is deployable.
- Global name conflict / soft-deleted Foundry name: use a new unique name and delete any stale **local** config after intentionally confirming the original account was decommissioned.
- Unexpected VNet CIDR or model version: script refuses to accept the mismatch rather than silently rewrite existing resources.
