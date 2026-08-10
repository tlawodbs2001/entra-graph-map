# WORKLOG

## 2026-08-10 - Microsoft PowerShell SDK migration

Status: direct collector migration completed on migration branch; tenant/subscription runtime validation pending.

- Created `agent/migrate-to-graph-powershell-sdk` from `main`.
- Migrated `Invoke-EntraAccessInventory.ps1` from Microsoft Graph CLI to Microsoft Graph PowerShell SDK.
- Replaced Graph authentication and REST calls with `Connect-MgGraph`, `Get-MgContext`, and `Invoke-MgGraphRequest`.
- Migrated optional Azure RBAC collection from Azure CLI to Azure PowerShell (`Get-AzSubscription`, `Set-AzContext`, `Get-AzRoleAssignment`).
- Migrated `Invoke-SharePointOneDriveScopeInventory.ps1` to Graph PowerShell SDK and retained paged traversal.
- Updated access inventory documentation and removed CLI setup guidance.
- Preserved read-only behavior and kept secrets/tokens out of the repository.
- `main` was not modified or merged.

Validation remaining:

- PowerShell parser/runtime validation on PowerShell 7.
- Graph delegated permission/consent validation.
- Azure PowerShell subscription context and RBAC result comparison.
- OneDrive/SharePoint drive traversal result comparison against a known sample.
