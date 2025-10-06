# Apply Entra→AD group deltas using UPNs from export JSON

# Path to the JSON produced by main.ps1 and staged by the pipeline
$InputPath      = ".\entra_groups.json"

# TODO: set your AD server (or leave empty to use default DC discovery)
$ADServer       = "ad01.contoso.local"

# TODO: restrict changes to groups under this OU (mandatory safety rail)
$AllowedGroupOU = "OU=EntraSync,OU=Groups,DC=contoso,DC=local"

# TODO: map Entra group IDs → AD group distinguished names
# Replace the sample GUIDs and DNs with your own.
$Mappings = @(
  @{ EntraGroupId = "00000000-0000-0000-0000-000000000001"; ADGroupDN = "CN=Entra-Group-1,OU=EntraSync,OU=Groups,DC=contoso,DC=local" }
  @{ EntraGroupId = "00000000-0000-0000-0000-000000000002"; ADGroupDN = "CN=Entra-Group-2,OU=EntraSync,OU=Groups,DC=contoso,DC=local" }
)

# Control flags
$DryRun     = $false       # set $true to see planned changes only
$StopOnFail = $false       # set $true to halt on first error

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

function Fail { param([int]$code,[string]$msg) Write-Error $msg; exit $code }

function Ensure-Prereqs {
  if (-not (Test-Path -LiteralPath $InputPath)) { Fail 1 "Input JSON not found: $InputPath" }
  if ([string]::IsNullOrWhiteSpace($AllowedGroupOU)) { Fail 1 "AllowedGroupOU not set." }
  if (-not $Mappings -or $Mappings.Count -eq 0) { Fail 1 "No mappings configured." }
  if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) { Fail 1 "ActiveDirectory module not found." }
  Import-Module ActiveDirectory -ErrorAction Stop
}

function Assert-GroupInScope {
  param([string]$GroupDN,[string]$AllowedOUDN)
  if ($GroupDN -notlike "*,${AllowedOUDN}") {
    $msg = "Group outside allowed OU: $GroupDN"
    if ($StopOnFail) { Fail 4 $msg } else { throw $msg }
  }
}

function Get-ADGroupState {
  param([string]$GroupDN,[hashtable]$AdParams)
  $g = Get-ADGroup -Identity $GroupDN @AdParams -ErrorAction Stop
  Assert-GroupInScope -GroupDN $g.DistinguishedName -AllowedOUDN $AllowedGroupOU
  $members = Get-ADGroupMember -Identity $g.DistinguishedName -Recursive:$false @AdParams |
             Where-Object { $_.objectClass -eq 'user' } |
             ForEach-Object {
               (Get-ADUser -Identity $_.DistinguishedName -Properties userPrincipalName @AdParams).userPrincipalName
             } |
             Where-Object { $_ } |
             Sort-Object -Unique
  return @{ Group=$g; MembersUPN=$members }
}

function Get-Delta {
  param([string[]]$DesiredUPN,[string[]]$CurrentUPN)
  $toAdd    = $DesiredUPN | Where-Object { $_ -and ($_ -notin $CurrentUPN) } | Sort-Object -Unique
  $toRemove = $CurrentUPN | Where-Object { $_ -and ($_ -notin $DesiredUPN) } | Sort-Object -Unique
  return @{ Add=$toAdd; Remove=$toRemove }
}

function Apply-Delta {
  param($GroupObj,[string[]]$ToAdd,[string[]]$ToRemove,[hashtable]$AdParams,[switch]$DryRun)

  if ($DryRun) {
    if ($ToAdd.Count)    { Write-Host    ("PLAN add: {0}"    -f ($ToAdd -join ', ')) }
    if ($ToRemove.Count) { Write-Warning ("PLAN remove: {0}" -f ($ToRemove -join ', ')) }
    return
  }

  $hadErrors = $false

  foreach ($upn in $ToAdd) {
    try {
      $u = Get-ADUser -LDAPFilter "(userPrincipalName=$upn)" @AdParams -ErrorAction Stop
      Add-ADGroupMember -Identity $GroupObj.Group.DistinguishedName -Members $u.DistinguishedName @AdParams -ErrorAction Stop
      Write-Host ("Added {0}" -f $upn)
    } catch { $hadErrors = $true; Write-Error ("Add failed {0}: {1}" -f $upn, $_.Exception.Message) }
  }

  foreach ($upn in $ToRemove) {
    try {
      $u = Get-ADUser -LDAPFilter "(userPrincipalName=$upn)" @AdParams -ErrorAction Stop
      Remove-ADGroupMember -Identity $GroupObj.Group.DistinguishedName -Members $u.DistinguishedName -Confirm:$false @AdParams -ErrorAction Stop
      Write-Host ("Removed {0}" -f $upn)
    } catch { $hadErrors = $true; Write-Error ("Remove failed {0}: {1}" -f $upn, $_.Exception.Message) }
  }

  if ($hadErrors -and $StopOnFail) { exit 5 }
}

function Sync-OneMapping {
  param([object]$GroupExport,[string]$ADGroupDN,[hashtable]$AdParams)

  $desired = @($GroupExport.Members) | Where-Object { $_ } | Sort-Object -Unique
  $adState = Get-ADGroupState -GroupDN $ADGroupDN -AdParams $AdParams
  $delta   = Get-Delta -DesiredUPN $desired -CurrentUPN $adState.MembersUPN

  Write-Host ("Delta for {0}: Add={1} Remove={2}" -f $GroupExport.EntraGroupName, $delta.Add.Count, $delta.Remove.Count)
  Apply-Delta -GroupObj $adState -ToAdd $delta.Add -ToRemove $delta.Remove -AdParams $AdParams -DryRun:$DryRun
}

function Main {
  try {
    Ensure-Prereqs

    $adParams = @{}
    if ($ADServer) { $adParams.Server = $ADServer }

    $bundle = Get-Content -LiteralPath $InputPath -Raw | ConvertFrom-Json
    if (-not $bundle.Groups) { Fail 3 "No groups in JSON." }

    foreach ($m in $Mappings) {
      $gid = $m.EntraGroupId
      $dn  = $m.ADGroupDN
      $gx  = $bundle.Groups | Where-Object { $_.EntraGroupId -eq $gid }
      if (-not $gx) { Write-Warning "Group export missing for $gid"; if ($StopOnFail){exit 3} else {continue} }

      Sync-OneMapping -GroupExport $gx -ADGroupDN $dn -AdParams $adParams
    }

    Write-Host "Done."
    exit 0
  }
  catch { Write-Error ("Unhandled error: {0}" -f $_.Exception.Message); exit 9 }
}

Main
