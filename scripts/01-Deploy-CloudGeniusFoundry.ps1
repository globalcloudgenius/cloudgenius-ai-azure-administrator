#Requires -Version 5.1
<#
.SYNOPSIS
  Recreates the CloudGenius AI Azure Administrator proof-of-concept foundation.
.DESCRIPTION
  Creates or verifies: resource group, VNet/subnet, Microsoft Foundry AIServices account,
  Foundry project, and GPT-5-mini GlobalStandard model deployment. Does NOT create storage.
  Writes a local configuration file for script 02. Existing resource configuration is checked;
  resources are not deleted or overwritten. Azure costs can apply.
.PREREQUISITES
  Azure CLI, az login, sufficient Azure permissions, GPT-5-mini quota in East US.
.EXAMPLE
  .\01-Deploy-CloudGeniusFoundry.ps1
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---- Project settings based on the original working deployment ----
$SubscriptionId = '7f54ad46-7f2f-453e-92dd-69f881e38371'
$ResourceGroup = 'rg-cloudgenius-ai-dev'
$Location = 'eastus'
$VNetName = 'vnet-cloudgenius-ai'
$VNetCidr = '10.50.0.0/16'
$SubnetName = 'snet-ai-private-endpoints'
$SubnetCidr = '10.50.1.0/24'
$ProjectName = 'cloudgenius-ai-project'
$DeploymentName = 'cg-gpt-5-mini'
$ModelName = 'gpt-5-mini'
$ModelVersion = '2025-08-07'
$Capacity = 10  # 10 x 1,000 tokens per minute, subject to quota
$ConfigPath = Join-Path $PSScriptRoot 'cloudgenius-ai-config.json'

