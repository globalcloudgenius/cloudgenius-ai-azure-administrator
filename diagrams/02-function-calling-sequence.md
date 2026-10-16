# Exact GPT tool-call / approval / Azure verification sequence

This sequence follows the **two published scripts**. A tool *definition* is sent to GPT; `deploy_storage_account` is **not** a deployed Azure Function, hosted plugin, or local PowerShell function body. The local script interprets the model's function call and issues Azure CLI operations.

![CloudGenius five-step GPT / PowerShell / Azure verification flow](assets/02-gpt-approval-verification-flow.svg)

## Reproduced working tool-call structure

```json
{
  "type": "function_call",
  "name": "deploy_storage_account",
  "arguments": "{\"storage_name\":\"cgaistore610655\"}",
  "call_id": "call_<unique-opaque-id>"
}
```

In that structure, `arguments` is a **JSON-encoded string** and `call_id` lets Script 2 correlate the response with the initial request.

## Enforcement is outside GPT

| Control | Location in real implementation |
| --- | --- |
| Model may specify only account name | `$tools` JSON schema |
| Requested name equals preselected candidate and regex | PowerShell validation |
| Name does not already exist and is globally available | Azure CLI lookups |
| Region, SKU, TLS, HTTPS, public access, Shared Key | Hardcoded Script 2 CLI argument list |
| Human change authorization | Local `Read-Host` confirmation |
| Resource successfully created | Azure control plane |
| Security posture passes | Local comparisons of fresh `az storage account show` response |
| GPT report grounded in observed Azure state | `function_call_output` sent to matching `call_id` |

**Important:** If Azure creates a Storage account but a later GPT narrative response fails, the account still exists. There is no built-in rollback. Never assume a generated AI sentence changes cloud state.
