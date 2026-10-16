# Actual deployed Azure topology — CloudGenius AI Azure Administrator

This is a **resource and trust-boundary view of the scripts as written**, **not** a planned production system. Example names `cgfoundry170463` and `cgaistore610655` were confirmed in the October 16, 2026 successful run. New runs generate different names.

```mermaid
flowchart TB
  Admin["Human administrator<br/>Windows PowerShell / VS Code<br/>az login identity"]
  Acl["Azure CLI<br/>ARM management calls"]
  Api["HTTPS Foundry Responses API<br/>/openai/v1/responses"]
  subgraph Sub["Azure subscription (configured in Script 1)"]
    subgraph RG["rg-cloudgenius-ai-dev · eastus"]
      subgraph Network["vnet-cloudgenius-ai · 10.50.0.0/16"]
        Subnet["snet-ai-private-endpoints<br/>10.50.1.0/24<br/>(reserved; no endpoint deployed)"]
      end
      Foundry["Microsoft Foundry AIServices<br/>cgfoundry170463 example<br/>S0 · system-assigned identity"]
      Project["Foundry project<br/>cloudgenius-ai-project"]
      Model["Model deployment cg-gpt-5-mini<br/>gpt-5-mini 2025-08-07<br/>GlobalStandard capacity 10"]
      Storage["Azure Storage StorageV2<br/>cgaistore610655 example<br/>Standard_LRS · HTTPS only<br/>TLS1_2 · no anonymous blob<br/>Public network Disabled<br/>Shared Key Disabled"]
    end
  end
  Admin -->|"local Script 1 & Script 2"| Acl
  Admin -->|"tool request / results, API key in memory"| Api
  Api --> Foundry
  Foundry --> Project
  Foundry --> Model
  Acl -->|"resource management"| RG
  Acl -->|"create + show"| Storage
  Subnet -.->|"No PE or DNS created"| Storage
  classDef boundary fill:#f3f4f6,color:#111827,stroke:#6b7280
  classDef active fill:#e0f2fe,color:#0c4a6e,stroke:#0284c7
  classDef gap fill:#fff7ed,color:#9a3412,stroke:#f97316,stroke-dasharray:5 5
  class Foundry,Project,Model,Storage active
  class Subnet gap
```

## Interpretation
- **Management plane:** The local user's Azure CLI identity creates and queries resources through Azure Resource Manager. The model has **no subscription login**.
- **Inference plane:** Script 2 calls the Foundry resource's HTTPS Responses API using an account key obtained locally at runtime. Foundry hosts GPT-5-mini; the model can return a **function call request**, not execute Azure CLI.
- **Network plane:** A VNet and named subnet exist, but they are **not connected to the Storage account**. The dashed line explicitly indicates missing private endpoint and private DNS; therefore this demo does **not** prove private blob connectivity.
- **Data plane:** No blob upload, download, application access or Entra Blob Data RBAC test occurs.
- **Identity boundary:** The Foundry account has a system-assigned identity, but that identity is not used by the local executor.
- **Scale:** The foundry deployment requested capacity 10 (10,000 TPM) in the example; requests and pricing depend on actual subscription limits.

See the [execution sequence](02-function-calling-sequence.md) for what the AI actually did.
