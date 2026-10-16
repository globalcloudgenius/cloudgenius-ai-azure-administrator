# SOP-CG-AI-001 — CloudGenius AI Azure Administrator (working POC)

**Version:** 1.0 · **Owner:** CloudGenius · **Scope:** Two PowerShell scripts committed under `scripts/` · **Status:** Validated POC, **not production authorization**

## 1. Objective and authorized operation
Reproduce a human-approved Azure Storage deployment using Microsoft Foundry GPT-5-mini **function calling** while independently verifying the deployed security properties. The local PowerShell executor—not GPT—holds authorization and executes Azure CLI. Only a new StorageV2 account in the configured resource group is within the Script 2 change scope.

**Recorded successful run (2026-10-16):** Foundry `cgfoundry170463`, model deployment `cg-gpt-5-mini`, account `cgaistore610655`, provisioning `Succeeded`, Azure security verification `verified`. These are historical observed values, not hardcoded names for new users.

## 2. Scope and environmental baseline

| Field | POC baseline | Source/interpretation |
| --- | --- | --- |
| Subscription | Configurable `$SubscriptionId` (original demo `7f54ad46-7f2f-453e-92dd-69f881e38371`) | Set in Script 1; Script 2 inherits generated local config |
| Resource group/region | `rg-cloudgenius-ai-dev`, `eastus` | Script 1 |
| VNet | `vnet-cloudgenius-ai`: `10.50.0.0/16` | Created or checked by Script 1 |
| Subnet | `snet-ai-private-endpoints`: `10.50.1.0/24` | Created or checked; no Private Endpoint |
| Foundry | New unique `cgfoundryNNNNNN` AIServices/S0 account | Script 1 saves chosen name |
| Foundry project | `cloudgenius-ai-project` | Script 1 |
| Model | `gpt-5-mini`, version `2025-08-07` | Alias `cg-gpt-5-mini`, GlobalStandard capacity 10 |
| Storage | `cgaistoreNNNNNN`, Standard_LRS, StorageV2 | Script 2 generates a new account per invocation |
| Storage baseline | HTTPS-only, TLS 1.2, no anonymous blob, public networking Disabled, Shared Key Disabled | Fixed Azure CLI flags and post-deployment assertions |

## 3. RACI / operating roles

| Activity | Administrator | GPT-5-mini | Local PowerShell executor | Azure services |
| --- | --- | --- | --- | --- |
| Select intended subscription | Accountable | None | Verifies | Supplies subscription context |
| Declare tool request | Observes | Responsible for `function_call` output | Defines and validates contract | Foundry hosts inference |
| Grant approval | **Accountable** (`APPROVE`) | No permission | Enforces prompt | No approval workflow in Azure |
| Execute creation | Authorizes | Does **not** execute | Calls `az storage account create` | ARM / Microsoft.Storage creates |
| Verify controls | Reviews | Reports result only | Queries and compares actual properties | ARM supplies authoritative state |
| Incident response | Reviews and remediates | No independent rollback | Throws/stops, can report failure | Azure resources persist until separately changed |

## 4. Preconditions — stop if any fail
1. Review both version-controlled scripts. Confirm scope, actual subscription ID, chargeable resources and fixed security parameters.
2. Run `az version`, `az login`, and `az account show --output table`. Ensure correct directory/tenant and role permissions to create resources and list Foundry account keys.
3. Confirm GPT-5-mini GlobalStandard capacity 10 is available in your subscription and `eastus`. A model's catalog listing alone does not confirm quota.
4. Confirm `10.50.0.0/16` and `10.50.1.0/24` do not conflict with any organization-connected networks. **No connectivity is provisioned** by this POC.
5. Confirm repository clone is a trusted version and review script signing policy. Never run arbitrary GitHub content with unrestricted credentials.
6. Ensure project resource group has no unrelated production assets and **keep a record of the change owner**.

## 5. Procedure A — deploy foundation (Script 1)

~~~powershell
git clone https://github.com/globalcloudgenius/cloudgenius-ai-azure-administrator.git
cd cloudgenius-ai-azure-administrator
az login
~~~

**Before execution:** Edit `$SubscriptionId` in `scripts/01-Deploy-CloudGeniusFoundry.ps1` to your subscription and review configured CIDRs / costs / policies. If Windows marks the downloaded script, review source, then `Get-ChildItem ".\scripts\*.ps1" | Unblock-File` if permitted.

~~~powershell
& ".\scripts\01-Deploy-CloudGeniusFoundry.ps1"
~~~

