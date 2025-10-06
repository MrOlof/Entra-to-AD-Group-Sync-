# Entra→AD Group Sync (Split Azure DevOps Pipeline)

Export Entra ID (Azure AD) group members to JSON on a cloud agent, then apply membership deltas to on-prem Active Directory groups on an isolated/self-hosted agent. No inbound connectivity to your DCs and no internet access required on the AD side.

> **Use case:**  
> Designed for organizations using **Entra Cloud Sync** where **Group Writeback** isn't working reliably.
> Ideal for environments that leverage **RBAC** (e.g., Azure Files) but still rely on **on-prem AD** for access enforcement — allowing those groups to be governed directly from Entra ID.

### Why not rely on Group Writeback for NTFS-controlled groups — an example of Cloud Sync writeback unreliability

One major operational risk with Entra Cloud Sync’s Group Writeback is **group recreation**.  
If the Cloud Sync agent or connection is disrupted, the service can recreate groups with a new random suffix and SID.  
This breaks any NTFS or RBAC permissions tied to the old SID, leading to orphaned ACLs on file shares.

This automation avoids that by **never recreating groups in AD** — it only updates membership of existing AD groups mapped to Entra IDs.  
The AD object, including its SID and ACL references, remains stable, making it safe for environments where those groups are used for **NTFS permissions or on-prem RBAC (e.g., Azure Files, SMB shares, AVD, etc.)**.


## What this does

- **Stage 1 (cloud agent)**: Uses a service principal + Graph API to export direct user UPNs for specific Entra groups to `out/entra_groups.json`. Publishes it as a build artifact.
- **Stage 2 (on-prem agent)**: Downloads the artifact and reconciles configured AD group memberships under a **restricted OU** using Windows PowerShell + RSAT ActiveDirectory.

## Why split stages

- Keeps Graph calls and secrets out of the isolated network.
- Avoids opening the DC network to the internet.
- Provides a durable artifact you can audit and re-apply.

## Repo contents

- `azure-pipelines.yml` — the split pipeline definition.
- `main.ps1` — exports Entra groups to JSON (Stage 1).
- `admembership.ps1` — applies deltas to AD groups (Stage 2).

## Prerequisites

**Entra / Graph**
- An App Registration (service principal) with **Application** permissions:
  - `Group.Read.All` (minimum for reading group members).  
- Admin consent granted.
- Client credentials (Client ID/Secret, Tenant ID).

**Azure DevOps**
- A project with a pipeline using this repo.
- Pipeline variables:
  - `ENTRA_TENANT_ID` — your tenant ID (GUID).
  - `ENTRA_CLIENT_ID` — the app registration’s client ID (GUID).
  - `ENTRA_CLIENT_SECRET` — the client secret (**mark as secret**).
- A self-hosted **on-prem agent pool** (e.g., `OnPremAgent`) that can reach your DCs.

**On-prem / AD**
- Windows PowerShell (not PowerShell 7) on the on-prem agent.
- RSAT **ActiveDirectory** module installed.
- The on-prem agent identity with rights to:
  - Read users and groups.
  - Add/Remove members of the target groups in the allowed OU.

## Setup
<img width="811" height="657" alt="image" src="https://github.com/user-attachments/assets/23a0aa61-d6dc-4330-845a-b50ca52e839d" />


1. **Edit `main.ps1`**
   - Set the `@($GroupIds)` array to the Entra group IDs you want to export.

2. **Edit `admembership.ps1`**
   - Set `$ADServer` (or leave empty for auto DC discovery).
   - Set `$AllowedGroupOU` to the OU where **target AD groups** live.
   - Populate `$Mappings` with **Entra group ID → AD group DN** pairs.
   - Optional: set `$DryRun = $true` for a safe plan-only run.

3. **Edit `azure-pipelines.yml`**
   - Replace the on-prem agent pool name (`OnPremAgent`) if needed.

4. **Create pipeline variables**
   - `ENTRA_TENANT_ID`, `ENTRA_CLIENT_ID`, `ENTRA_CLIENT_SECRET` (secret).

5. **Run the pipeline**
   - Stage 1 publishes `EntraExport` artifact.
   - Stage 2 downloads it and applies deltas on the on-prem agent.

## JSON schema produced by Stage 1

```json
{
  "GeneratedAtUtc": "2025-01-01T12:34:56.789Z",
  "Groups": [
    {
      "EntraGroupId": "00000000-0000-0000-0000-000000000001",
      "EntraGroupName": "Sample Group",
      "MemberCount": 3,
      "Members": [
        "alice@contoso.com",
        "bob@contoso.com",
        "carol@contoso.com"
      ]
    }
  ]
}
