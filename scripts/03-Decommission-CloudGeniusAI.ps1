#Requires -Version 5.1
<#
.SYNOPSIS
  Decommissions only the Azure resource group for the CloudGenius AI Azure Administrator POC.
.DESCRIPTION
  Loads the deployment configuration written by Script 1 (or requires explicit arguments).
  Verifies the Azure subscription, inventories the entire resource group, obtains an exact
  human deletion confirmation, deletes the group, verifies absence, and optionally purges
  the specified soft-deleted Foundry AIServices account with a SECOND confirmation.
  This is destructive. It does not remove other resource groups, subscription registrations,
  billing records, or Azure's retained activity logs.
.EXAMPLE
  .\03-Decommission-CloudGeniusAI.ps1
.EXAMPLE
  .\03-Decommission-CloudGeniusAI.ps1 -SubscriptionId 'YOUR-SUBSCRIPTION-ID' -ResourceGroup 'rg-cloudgenius-ai-dev' -Location eastus -FoundryName cgfoundry123456
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$ResourceGroup,
    [string]$Location,
    [string]$FoundryName,
    [switch]$SkipFoundryPurge
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-AzCli {
    param([Parameter(Mandatory=$true)][string[]]$Arguments)
    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed: az $($Arguments -join ' ')`n$($output -join [Environment]::NewLine)"
    }
    return ($output | Out-String).Trim()
}

Write-Host "`n=== CLOUDGENIUS AI: DECOMMISSION ===" -ForegroundColor Yellow
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is not installed or is not on PATH.'
}

# Load deployment-specific identifiers; do not guess the new random Foundry name.
$configPath = Join-Path $PSScriptRoot 'cloudgenius-ai-config.json'
if (Test-Path $configPath) {
    $cfg = Get-Content -Path $configPath -Raw | ConvertFrom-Json
    if ($SubscriptionId -and $SubscriptionId -ne [string]$cfg.subscription_id) { throw 'Explicit SubscriptionId conflicts with saved config.' }
    if ($ResourceGroup -and $ResourceGroup -ne [string]$cfg.resource_group) { throw 'Explicit ResourceGroup conflicts with saved config.' }
    if ($Location -and $Location -ne [string]$cfg.location) { throw 'Explicit Location conflicts with saved config.' }
    if ($FoundryName -and $FoundryName -ne [string]$cfg.foundry_name) { throw 'Explicit FoundryName conflicts with saved config.' }
    $SubscriptionId = [string]$cfg.subscription_id
    $ResourceGroup = [string]$cfg.resource_group
    $Location = [string]$cfg.location
    $FoundryName = [string]$cfg.foundry_name
    Write-Host "Using deployment config: $configPath"
}

if ([string]::IsNullOrWhiteSpace($SubscriptionId) -or
    [string]::IsNullOrWhiteSpace($ResourceGroup) -or
    [string]::IsNullOrWhiteSpace($Location)) {
    throw 'Missing deployment config. Specify -SubscriptionId, -ResourceGroup, and -Location explicitly.'
}
if (-not $SkipFoundryPurge -and [string]::IsNullOrWhiteSpace($FoundryName)) {
    throw 'Specify -FoundryName to check/purge that one account, or add -SkipFoundryPurge.'
}
if ($ResourceGroup -notmatch '^[a-zA-Z0-9_().-]{1,90}$') {
    throw 'Resource group name has unexpected characters.'
}
if ($Location -notmatch '^[a-z0-9]+$') {
    throw 'Unexpected Azure region name.'
}
if ($FoundryName -and $FoundryName -notmatch '^[a-zA-Z0-9-]{2,64}$') {
    throw 'Unexpected Foundry account name.'
}

# Verify the exact subscription BEFORE any deletion is attempted.
Invoke-AzCli @('account','set','--subscription',$SubscriptionId) | Out-Null
$activeId = Invoke-AzCli @('account','show','--query','id','-o','tsv')
if ($activeId -ne $SubscriptionId) { throw 'Active subscription does not match requested subscription.' }
$activeName = Invoke-AzCli @('account','show','--query','name','-o','tsv')
Write-Host "Verified Azure subscription: $activeName ($activeId)"
Write-Host "Target resource group: $ResourceGroup"
Write-Host "Expected region: $Location"
if ($FoundryName) { Write-Host "Foundry to inspect for soft-delete: $FoundryName" }

