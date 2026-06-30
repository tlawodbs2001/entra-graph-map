[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Drive')]
    [string]$ScopeType,

    [Parameter(Mandatory)]
    [string]$DriveId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[^\s@]+@[^\s@]+\.[^\s@]+$')]
    [string]$TargetUserPrincipalName,

    [string]$OutputRoot = 'C:\scripts\entra-access-inventory\output',

    [int]$MaxItems = 500
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-MgcJson {
    param([string[]]$Arguments)
    $raw = & mgc @Arguments --output JSON 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($raw | Out-String) }
    $text = ($raw | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text | ConvertFrom-Json -Depth 100
}
function Get-ValueArray($Response) {
    if ($null -eq $Response) { return @() }
    if ($Response.PSObject.Properties.Name -contains 'value') { return @($Response.value) }
    return @($Response)
}

if (-not (Get-Command mgc -ErrorAction SilentlyContinue)) {
    throw 'mgc를 찾을 수 없습니다. Microsoft Graph CLI 설치 및 PATH 등록 후 다시 실행하십시오.'
}

$safe = ($TargetUserPrincipalName -replace '[^a-zA-Z0-9._-]', '_')
$outDir = Join-Path $OutputRoot $safe
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

$errors = [System.Collections.Generic.List[object]]::new()
$items = [System.Collections.Generic.List[object]]::new()

try {
    $rootChildren = Invoke-MgcJson -Arguments @('drives','with-drive-id','--drive-id',$DriveId,'root','children','list','--all','--top',[string]$MaxItems,'--select','id,name,webUrl,folder,file,parentReference,createdDateTime,lastModifiedDateTime')
    $queue = [System.Collections.Generic.Queue[object]]::new()
    foreach ($child in (Get-ValueArray $rootChildren)) { $queue.Enqueue($child) }

    while ($queue.Count -gt 0 -and $items.Count -lt $MaxItems) {
        $item = $queue.Dequeue()
        $permissionResult = $null
        try {
            $permissionResult = Invoke-MgcJson -Arguments @('drives','with-drive-id','--drive-id',$DriveId,'items','with-drive-item-id','--drive-item-id',$item.id,'permissions','list','--all')
        }
        catch {
            $errors.Add([pscustomobject]@{ scope="driveItem.permissions:$($item.id)"; message=$_.Exception.Message; remediation='Files.Read.All 또는 Sites.Read.All 계열 권한과 해당 Drive 접근 권한을 확인하십시오.' })
        }

        $permissions = Get-ValueArray $permissionResult
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

        if ($item.folder -and $items.Count -lt $MaxItems) {
            try {
                $children = Invoke-MgcJson -Arguments @('drives','with-drive-id','--drive-id',$DriveId,'items','with-drive-item-id','--drive-item-id',$item.id,'children','list','--all','--top','200','--select','id,name,webUrl,folder,file,parentReference,createdDateTime,lastModifiedDateTime')
                foreach ($child in (Get-ValueArray $children)) { $queue.Enqueue($child) }
            }
            catch {
                $errors.Add([pscustomobject]@{ scope="driveItem.children:$($item.id)"; message=$_.Exception.Message; remediation='폴더 탐색 권한 또는 API 제한을 확인하십시오.' })
            }
        }
    }
}
catch {
    $errors.Add([pscustomobject]@{ scope='sharepointOneDrive.scopeInventory'; message=$_.Exception.Message; remediation='Drive ID, Graph 권한, mgc 로그인 상태를 확인하십시오.' })
}

$result = [ordered]@{
    schemaVersion = '0.1'
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    target = [ordered]@{ userPrincipalName = $TargetUserPrincipalName }
    collection = [ordered]@{
        scopeType = $ScopeType
        driveId = $DriveId
        maxItems = $MaxItems
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
if ($items.Count -ge $MaxItems) { Write-Warning "MaxItems 한도에 도달했습니다. 결과는 부분 수집일 수 있습니다." }
if ($errors.Count -gt 0) { Write-Warning "일부 항목을 수집하지 못했습니다. JSON의 inventory.errors를 확인하십시오." }
