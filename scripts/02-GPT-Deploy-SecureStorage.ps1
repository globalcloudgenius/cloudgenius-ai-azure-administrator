#Requires -Version 5.1
<#
.SYNOPSIS
  Ask GPT-5-mini in Microsoft Foundry to request secure Azure Storage deployment.
.DESCRIPTION
  GPT calls the deploy_storage_account tool (name only). PowerShell validates tool arguments,
  requires explicit human approval, creates the resource using fixed security controls,
  independently verifies Azure properties, and returns verified results to the model.
  The model NEVER directly executes Azure CLI. This POC uses a Foundry resource key locally;
  production should use managed identity and least-privilege RBAC.
.EXAMPLE
  .\02-GPT-Deploy-SecureStorage.ps1
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ConfigPath = Join-Path $PSScriptRoot 'cloudgenius-ai-config.json'
if (-not (Test-Path $ConfigPath)) { throw 'Run 01-Deploy-CloudGeniusFoundry.ps1 first (configuration not found).' }
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

function Invoke-AzCli {
    param([Parameter(Mandatory=$true)][string[]]$Arguments)
    $result = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed: az $($Arguments -join ' ')`n$($result -join [Environment]::NewLine)" }
    return ($result | Out-String).Trim()
}
function Get-AIText {
    param($Response)
    @($Response.output | Where-Object { $_.type -eq 'message' } | ForEach-Object { $_.content } | Where-Object { $_.type -eq 'output_text' } | ForEach-Object { $_.text }) -join "`n"
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI is required.' }
Invoke-AzCli @('account','set','--subscription',[string]$cfg.subscription_id) | Out-Null
if ((Invoke-AzCli @('account','show','--query','id','-o','tsv')) -ne [string]$cfg.subscription_id) { throw 'Wrong Azure subscription.' }

# Unique lowercase globally scoped name. Use a fresh name for each invocation.
$StorageName = 'cgaistore' + (Get-Random -Minimum 100000 -Maximum 999999)

# Credentials are held only in memory, never written into the config or report.
$endpoint = Invoke-AzCli @('cognitiveservices','account','show','--name',[string]$cfg.foundry_name,'--resource-group',[string]$cfg.resource_group,'--query','properties.endpoint','-o','tsv')
$apiKey = Invoke-AzCli @('cognitiveservices','account','keys','list','--name',[string]$cfg.foundry_name,'--resource-group',[string]$cfg.resource_group,'--query','key1','-o','tsv')
if ([string]::IsNullOrWhiteSpace($endpoint) -or [string]::IsNullOrWhiteSpace($apiKey)) { throw 'Foundry endpoint/key unavailable.' }
$uri = $endpoint.TrimEnd('/') + '/openai/v1/responses'
$headers = @{ 'api-key'=$apiKey; 'Content-Type'='application/json' }

# Function definition provided to GPT. It is a contract, NOT executable code in Foundry.
$tools = @(@{
    type='function'
    name='deploy_storage_account'
    description='Request deployment of one secure Azure Storage account after human approval. Execution and verification are handled externally.'
    parameters=@{
        type='object'
        properties=@{ storage_name=@{ type='string'; description='Unique lowercase Azure Storage account name (3-24 characters)' } }
        required=@('storage_name')
        additionalProperties=$false
    }
    strict=$true
})

$instructions = 'You are CloudGenius AI Azure Administrator. For a secure storage deployment, call deploy_storage_account exactly once with the requested storage name. The external executor handles approval, validation, security parameters and Azure CLI. Only report success when tool output says verified. Do not request another approval after verified deployment. Never invent rollback, finalization, or lock features.'
$body = @{
    model=[string]$cfg.deployment_name
    reasoning=@{ effort='low' }
    instructions=$instructions
    tools=$tools
    tool_choice='auto'
    input="Request deployment of an Azure Storage account named $StorageName in resource group $($cfg.resource_group), $($cfg.location). Require HTTPS, minimum TLS 1.2, no anonymous blob access, no public network access, no Shared Key access, and human approval before executing. Call the available tool."
    max_output_tokens=2000
} | ConvertTo-Json -Depth 20

Write-Host "=== CLOUDGENIUS AI: GPT STORAGE DEPLOYMENT ===" -ForegroundColor Cyan
Write-Host "Storage request: $StorageName"
$ai = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -ErrorAction Stop
$calls = @($ai.output | Where-Object { $_.type -eq 'function_call' -and $_.name -eq 'deploy_storage_account' })
if ($calls.Count -ne 1) { throw "Expected exactly one GPT function call; received $($calls.Count). AI status: $($ai.status). AI text: $(Get-AIText $ai)" }
$call = $calls[0]
$requestedName = ($call.arguments | ConvertFrom-Json).storage_name
if ($requestedName -cne $StorageName -or $requestedName -notmatch '^[a-z0-9]{3,24}$') { throw 'GPT requested an unexpected or invalid account name. Nothing deployed.' }
Write-Host "GPT called: $($call.name) with storage_name=$requestedName" -ForegroundColor Cyan

# Prevent accidental overwrite or repurposing of any existing account.
$existing = Invoke-AzCli @('storage','account','list','--resource-group',[string]$cfg.resource_group,'--query',"[?name=='$requestedName'] | length(@)",'-o','tsv')
if ($existing -ne '0') { throw 'Storage account already exists in resource group; refusing to modify it.' }
$available = Invoke-AzCli @('storage','account','check-name','--name',$requestedName,'--query','nameAvailable','-o','tsv')
if ($available -ne 'true') { throw "Storage account name $requestedName is unavailable. Run script again to generate a new name." }

Write-Host "`nPROPOSED DEPLOYMENT (fixed executor policy)" -ForegroundColor Yellow
Write-Host "Subscription: $($cfg.subscription_id)"
Write-Host "Resource group: $($cfg.resource_group) | Region: $($cfg.location)"
Write-Host "Storage: $requestedName | SKU: Standard_LRS | Kind: StorageV2"
Write-Host 'HTTPS only: true | TLS: TLS1_2 | Anonymous blobs: false | Public network: Disabled | Shared Key: false'
$approval = Read-Host "Type APPROVE to CREATE storage account $requestedName"
if ($approval -cne 'APPROVE') {
    Write-Host 'Not approved: no resource created.' -ForegroundColor Yellow
    exit 0
}

# Actual Azure deployment. The fixed security controls cannot be changed by GPT arguments.
Write-Host 'Executing Azure CLI deployment...'
Invoke-AzCli @('storage','account','create','--name',$requestedName,'--resource-group',[string]$cfg.resource_group,'--location',[string]$cfg.location,'--sku','Standard_LRS','--kind','StorageV2','--https-only','true','--min-tls-version','TLS1_2','--allow-blob-public-access','false','--public-network-access','Disabled','--allow-shared-key-access','false','-o','none') | Out-Null

# Never trust the CLI create response alone: fetch fresh state and compare all required fields.
$storage = Invoke-AzCli @('storage','account','show','--name',$requestedName,'--resource-group',[string]$cfg.resource_group,'-o','json') | ConvertFrom-Json
$verified = ($storage.provisioningState -eq 'Succeeded' -and
             $storage.enableHttpsTrafficOnly -eq $true -and
             $storage.minimumTlsVersion -eq 'TLS1_2' -and
             $storage.allowBlobPublicAccess -eq $false -and
             $storage.publicNetworkAccess -eq 'Disabled' -and
             $storage.allowSharedKeyAccess -eq $false -and
             $storage.kind -eq 'StorageV2' -and $storage.sku.name -eq 'Standard_LRS')

# Report verification failure to GPT too, without asserting success.
$toolResult = @{
    status=$(if ($verified) { 'verified' } else { 'verification_failed' })
    name=$storage.name; resource_id=$storage.id; provisioning_state=$storage.provisioningState
    https_only=$storage.enableHttpsTrafficOnly; minimum_tls=$storage.minimumTlsVersion
    anonymous_blob_access=$storage.allowBlobPublicAccess; public_network_access=$storage.publicNetworkAccess
    shared_key_access=$storage.allowSharedKeyAccess; kind=$storage.kind; sku=$storage.sku.name
    human_approval='granted_before_execution'
} | ConvertTo-Json -Compress -Depth 5
Write-Host "`n=== AZURE VERIFICATION ===" -ForegroundColor Cyan
$toolResult | ConvertFrom-Json | Format-List

# Return output attached to the specific GPT tool call; no key or token is included.
$finalBody = @{
    model=[string]$cfg.deployment_name
    reasoning=@{ effort='low' }
    previous_response_id=$ai.id
    instructions=$instructions
    input=@(@{ type='function_call_output'; call_id=$call.call_id; output=$toolResult })
    max_output_tokens=2000
} | ConvertTo-Json -Depth 15
try {
    $final = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $finalBody -ErrorAction Stop
    Write-Host "`n=== FOUNDRY GPT REPORT ===" -ForegroundColor Cyan
    $finalText = Get-AIText $final
    if ([string]::IsNullOrWhiteSpace($finalText)) { Write-Warning "GPT generated no final text (status: $($final.status)). Azure verification above remains authoritative." }
    else { Write-Host $finalText }
} catch {
    Write-Warning "Azure operation finished but GPT reporting failed: $($_.Exception.Message)"
}
if (-not $verified) { throw 'Storage was created but security verification FAILED. Inspect and remediate it immediately.' }
Write-Host "`nSUCCESS: Azure Storage $requestedName created and independently verified." -ForegroundColor Green
Write-Host 'NOTE: Public network is disabled; accessing blob data requires private networking + suitable RBAC (not provisioned in this POC).'