**Under the hood (in order):**
1. `az account set` and `az account show`: fails if selected subscription does not match.
2. Reuses validated local Foundry name if config already exists; otherwise generates `cgfoundryNNNNNN`.
3. Creates RG if missing, then verifies VNet `Succeeded` + CIDR and subnet `Succeeded` + CIDR.
4. Creates/verifies Foundry AIServices account with `--assign-identity` and `--allow-project-management true`.
5. Creates/verifies project; deploys or reuses GPT-5-mini; confirms model/version and provisioning state.
6. Writes **non-secret** `scripts/cloudgenius-ai-config.json` (ignored by Git), including Foundry name for Script 2.

**Checkpoint:** `SUCCESS: Azure/Foundry environment verified.` If not printed, do **not** proceed to Script 2. The existence of an account alone is not success.

## 6. Procedure B — GPT requests Storage, operator approves, Azure provisions

~~~powershell
& ".\scripts\02-GPT-Deploy-SecureStorage.ps1"
~~~

**Checkpoint chain:**

| Step | Actual script behavior | Pass criteria |
| --- | --- | --- |
| 1 | Loads local config; verifies subscription | Subscription ID equals configured ID |
| 2 | Generates new lowercase Storage name | Candidate matches `cgaistoreNNNNNN` form |
| 3 | Gets Foundry endpoint and `key1` into process memory | Both populated; **never print or commit the key** |
| 4 | POSTs to Foundry `/openai/v1/responses` with `deploy_storage_account` tool | Exactly one tool call with matching account name |
| 5 | Checks account does not already exist, checks global name availability | Not present and Azure says available |
| 6 | Prints **exact** RG, region, SKU and security policy; reads approval | Operator explicitly types uppercase `APPROVE` |
| 7 | Uses Azure CLI to create `StorageV2` | CLI exit code 0 (necessary, not sufficient) |
| 8 | Calls `az storage account show`; compares eight conditions | All required properties match |
| 9 | Returns `function_call_output` tagged with original `call_id` | GPT produces a report, if inference endpoint remains available |
| 10 | Prints final SUCCESS only after verified state | `status=verified` and `Succeeded` |

**Approval handling:** Type exactly `APPROVE` only after reviewing the target subscription, RG and controls. Any other response exits without *issuing the create command*. A GPT-generated request is **not** an approval.

### Verification command (replace sample Storage name with actual run output)

~~~powershell
az storage account show --name cgaistore610655 --resource-group rg-cloudgenius-ai-dev --query "{Name:name,State:provisioningState,HTTPS:enableHttpsTrafficOnly,TLS:minimumTlsVersion,AnonymousBlob:allowBlobPublicAccess,PublicNetwork:publicNetworkAccess,SharedKey:allowSharedKeyAccess}" --output json
~~~

**Required actual state:** `Succeeded`, `true`, `TLS1_2`, `false`, `Disabled`, `false`. Script 2 additionally checks `StorageV2` and `Standard_LRS`.

## 7. Operational decision table

| Situation | Required operator action |
| --- | --- |
| Foundation script fails | Stop. Inspect `az` error; do not run Script 2. |
| Foundry quota error | Stop. Review quota, model/region and capacity. |
| GPT returns no or multiple function calls | Stop. No deployment approved or executed. Review model response. |
| GPT requests different Storage name | Stop. Never override the name validator. |
| Name unavailable | Stop and rerun Script 2 to generate a fresh candidate; don't reuse stale `call_id`. |
| Operator declines approval | Script exits without attempting Storage creation. |
| Azure create succeeds but property verification fails | Treat as **created but noncompliant**. Inspect immediately; no implicit rollback exists. |
| GPT report fails **after** successful Azure deployment | **Do not rerun Script 2** just to get a report: rerunning proposes another chargeable account. Independently inspect the existing account instead. |
| Operator wants to use blob data | Plan Private Endpoint/DNS and Entra blob data RBAC separately; do not enable public access as an ad hoc workaround. |

## 8. Evidence capture and closeout

Capture a change record containing date/time (UTC), operator identifier, target subscription, resource group, Foundry deployment alias, GPT `call_id` if available, approved Storage name, approval decision, CLI exit/provisioning state, property checks and final report. **The current scripts print to console but do not create a durable approval/audit record.** Record evidence in your organization's approved system, redacting credentials.

Close only when actual Azure property verification succeeds. Report all resources and estimated ongoing charges. No automated cleanup is included; deletion requires a **separate explicit destructive-change authorization** after listing every resource in the target group.

## 9. Known gaps / change controls

This SOP applies to the **current lab**. It is not a production runbook, because there is no dedicated least-privilege execution identity, central audit retention, Azure Policy attestation, Private Endpoint, private DNS, data-plane test, standardized IaC rollback, continuous drift monitoring or explicit cost alerts. The Foundry resource's assigned identity does **not** run the CLI. Never describe the tool schema as executable hosted code.

Related: [Foundation walkthrough](01-foundation-walkthrough.md), [GPT walkthrough](02-gpt-storage-walkthrough.md), [Security/operations](03-security-operations.md).
