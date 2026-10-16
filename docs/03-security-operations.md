# Security, operations, limitations and troubleshooting

## POC security properties

The prototype deliberately separates **AI decision/request** from **authorized execution**. GPT can suggest only a storage account name through the defined tool schema; all security switches live outside the model in PowerShell. Human approval is mandatory before `az storage account create`. Azure's actual resource properties are queried after deployment.

However, this **is not production ready**. Using a developer's interactive CLI identity and retrieving a Foundry account key are convenient lab choices, not a recommended production execution boundary.

## Shared responsibility table

| Component | Responsibility |
| --- | --- |
| User/operator | Signs in, chooses Azure subscription, reviews proposal, explicitly approves. |
| Foundry-hosted GPT-5-mini | Interprets instruction, emits structured tool request, explains verified result. |
| PowerShell script | Defines function contract, validates name, enforces policy, prompts approval, executes CLI, verifies resource. |
| Azure CLI with user's identity | Authenticates to Azure management APIs under existing RBAC permissions. |
| Azure Resource Manager / Microsoft.Storage | Provisions Azure resources and provides authoritative resource state. |

## Credentials and repository safety

- Never place secrets in GitHub, including Foundry key1, keys, storage SAS, bearer tokens, saved Azure CLI tokens or personal credentials.
- Script 2 obtains `key1` at runtime and holds it only in memory. Avoid transcript logging or printing `$headers` / `$apiKey`.
- Script 1 saves the non-secret `cloudgenius-ai-config.json` adjacent to the scripts. It includes subscription and resource metadata, and should remain untracked (`.gitignore`).
- Before reusing this repo, change **Script 1 subscription ID** and review your resource naming, quota, regional and organizational requirements.
- For production, replace the CLI identity with a dedicated execution identity (prefer managed identity for Azure-hosted execution), scope RBAC to the allowed resource group, and keep approval evidence and audit logs in your organization’s system.
- A Foundry AIServices system-assigned identity does not automatically grant the local PowerShell executor any Azure permissions.
- Avoid sending user secrets or private identifiers to the model in function-call inputs or outputs.

## Networking and data-plane access

- Storage's `publicNetworkAccess=Disabled` means it cannot be accessed from the public network data endpoint.
- Script 1 creates a *future* private endpoint subnet but does not provision a Private Endpoint, DNS zone/link, hosted execution client or workload network access.
- To use blob data privately, create a Blob private endpoint, connect `privatelink.blob.core.windows.net` DNS to a suitable VNet, test DNS resolution from a VNet-connected client, and grant the required Entra ID Blob data-role permissions.
- Simply creating the subnet **does not validate end-to-end private access**.
- Storage LRS is a cost-conscious POC redundancy choice, not a universally recommended production disaster-recovery configuration.

## Expected charges and repeat runs

- Consumption from Foundry inference/model deployment and provisioned cloud resources may be billable.
- Script 1 is designed to *create missing foundation components and check existing ones*. It is not a general Terraform-style desired-state reconciler.
- Script 2 generates a **new random Storage account name every time**. Each successful approved invocation creates another storage account; repeated runs are not idempotent in the Storage layer.
- Never assume deleting your local files or GitHub repository decommissions Azure resources.

## Troubleshooting

| Symptom | Likely cause | Action |
| --- | --- | --- |
| `az: command not found` | Azure CLI missing or not in PATH | Install CLI; reopen terminal; run `az version`. |
| `Please run az login` | No current Azure CLI session | Run `az login`, then retry. |
| Wrong subscription | Incorrect committed sample subscription ID | Update `$SubscriptionId` in Script 1 to your own; do not point Script 2 at a stale config. |
| `InsufficientQuota` | GPT model/capacity unavailable to this subscription in East US | Request quota or change deployment plan deliberately after verifying availability. |
| `cannot be loaded ... not digitally signed` | Downloaded-file security marker or execution policy | Review source; run `Unblock-File` on trusted downloaded scripts; check organizational policy. |
| Existing Foundry name not found | Local config refers to deleted resource | Check Azure subscription and config; intentionally remove stale local config for a fresh deployment. |
| Storage name unavailable | Global name collision | Re-run Script 2 to generate another candidate. |
| GPT emits no function call | Model chose text response or API request incomplete | Script aborts before any deployment. Check model availability, request quotas, and service response. |
| `APPROVE` not entered exactly | Human approval intentionally failed | No account is created; rerun only if still desired. |
| Storage created but verification fails | Policy mismatch, update or Azure reporting delay | Review the live resource using `az storage account show`; do not tell users it was verified. |
| GPT final report fails | Inference request/network problem after successful Azure deployment | Check Azure resource state independently; don't rerun Script 2 solely to regenerate the report, because it creates another account. |

## Safety for a public educational repository

Document the expected privileges, costs, and limits. Every user should run against **their own** subscription after reviewing scripts. Never claim that GPT autonomously deployed Azure resources without the executor. Never claim the storage account has working private connectivity until a private endpoint and data-plane test have been completed.

## Decommissioning

Resource deletion is destructive. Before deleting `rg-cloudgenius-ai-dev`, inventory it with:

~~~powershell
az resource list --resource-group rg-cloudgenius-ai-dev --output table
~~~

Delete only if the resource group contains **exclusively disposable lab assets**. Azure resource group deletion removes its child resources. Foundry may need separate soft-delete purge for complete removal of recoverable account state. GitHub commit history is independent from Azure cleanup.

## Notes about testing

The two published PowerShell scripts were run successfully in the original project, including a GPT `deploy_storage_account` function call, human approval, Azure Storage creation, complete property verification and GPT final report. A different user's subscription, permission set or quota may prevent success; this repository does not promise it will run unmodified everywhere.