function Invoke-AzCli {
    param([Parameter(Mandatory=$true)][string[]]$Arguments)
    $result = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed: az $($Arguments -join ' ')`n$($result -join [Environment]::NewLine)" }
    return ($result | Out-String).Trim()
}
function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }

Write-Host '=== CLOUDGENIUS AI: FOUNDRY FOUNDATION ===' -ForegroundColor Cyan
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI missing. Install Azure CLI and run az login.' }
Invoke-AzCli @('account','set','--subscription',$SubscriptionId) | Out-Null
$CurrentSubscription = Invoke-AzCli @('account','show','--query','id','-o','tsv')
Assert-True ($CurrentSubscription -eq $SubscriptionId) 'Wrong Azure subscription selected.'
Write-Host "Subscription verified: $CurrentSubscription"

# Preserve the Foundry resource name across reruns; use a fresh one after decommissioning.
if (Test-Path $ConfigPath) {
    $saved = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    Assert-True ($saved.subscription_id -eq $SubscriptionId -and $saved.resource_group -eq $ResourceGroup) 'Config points to unexpected subscription/resource group. Move the config first if intentional.'
    $FoundryName = [string]$saved.foundry_name
} else {
    $FoundryName = 'cgfoundry' + (Get-Random -Minimum 100000 -Maximum 999999)
}
Assert-True ($FoundryName -match '^cgfoundry[0-9]{6}$') 'Foundry resource name failed validation.'

# 1. Resource group
if ((Invoke-AzCli @('group','exists','--name',$ResourceGroup)) -eq 'false') {
    Write-Host 'Creating resource group...'
    Invoke-AzCli @('group','create','--name',$ResourceGroup,'--location',$Location,'-o','none') | Out-Null
} else { Write-Host 'Resource group already exists.' }

# 2. Virtual network + subnet
$vnetExists = Invoke-AzCli @('network','vnet','list','--resource-group',$ResourceGroup,'--query',"[?name=='$VNetName'] | length(@)",'-o','tsv')
if ($vnetExists -eq '0') {
    Write-Host 'Creating virtual network...'
    Invoke-AzCli @('network','vnet','create','--resource-group',$ResourceGroup,'--name',$VNetName,'--location',$Location,'--address-prefixes',$VNetCidr,'-o','none') | Out-Null
}
$vnet = Invoke-AzCli @('network','vnet','show','--resource-group',$ResourceGroup,'--name',$VNetName,'-o','json') | ConvertFrom-Json
Assert-True ($vnet.provisioningState -eq 'Succeeded') 'VNet provisioning failed.'
Assert-True ($vnet.addressSpace.addressPrefixes -contains $VNetCidr) 'Existing VNet does not have expected CIDR.'

$subnetExists = Invoke-AzCli @('network','vnet','subnet','list','--resource-group',$ResourceGroup,'--vnet-name',$VNetName,'--query',"[?name=='$SubnetName'] | length(@)",'-o','tsv')
if ($subnetExists -eq '0') {
    Write-Host 'Creating subnet for future Private Endpoints...'
    Invoke-AzCli @('network','vnet','subnet','create','--resource-group',$ResourceGroup,'--vnet-name',$VNetName,'--name',$SubnetName,'--address-prefixes',$SubnetCidr,'-o','none') | Out-Null
}
$subnet = Invoke-AzCli @('network','vnet','subnet','show','--resource-group',$ResourceGroup,'--vnet-name',$VNetName,'--name',$SubnetName,'-o','json') | ConvertFrom-Json
Assert-True ($subnet.provisioningState -eq 'Succeeded' -and $subnet.addressPrefix -eq $SubnetCidr) 'Subnet verification failed.'

# 3. Foundry AI Services account with system-assigned identity / project management.
$foundryCount = Invoke-AzCli @('cognitiveservices','account','list','--resource-group',$ResourceGroup,'--query',"[?name=='$FoundryName'] | length(@)",'-o','tsv')
if ($foundryCount -eq '0') {
    Write-Host "Creating Microsoft Foundry resource: $FoundryName"
    Invoke-AzCli @('cognitiveservices','account','create','--name',$FoundryName,'--resource-group',$ResourceGroup,'--kind','AIServices','--sku','S0','--location',$Location,'--custom-domain',$FoundryName,'--assign-identity','--allow-project-management','true','-o','none') | Out-Null
}
$foundry = Invoke-AzCli @('cognitiveservices','account','show','--name',$FoundryName,'--resource-group',$ResourceGroup,'-o','json') | ConvertFrom-Json
Assert-True ($foundry.kind -eq 'AIServices' -and $foundry.location -eq $Location) 'Foundry account verification failed.'

# 4. Foundry project
$projects = Invoke-AzCli @('cognitiveservices','account','project','list','--name',$FoundryName,'--resource-group',$ResourceGroup,'-o','json') | ConvertFrom-Json
if (-not @($projects | Where-Object { $_.name -eq "$FoundryName/$ProjectName" -or $_.name -eq $ProjectName }).Count) {
    Write-Host 'Creating Foundry project...'
    Invoke-AzCli @('cognitiveservices','account','project','create','--name',$FoundryName,'--resource-group',$ResourceGroup,'--project-name',$ProjectName,'--location',$Location,'-o','none') | Out-Null
}
$projects = Invoke-AzCli @('cognitiveservices','account','project','list','--name',$FoundryName,'--resource-group',$ResourceGroup,'-o','json') | ConvertFrom-Json
Assert-True (@($projects | Where-Object { $_.name -eq "$FoundryName/$ProjectName" -or $_.name -eq $ProjectName }).Count -gt 0) 'Foundry project verification failed.'

# 5. GPT-5-mini (gpt-6.1-sol had no quota in the original subscription).
$deployments = Invoke-AzCli @('cognitiveservices','account','deployment','list','--name',$FoundryName,'--resource-group',$ResourceGroup,'-o','json') | ConvertFrom-Json
if (-not @($deployments | Where-Object { $_.name -eq $DeploymentName }).Count) {
    Write-Host 'Deploying GPT-5-mini GlobalStandard, capacity 10...'
    Invoke-AzCli @('cognitiveservices','account','deployment','create','--name',$FoundryName,'--resource-group',$ResourceGroup,'--deployment-name',$DeploymentName,'--model-name',$ModelName,'--model-version',$ModelVersion,'--model-format','OpenAI','--sku-name','GlobalStandard','--sku-capacity',"$Capacity",'-o','none') | Out-Null
}
$modelDeployment = Invoke-AzCli @('cognitiveservices','account','deployment','show','--name',$FoundryName,'--resource-group',$ResourceGroup,'--deployment-name',$DeploymentName,'-o','json') | ConvertFrom-Json
Assert-True ($modelDeployment.properties.provisioningState -eq 'Succeeded' -and $modelDeployment.properties.model.name -eq $ModelName -and $modelDeployment.properties.model.version -eq $ModelVersion) 'GPT deployment verification failed.'

# 6. Save NON-SECRET configuration. API keys are fetched at runtime by script 02.
@{
    subscription_id=$SubscriptionId; resource_group=$ResourceGroup; location=$Location
    vnet_name=$VNetName; subnet_name=$SubnetName
    foundry_name=$FoundryName; project_name=$ProjectName; deployment_name=$DeploymentName
    model_name=$ModelName; model_version=$ModelVersion
} | ConvertTo-Json -Depth 5 | Set-Content -Path $ConfigPath -Encoding UTF8

Write-Host "`nSUCCESS: Azure/Foundry environment verified." -ForegroundColor Green
Write-Host "Resource group: $ResourceGroup | VNet: $VNetName | Subnet: $SubnetName"
Write-Host "Foundry: $FoundryName | Project: $ProjectName | Model deployment: $DeploymentName"
Write-Host "Configuration saved: $ConfigPath"
Write-Host 'Next: run .\02-GPT-Deploy-SecureStorage.ps1'