# Export Entra ID group members (direct only) to JSON via Microsoft Graph

# These are supplied by the pipeline environment (azure-pipelines.yml)
$TenantId     = $env:TenantId
$ClientId     = $env:ClientId
$ClientSecret = $env:ClientSecret

# Output path inside the repo workspace (published as build artifact)
$OutputPath   = ".\out\entra_groups.json"

# TODO: list the Entra group IDs to export (replace samples)
$GroupIds = @(
  "00000000-0000-0000-0000-000000000001"
  "00000000-0000-0000-0000-000000000002"
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

function Fail { param($code,$msg) Write-Error $msg; exit $code }

function Ensure-Prereqs {
  if ([string]::IsNullOrWhiteSpace($TenantId) -or
      [string]::IsNullOrWhiteSpace($ClientId) -or
      [string]::IsNullOrWhiteSpace($ClientSecret)) { Fail 1 "Missing TenantId/ClientId/ClientSecret." }
  if (-not $GroupIds -or $GroupIds.Count -eq 0) { Fail 1 "No Entra group IDs provided." }
  $dir = Split-Path -Parent $OutputPath
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
}

function Get-GraphToken {
  $body = @{
    client_id     = $ClientId
    client_secret = $ClientSecret
    scope         = "https://graph.microsoft.com/.default"
    grant_type    = "client_credentials"
  }
  $uri = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
  try {
    (Invoke-RestMethod -Method Post -Uri $uri -Body $body -ContentType "application/x-www-form-urlencoded").access_token
  } catch { Fail 2 ("Token request failed: {0}" -f $_.Exception.Message) }
}

function Invoke-Graph {
  param([string]$Method,[string]$Uri,[hashtable]$Headers,[int]$Retry = 3)
  for ($i=0; $i -lt $Retry; $i++) {
    try { return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers }
    catch {
      $status = $_.Exception.Response.StatusCode.Value__
      if ($status -eq 429 -or $status -ge 500) { Start-Sleep -Seconds ([math]::Min(60,[int][math]::Pow(2,$i)*2)); continue }
      throw
    }
  }
  throw "Graph request failed after retries: $Uri"
}

function Get-GroupMeta {
  param([string]$Id,[hashtable]$Headers)
  $uri = "https://graph.microsoft.com/v1.0/groups/$Id`?$select=id,displayName"
  Invoke-Graph -Method Get -Uri $uri -Headers $Headers
}

function Get-DirectUPNs {
  param([string]$GroupId,[hashtable]$Headers)
  $uri = "https://graph.microsoft.com/v1.0/groups/$GroupId/members/microsoft.graph.user`?$select=userPrincipalName&$top=999"
  $upns = @()
  while ($true) {
    $resp = Invoke-Graph -Method Get -Uri $uri -Headers $Headers
    if ($resp.value) { $upns += ($resp.value | ForEach-Object { $_.userPrincipalName }) }
    if (-not $resp.'@odata.nextLink') { break }
    $uri = $resp.'@odata.nextLink'
  }
  $upns | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique
}

function Main {
  try {
    Ensure-Prereqs
    $token   = Get-GraphToken
    $headers = @{ Authorization = "Bearer $token" }

    $bundle = [ordered]@{
      GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
      Groups         = @()
    }

    foreach ($gid in $GroupIds) {
      $id = $gid.Trim()
      if (-not $id) { Fail 3 "Empty group ID." }

      $meta  = Get-GroupMeta -Id $id -Headers $headers
      $upns  = Get-DirectUPNs -GroupId $id -Headers $headers

      $bundle.Groups += [pscustomobject]@{
        EntraGroupId   = $meta.id
        EntraGroupName = $meta.displayName
        MemberCount    = $upns.Count
        Members        = $upns
      }
    }

    ($bundle | ConvertTo-Json -Depth 4) | Set-Content -Path $OutputPath -Encoding UTF8
    exit 0
  }
  catch { Write-Error ("Unhandled error: {0}" -f $_.Exception.Message); exit 9 }
}

Main
