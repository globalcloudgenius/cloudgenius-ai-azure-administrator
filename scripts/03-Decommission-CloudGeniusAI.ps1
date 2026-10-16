#Requires -Version 5.1
<#
.SYNOPSIS
  Decommissions the CloudGenius AI demo resource group after explicit approval.
.DESCRIPTION
  Works with or without the locally generated config. Enumerates all RG resources,
  confirms deletion, checks group absence, and separately authorizes Foundry purge.
  WARNING: ALL resources in the RG are deleted, including unrelated resources.
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
function Invoke-Az {
 param([string[]]$Arguments)
 $result = & az @Arguments 2>&1
 if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed: $($result | Out-String)" }
 return ($result | Out-String).Trim()
}
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI missing. Install it and run az login.' }
$config = Join-Path $PSScriptRoot 'cloudgenius-ai-config.json'
if (Test-Path $config) {
 $cfg = Get-Content $config -Raw | ConvertFrom-Json
 if ($SubscriptionId -and $SubscriptionId -ne $cfg.subscription_id) { throw 'Subscription conflicts with config.' }
 if ($ResourceGroup -and $ResourceGroup -ne $cfg.resource_group) { throw 'Resource group conflicts with config.' }
 if ($FoundryName -and $FoundryName -ne $cfg.foundry_name) { throw 'Foundry name conflicts with config.' }
 $SubscriptionId=[string]$cfg.subscription_id
 $ResourceGroup=[string]$cfg.resource_group
 $Location=[string]$cfg.location
 $FoundryName=[string]$cfg.foundry_name
 Write-Host "Loaded config: $config"
}
if (-not $SubscriptionId) { $SubscriptionId='7f54ad46-7f2f-453e-92dd-69f881e38371' }
if (-not $ResourceGroup) { $ResourceGroup='rg-cloudgenius-ai-dev' }
if (-not $Location) { $Location='eastus' }
if ($ResourceGroup -notmatch '^[a-zA-Z0-9_().-]{1,90}$') { throw 'Invalid resource group.' }
if ($Location -notmatch '^[a-z0-9]+$') { throw 'Invalid location.' }
Write-Host 'CLOUDGENIUS AI DECOMMISSION' -ForegroundColor Yellow
Invoke-Az @('account','set','--subscription',$SubscriptionId) | Out-Null
if ((Invoke-Az @('account','show','--query','id','-o','tsv')) -ne $SubscriptionId) { throw 'Wrong subscription.' }
Write-Host "Subscription: $SubscriptionId | RG: $ResourceGroup | Location: $Location"
$exists=Invoke-Az @('group','exists','--name',$ResourceGroup)
if ($exists -eq 'true') {
 $rg=Invoke-Az @('group','show','--name',$ResourceGroup,'-o','json') | ConvertFrom-Json
 if ($rg.location -ne $Location) { throw 'Region mismatch. Stop.' }
 if (-not $FoundryName -and -not $SkipFoundryPurge) {
  $accounts=ConvertFrom-Json -InputObject (Invoke-Az @('cognitiveservices','account','list','--resource-group',$ResourceGroup,'-o','json'))
  $matches=@($accounts | Where-Object { $_.kind -eq 'AIServices' -and $_.name -match '^cgfoundry[0-9]{6}$' })
  if ($matches.Count -eq 1) { $FoundryName=[string]$matches[0].name; Write-Host "Foundry discovered: $FoundryName" }
  elseif ($matches.Count -gt 1) { throw 'Multiple Foundry accounts. Specify -FoundryName explicitly.' }
  else { Write-Warning 'No Foundry candidate. Optional purge skipped.'; $SkipFoundryPurge=$true }
 }
 Write-Host 'EVERY RESOURCE BELOW WILL BE DELETED:' -ForegroundColor Yellow
 $inventory=ConvertFrom-Json -InputObject (Invoke-Az @('resource','list','--resource-group',$ResourceGroup,'-o','json'))
 $inventory | Select-Object name,type,location | Format-Table -AutoSize
 Write-Warning 'Deleting this group deletes ALL resources, including unrelated ones added later.'
 $confirm="DELETE $ResourceGroup"
 if ((Read-Host "Type exactly $confirm to proceed") -cne $confirm) { throw 'Deletion cancelled.' }
 Invoke-Az @('group','delete','--name',$ResourceGroup,'--yes') | Out-Null
 if ((Invoke-Az @('group','exists','--name',$ResourceGroup)) -ne 'false') { throw 'RG deletion could not be verified.' }
 Write-Host 'Group deletion verified.' -ForegroundColor Green
} elseif ($exists -eq 'false') {
 Write-Host 'Resource group already absent.'
 if (-not $FoundryName) { $SkipFoundryPurge=$true; Write-Warning 'No Foundry name available for purge. Pass -FoundryName if required.' }
} else { throw 'Unable to determine whether resource group exists.' }
if (-not $SkipFoundryPurge -and $FoundryName) {
 if ($FoundryName -notmatch '^[a-zA-Z0-9-]{2,64}$') { throw 'Invalid Foundry name.' }
 $matching=@()
 for ($attempt=1;$attempt -le 12;$attempt++) {
  $all=ConvertFrom-Json -InputObject (Invoke-Az @('cognitiveservices','account','list-deleted','-o','json'))
  $matching=@($all | Where-Object {
   $id=[string]$_.id
   $original=''
   if ($_.properties -and $_.properties.PSObject.Properties['accountId']) { $original=[string]$_.properties.accountId }
   $_.name -eq $FoundryName -and $_.location -eq $Location -and
   (($original -like "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/*") -or
    ($id -like "*/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/*"))
  })
  if ($matching.Count -gt 0) { break }
  if ($attempt -lt 12) { Start-Sleep -Seconds 5 }
 }
 if ($matching.Count -gt 1) { throw 'Ambiguous soft-deleted Foundry accounts. Stop.' }
 if ($matching.Count -eq 1) {
  $confirm="PURGE $FoundryName"
  if ((Read-Host "Type exactly $confirm to permanently purge Foundry") -cne $confirm) {
   Write-Warning 'RG deleted; Foundry purge declined.'
   return
  }
  Invoke-Az @('cognitiveservices','account','purge','--name',$FoundryName,'--resource-group',$ResourceGroup,'--location',$Location) | Out-Null
  Write-Host 'Foundry purge command succeeded. Check the soft-deleted account list for propagation.' -ForegroundColor Green
 } else { Write-Warning 'Matching soft-deleted Foundry not found yet. Check Azure again later.' }
}
if ((Invoke-Az @('group','exists','--name',$ResourceGroup)) -ne 'false') { throw 'Final group verification failed.' }
Write-Host 'COMPLETE: resource group absent. Other groups and retained billing logs not affected.' -ForegroundColor Green
