# Exact GPT tool-call / approval / Azure verification sequence

This sequence follows the **two published scripts**. A tool *definition* is sent to GPT; `deploy_storage_account` is **not** a deployed Azure Function, hosted plugin, or local PowerShell function body. The local script interprets the model's function call and issues Azure CLI operations.

```mermaid
sequenceDiagram
  autonumber
  actor Admin as Human administrator
  participant PS as Local PowerShell Script 2
  participant F as Foundry GPT-5-mini Responses API
  participant ARM as Azure CLI / Azure Resource Manager
  Admin->>PS: Run Script 2 after Script 1 succeeded
  PS->>PS: Load cloudgenius-ai-config.json; verify subscription
  PS->>PS: Generate cgaistoreNNNNNN candidate
  PS->>ARM: Get Foundry endpoint and key1 (CLI)
  ARM-->>PS: Endpoint + key held in memory
  PS->>F: POST model + tool schema deploy_storage_account + input
  F-->>PS: function_call(name, arguments.storage_name, call_id)
  PS->>PS: Require exactly one call; validate name matches candidate
  PS->>ARM: Check storage account existence + global naming availability
  ARM-->>PS: No existing account; name available
  PS->>Admin: Display fixed Storage2/Standard_LRS and security policy; ask APPROVE
  alt Administrator types exact APPROVE
    Admin-->>PS: APPROVE
    PS->>ARM: az storage account create with fixed HTTPS/TLS/network/key flags
    ARM-->>PS: Create command completes
    PS->>ARM: az storage account show --output json
    ARM-->>PS: Authoritative properties and provisioning state
    PS->>PS: Compare 8 required security/type/state conditions
    PS->>F: POST previous_response_id + function_call_output(call_id, real result)
    F-->>PS: Final narrative report (may independently fail)
    PS-->>Admin: Verification result; SUCCESS only if all checks passed
  else Approval withheld
    Admin-->>PS: Any value other than APPROVE
    PS-->>Admin: Stop. No create command executed.
  end
```

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
