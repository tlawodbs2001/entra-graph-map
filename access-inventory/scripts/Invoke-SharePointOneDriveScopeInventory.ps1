[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Drive')]
    [string]$ScopeType,
    [Parameter(Mandatory)][string]$DriveId,
    [Parameter(Mandatory)]
    [ValidatePattern('^[^\s@]+@[^\s@]+\.[^\s@]+$')]
    [string]$TargetUserPrincipalName,
    [string]$OutputRoot = 'C:\scripts\entra-access-inventory\output',
    [ValidateRange(1, 100000)][int]$MaxItems = 500
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Assert-GraphSdkAvailable {
    $required = @('Connect-MgGraph', 'Get-MgContext', 'Invoke-MgGraphRequest')
    $missing = @($required | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
    if ($missing.Count -gt 0) {
        try { Import-Module Microsoft.Graph.Authentication -ErrorAction Stop } catch {}
        $missing = @($required | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
    }
    if ($missing.Count -gt 0) {
        throw "Microsoft Graph PowerShell SDK가 필요합니다. 누락 명령: $($missing -join ', '). 설치 예: Install-Module Microsoft.Graph -Scope CurrentUser"
    }
}

function Ensure-GraphConnection {
    param([Parameter(Mandatory)][string[]]$Scopes)

    Assert-GraphSdkAvailable
    $ctx = Get-MgContext -ErrorAction SilentlyContinue
    $currentScopes = if ($ctx) { @($ctx.Scopes) } else { @() }
    $missingScopes = @($Scopes | Where-Object { $currentScopes -notcontains $_ })
    if (-not $ctx -or -not $ctx.Account -or $missingScopes.Count -gt 0) {
        if ($ctx) { try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch {} }
        Connect-MgGraph -Scopes $Scopes -UseDeviceCode -ContextScope Process -NoWelcome | Out-Null
    }
}

function Get-GraphPropertyValue {
    param([AllowNull()]$Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) {
            if ([string]$key -ieq $Name) { return $Object[$key] }
        }
        return $null
    }
    $property = $Object.PSObject.Properties | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
    if ($property) { return $property.Value }
    return $null
}

function Get-GraphCollection {
    param([Parameter(Mandatory)][string]$Uri)

    $result = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    while (-not [string]::IsNullOrWhiteSpace([string]$next)) {
        $response = Invoke-MgGraphRequest -Method GET -Uri $next -ErrorAction Stop
        foreach ($entry in @(Get-GraphPropertyValue -Object $response -Name 'value')) { $result.Add($entry) }
        $next = [string](Get-GraphPropertyValue -Object $response -Name '@odata.nextLink')
    }
    return @($result)
}

# Arbitrary drive inventory requires tenant-wide file read capability in the intended admin scenario.
# Sites.Read.All is not additionally requested because Files.Read.All is sufficient for these DriveItem calls.
Ensure-GraphConnection -Scopes @('Files.Read.All')

$safe = ($TargetUserPrincipalName -replace '[^a-zA-Z0-9._-]', '_')
$outDir = Join-Path $OutputRoot $safe
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

$errors = [System.Collections.Generic.List[object]]::new()
$items = [System.Collections.Generic.List[object]]::new()
$processedDriveItems = 0
$pageTop = [Math]::Min(999, [Math]::Max(1, $MaxItems))
$select = 'id,name,webUrl,folder,file,parentReference,createdDateTime,lastModifiedDateTime'

try {
    $rootChildren = Get-GraphCollection -Uri "https://graph.microsoft.com/v1.0/drives/$DriveId/root/children?`$top=$pageTop&`$select=$select"
    $queue = [System.Collections.Generic.Queue[object]]::new()
    foreach ($child in $rootChildren) { $queue.Enqueue($child) }

    while ($queue.Count -gt 0 -and $processedDriveItems -lt $MaxItems) {
        $item = $queue.Dequeue()
        $processedDriveItems++

        $permissions = @()
        try {
            $permissions = Get-GraphCollection -Uri "https://graph.microsoft.com/v1.0/drives/$DriveId/items/$($item.id)/permissions?`$top=999"
        }
        catch {
            $errors.Add([pscustomobject]@{
                scope = "driveItem.permissions:$($item.id)"
                message = $_.Exception.Message
                remediation = 'Files.Read.All 권한과 해당 Drive 접근 가능 여부를 확인하십시오.'
            })
        }

        foreach ($permission in $permissions) {
            $roles = @($permission.roles) -join ','
            $grantees = @()
            if ($permission.grantedToV2?.user?.displayName) { $grantees += "User:$($permission.grantedToV2.user.displayName)" }
            if ($permission.grantedToV2?.siteUser?.displayName) { $grantees += "SiteUser:$($permission.grantedToV2.siteUser.displayName)" }
            foreach ($g in @($permission.grantedToIdentitiesV2)) {
                if ($g.user?.displayName) { $grantees += "User:$($g.user.displayName)" }
                if ($g.group?.displayName) { $grantees += "Group:$($g.group.displayName)" }
                if ($g.siteGroup?.displayName) { $grantees += "SiteGroup:$($g.siteGroup.displayName)" }
            }
            if ($permission.link?.scope) { $grantees += "Link:$($permission.link.scope)" }

            $items.Add([pscustomobject]@{
                driveId = $DriveId
                itemId = $item.id
                itemName = $item.name
                itemType = if ($item.folder) { 'Folder' } elseif ($item.file) { 'File' } else { 'Other' }
                webUrl = $item.webUrl
                roles = $roles
                inheritance = if ($permission.inheritedFrom) { 'Inherited' } else { 'DirectOrUnknown' }
                grantSource = ($grantees -join '; ')
                permissionId = $permission.id
                createdDateTime = $item.createdDateTime
                lastModifiedDateTime = $item.lastModifiedDateTime
            })
        }

        if ($item.folder -and $processedDriveItems -lt $MaxItems) {
            try {
                $children = Get-GraphCollection -Uri "https://graph.microsoft.com/v1.0/drives/$DriveId/items/$($item.id)/children?`$top=200&`$select=$select"
                foreach ($child in $children) { $queue.Enqueue($child) }
            }
            catch {
                $errors.Add([pscustomobject]@{
                    scope = "driveItem.children:$($item.id)"
                    message = $_.Exception.Message
                    remediation = '폴더 탐색 권한, Graph 응답 또는 API 제한을 확인하십시오.'
                })
            }
        }
    }
}
catch {
    $errors.Add([pscustomobject]@{
        scope = 'sharepointOneDrive.scopeInventory'
        message = $_.Exception.Message
        remediation = 'Drive ID, Graph PowerShell 로그인 상태, Files.Read.All 권한을 확인하십시오.'
    })
}

$result = [ordered]@{
    schemaVersion = '0.2'
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    target = [ordered]@{ userPrincipalName = $TargetUserPrincipalName }
    collection = [ordered]@{
        tool = 'Microsoft Graph PowerShell SDK'
        scopeType = $ScopeType
        driveId = $DriveId
        maxItems = $MaxItems
        processedDriveItems = $processedDriveItems
        limitation = '지정 Drive 범위에서 탐지된 권한입니다. 대상 사용자가 접근 가능한 테넌트 전체 파일의 완전한 역추적 결과가 아닙니다.'
    }
    inventory = [ordered]@{
        sharePointOneDrive = [ordered]@{
            collectionScope = "Drive:$DriveId / maxItems:$MaxItems"
            permissionFindings = @($items)
        }
        errors = @($errors)
    }
}

$jsonPath = Join-Path $outDir 'sharepoint-onedrive-scope-inventory.json'
$csvPath = Join-Path $outDir 'sharepoint-onedrive-scope-inventory.csv'
$result | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $jsonPath -Encoding utf8
$items | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8BOM

Write-Host "완료: $jsonPath" -ForegroundColor Green
Write-Host "요약: $csvPath" -ForegroundColor Green
if ($processedDriveItems -ge $MaxItems) { Write-Warning "MaxItems 한도에 도달했습니다. 결과는 부분 수집일 수 있습니다." }
if ($errors.Count -gt 0) { Write-Warning "일부 항목을 수집하지 못했습니다. JSON의 inventory.errors를 확인하십시오." }