$exists = Invoke-AzCli @('group','exists','--name',$ResourceGroup)
if ($exists -eq 'true') {
    $group = Invoke-AzCli @('group','show','--name',$ResourceGroup,'-o','json') | ConvertFrom-Json
    if ($group.location -ne $Location) { throw 'Resource group is in an unexpected location. Aborting.' }

    # Azure resource group deletion affects ALL resources, including resources not created by our scripts.
    Write-Host "`nAll resources currently in the target group:" -ForegroundColor Yellow
    $inventory = Invoke-AzCli @('resource','list','--resource-group',$ResourceGroup,'-o','json') | ConvertFrom-Json
    @($inventory) | Select-Object name,type,location | Format-Table -AutoSize
    Write-Warning 'EVERY resource in this group will be deleted, even if it was added later and is unrelated.'
    Write-Warning 'Data deletion can be irreversible. Verify the inventory and any Azure resource locks.'

    $required = "DELETE $ResourceGroup"
    $confirmation = Read-Host "To delete this group, type exactly: $required"
    if ($confirmation -cne $required) { throw 'Deletion was not approved; no deletion command executed.' }

    Write-Host "`nDeleting Azure resource group; waiting for Azure to finish..." -ForegroundColor Yellow
    Invoke-AzCli @('group','delete','--name',$ResourceGroup,'--yes','--only-show-errors') | Out-Null
    $existsAfter = Invoke-AzCli @('group','exists','--name',$ResourceGroup)
    if ($existsAfter -ne 'false') { throw 'Resource group still exists after deletion; inspect Azure resource locks and activity.' }
    Write-Host 'Verified: resource group no longer exists.' -ForegroundColor Green
}
elseif ($exists -eq 'false') {
    Write-Host 'Resource group is already absent; nothing to delete there.'
}
else { throw "Unexpected group exists output: $exists" }

# Foundry AIServices accounts may be soft-deleted after the group's deletion.
# Purge is an OPTIONAL second destructive operation and has a distinct confirmation.
if (-not $SkipFoundryPurge -and $FoundryName) {
    Write-Host "`nChecking recoverable/soft-deleted Foundry account..." -ForegroundColor Yellow
    $found = @()
    # Azure may take a moment to surface the soft-deleted entry after RG deletion.
    for ($attempt = 1; $attempt -le 12; $attempt++) {
        $deletedJson = Invoke-AzCli @('cognitiveservices','account','list-deleted','-o','json')
        $deletedAccounts = @($deletedJson | ConvertFrom-Json)
        $found = @($deletedAccounts | Where-Object {
            $_.name -eq $FoundryName -and
            $_.location -eq $Location -and
            (
                ($_.properties.PSObject.Properties['accountId'] -and $_.properties.accountId -like "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/*") -or
                ($_.id -and $_.id -match [regex]::Escape("/subscriptions/$SubscriptionId/") -and $_.id -match [regex]::Escape("/resourceGroups/$ResourceGroup/"))
            )
        })
        if ($found.Count -gt 0) { break }
        if ($attempt -lt 12) { Start-Sleep -Seconds 5 }
    }

    if ($found.Count -gt 1) {
        throw "Multiple matching soft-deleted Foundry entries found ($($found.Count)); manual inspection needed."
    }
    if ($found.Count -eq 1) {
        Write-Host "Found soft-deleted Foundry: $FoundryName ($Location)"
        $purgeRequired = "PURGE $FoundryName"
        $purgeApproval = Read-Host "To permanently purge it, type exactly: $purgeRequired"
        if ($purgeApproval -cne $purgeRequired) {
            Write-Warning 'Foundry purge was declined. Resource group deletion is already complete.'
            return
        }
        Invoke-AzCli @('cognitiveservices','account','purge','--name',$FoundryName,'--resource-group',$ResourceGroup,'--location',$Location) | Out-Null
        Write-Host 'Foundry purge command succeeded; checking for eventual consistency...'
        for ($attempt = 1; $attempt -le 12; $attempt++) {
            $deletedJson = Invoke-AzCli @('cognitiveservices','account','list-deleted','-o','json')
            $deletedAccounts = @($deletedJson | ConvertFrom-Json)
            $remaining = @($deletedAccounts | Where-Object {
                $_.name -eq $FoundryName -and
                $_.location -eq $Location -and
                (
                    ($_.properties.PSObject.Properties['accountId'] -and $_.properties.accountId -like "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/*") -or
                    ($_.id -and $_.id -match [regex]::Escape("/subscriptions/$SubscriptionId/") -and $_.id -match [regex]::Escape("/resourceGroups/$ResourceGroup/"))
                )
            })
            if ($remaining.Count -eq 0) { break }
            if ($attempt -lt 12) { Start-Sleep -Seconds 5 }
        }
        if ($remaining.Count -gt 0) {
            Write-Warning 'Foundry is still shown as soft-deleted. Purge may be propagating or may need investigation.'
        } else {
            Write-Host 'Verified: matching soft-deleted Foundry entry no longer listed.' -ForegroundColor Green
        }
    }
    else {
        Write-Host 'No confidently matching soft-deleted Foundry account found.'
        Write-Warning 'If Azure has not yet surfaced the deleted account, check Azure Portal again later.'
    }
}
elseif ($SkipFoundryPurge) { Write-Host 'Foundry purge intentionally skipped.' }

$finalExists = Invoke-AzCli @('group','exists','--name',$ResourceGroup)
if ($finalExists -ne 'false') { throw 'FINAL CHECK FAILED: resource group still exists.' }
Write-Host "`nDECOMMISSION COMPLETE: Resource group absence confirmed." -ForegroundColor Green
Write-Host 'Scope: This script does not remove resources in other groups, retained logs, billing history, or unrelated subscription-level configuration.'
