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

function Get-GraphPropertyResult {
    param([AllowNull()]$Object,[Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return [pscustomobject]@{ Exists=$false; Value=$null } }
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) {
            if ([string]$key -ieq $Name) { return [pscustomobject]@{ Exists=$true; Value=$Object[$key] } }
        }
        return [pscustomobject]@{ Exists=$false; Value=$null }
    }
    $property = $Object.PSObject.Properties | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
    if ($property) { return [pscustomobject]@{ Exists=$true; Value=$property.Value } }
    return [pscustomobject]@{ Exists=$false; Value=$null }
}

function Get-GraphPropertyValue {
    param([AllowNull()]$Object,[Parameter(Mandatory)][string]$Name,[AllowNull()]$Default=$null)
    $result = Get-GraphPropertyResult -Object $Object -Name $Name
    if ($result.Exists) { return $result.Value }
    return $Default
}

function Ensure-GraphConnection {
    param([Parameter(Mandatory)][string[]]$Scopes)

    Assert-GraphSdkAvailable
    $ctx = Get-MgContext -ErrorAction SilentlyContinue
    $currentScopes = if ($ctx) { @((Get-GraphPropertyValue -Object $ctx -Name 'Scopes')) } else { @() }
    $account = Get-GraphPropertyValue -Object $ctx -Name 'Account'
    $missingScopes = @($Scopes | Where-Object { $currentScopes -notcontains $_ })
    if (-not $ctx -or -not $account -or $missingScopes.Count -gt 0) {
        if ($ctx) { try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch {} }
        Connect-MgGraph -Scopes $Scopes -UseDeviceCode -ContextScope Process -NoWelcome | Out-Null
    }
}

function Get-GraphErrorInfo {
    param([Parameter(Mandatory)]$ErrorRecord)

    $statusCode = $null
    $retryAfter = $null
    $errorCode = $null
    $exception = Get-GraphPropertyValue -Object $ErrorRecord -Name 'Exception'
    $message = [string](Get-GraphPropertyValue -Object $exception -Name 'Message' -Default 'Unknown Graph error')

    try {
        $response = Get-GraphPropertyValue -Object $exception -Name 'Response'
        $status = Get-GraphPropertyValue -Object $response -Name 'StatusCode'
        if ($null -eq $status) { $status = Get-GraphPropertyValue -Object $exception -Name 'ResponseStatusCode' }
        if ($null -ne $status) { $statusCode = [int]$status }

        $headers = Get-GraphPropertyValue -Object $response -Name 'Headers'
        if ($null -eq $headers) { $headers = Get-GraphPropertyValue -Object $exception -Name 'ResponseHeaders' }
        if ($headers -and ($headers.PSObject.Methods.Name -contains 'TryGetValues')) {
            [System.Collections.Generic.IEnumerable[string]]$values = $null
            if ($headers.TryGetValues('Retry-After',[ref]$values)) {
                [int]$parsed = 0
                $first = @($values) | Select-Object -First 1
                if ($first -and [int]::TryParse([string]$first,[ref]$parsed)) { $retryAfter = $parsed }
            }
        }
        elseif ($headers -is [System.Collections.IDictionary]) {
            [int]$parsed = 0
            $value = Get-GraphPropertyValue -Object $headers -Name 'Retry-After'
            if ($value -and [int]::TryParse([string]$value,[ref]$parsed)) { $retryAfter = $parsed }
        }
    } catch {}

    if ($null -eq $statusCode) {
        if ($message -match '\b(401|403|404|408|409|429|500|502|503|504)\b') { $statusCode = [int]$Matches[1] }
        elseif ($message -match 'TooManyRequests|Too Many Requests|throttl') { $statusCode = 429 }
        elseif ($message -match 'Authorization_RequestDenied|Insufficient privileges|Forbidden') { $statusCode = 403 }
        elseif ($message -match 'Unauthorized|invalid.*token|expired.*token') { $statusCode = 401 }
    }

    try {
        $details = Get-GraphPropertyValue -Object $ErrorRecord -Name 'ErrorDetails'
        $raw = Get-GraphPropertyValue -Object $details -Name 'Message'
        if (-not [string]::IsNullOrWhiteSpace([string]$raw)) {
            $parsed = ([string]$raw | ConvertFrom-Json -ErrorAction Stop)
            $inner = Get-GraphPropertyValue -Object $parsed -Name 'error'
            $code = Get-GraphPropertyValue -Object $inner -Name 'code'
            $graphMessage = Get-GraphPropertyValue -Object $inner -Name 'message'
            if ($code) { $errorCode = [string]$code }
            if ($graphMessage) { $message = [string]$graphMessage }
        }
    } catch {}

    return [pscustomobject]@{ StatusCode=$statusCode; RetryAfter=$retryAfter; ErrorCode=$errorCode; Message=$message }
}

function Invoke-GraphGetWithRetry {
    param([Parameter(Mandatory)][string]$Uri,[int]$MaxAttempts=5)

    if ($MaxAttempts -lt 1) { throw 'MaxAttempts는 1 이상이어야 합니다.' }
    for ($attempt=1; $attempt -le $MaxAttempts; $attempt++) {
        try { return Invoke-MgGraphRequest -Method GET -Uri $Uri -ErrorAction Stop }
        catch {
            $info = Get-GraphErrorInfo -ErrorRecord $_
            $transientText = $info.Message -match 'timeout|temporar|connection.*reset|connection.*closed'
            $retryable = ($info.StatusCode -eq 429) -or ($info.StatusCode -in @(408,500,502,503,504)) -or ($null -eq $info.StatusCode -and $transientText)
            if (-not $retryable -or $attempt -ge $MaxAttempts) { throw }
            $delay = if ($info.RetryAfter -and $info.RetryAfter -gt 0) { [Math]::Min([int]$info.RetryAfter,120) }
                else { [int][Math]::Min([Math]::Pow(2,$attempt),30) }
            Start-Sleep -Seconds $delay
        }
    }
}

function Get-GraphCollection {
    param([Parameter(Mandatory)][string]$Uri,[int]$MaxPages=10000)

    if ($MaxPages -lt 1) { throw 'MaxPages는 1 이상이어야 합니다.' }
    $result = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    $page = 0
    $seenLinks = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    while (-not [string]::IsNullOrWhiteSpace([string]$next)) {
        if ($page -ge $MaxPages) { throw "MaxPages($MaxPages)를 초과했습니다. URI=$next" }
        $page++
        if (-not $seenLinks.Add([string]$next)) { throw "동일한 @odata.nextLink가 반복되었습니다. page=$page URI=$next" }

        $response = Invoke-GraphGetWithRetry -Uri $next
        if ($null -eq $response) { throw "Graph 응답이 null입니다. page=$page URI=$next" }
        $valueResult = Get-GraphPropertyResult -Object $response -Name 'value'
        if (-not $valueResult.Exists) { throw "Collection 응답에 value 배열이 없습니다. page=$page type=$($response.GetType().FullName) URI=$next" }

        foreach ($entry in @($valueResult.Value)) { if ($null -ne $entry) { $result.Add($entry) } }
        $next = [string](Get-GraphPropertyValue -Object $response -Name '@odata.nextLink')
    }
    return @($result)
}

function Add-InventoryError {
    param(
        [Parameter(Mandatory)][System.Collections.Generic.List[object]]$Errors,
        [Parameter(Mandatory)][string]$Scope,
        [string]$Uri,
        [Parameter(Mandatory)][string]$Message,
        [string]$Remediation,
        [Nullable[int]]$StatusCode,
        [string]$ErrorCode
    )

    $Errors.Add([pscustomobject]@{
        scope = $Scope
        uri = $Uri
        statusCode = $StatusCode
        errorCode = $ErrorCode
        message = $Message
        remediation = $Remediation
    })
}

function Export-PermissionCsv {
    param([Parameter(Mandatory)][object[]]$Rows,[Parameter(Mandatory)][string]$Path)

    $columns = @('driveId','itemId','itemName','itemType','webUrl','roles','inheritance','grantSource','permissionId','createdDateTime','lastModifiedDateTime')
    if (@($Rows).Count -gt 0) {
        @($Rows) | Select-Object -Property $columns | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding utf8BOM
        return
    }

    $header = ($columns | ForEach-Object { '"' + $_ + '"' }) -join ','
    Set-Content -LiteralPath $Path -Value $header -Encoding utf8
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
$duplicateDriveItemsSkipped = 0
$seenDriveItems = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$pageTop = [Math]::Min(999,[Math]::Max(1,$MaxItems))
$select = 'id,name,webUrl,folder,file,parentReference,createdDateTime,lastModifiedDateTime'

try {
    $rootUri = "https://graph.microsoft.com/v1.0/drives/$DriveId/root/children?`$top=$pageTop&`$select=$select"
    $rootChildren = Get-GraphCollection -Uri $rootUri
    $queue = [System.Collections.Generic.Queue[object]]::new()
    foreach ($child in $rootChildren) { $queue.Enqueue($child) }

    while ($queue.Count -gt 0 -and $processedDriveItems -lt $MaxItems) {
        $item = $queue.Dequeue()
        $itemId = [string](Get-GraphPropertyValue -Object $item -Name 'id')
        if ([string]::IsNullOrWhiteSpace($itemId)) {
            Add-InventoryError -Errors $errors -Scope 'driveItem' -Message 'DriveItem id가 없어 항목을 건너뜁니다.' -ErrorCode 'MissingDriveItemId' -Remediation 'Graph 응답의 id 필드를 확인하십시오.'
            continue
        }
        if (-not $seenDriveItems.Add($itemId)) {
            $duplicateDriveItemsSkipped++
            continue
        }

        $processedDriveItems++
        $permissions = @()
        $permissionsUri = "https://graph.microsoft.com/v1.0/drives/$DriveId/items/$itemId/permissions?`$top=999"
        try { $permissions = @(Get-GraphCollection -Uri $permissionsUri) }
        catch {
            $info = Get-GraphErrorInfo -ErrorRecord $_
            Add-InventoryError -Errors $errors -Scope "driveItem.permissions:$itemId" -Uri $permissionsUri -Message $info.Message -StatusCode $info.StatusCode -ErrorCode $info.ErrorCode -Remediation 'Files.Read.All 권한과 해당 Drive 접근 가능 여부를 확인하십시오.'
        }

        $itemFolder = Get-GraphPropertyValue -Object $item -Name 'folder'
        $itemFile = Get-GraphPropertyValue -Object $item -Name 'file'
        foreach ($permission in $permissions) {
            $roles = @((Get-GraphPropertyValue -Object $permission -Name 'roles')) -join ','
            $grantees = [System.Collections.Generic.List[string]]::new()

            $grantedToV2 = Get-GraphPropertyValue -Object $permission -Name 'grantedToV2'
            $grantedUser = Get-GraphPropertyValue -Object $grantedToV2 -Name 'user'
            $grantedSiteUser = Get-GraphPropertyValue -Object $grantedToV2 -Name 'siteUser'
            $display = Get-GraphPropertyValue -Object $grantedUser -Name 'displayName'
            if ($display) { $grantees.Add("User:$display") }
            $display = Get-GraphPropertyValue -Object $grantedSiteUser -Name 'displayName'
            if ($display) { $grantees.Add("SiteUser:$display") }

            foreach ($identity in @((Get-GraphPropertyValue -Object $permission -Name 'grantedToIdentitiesV2'))) {
                $identityUser = Get-GraphPropertyValue -Object $identity -Name 'user'
                $identityGroup = Get-GraphPropertyValue -Object $identity -Name 'group'
                $identitySiteGroup = Get-GraphPropertyValue -Object $identity -Name 'siteGroup'

                $display = Get-GraphPropertyValue -Object $identityUser -Name 'displayName'
                if ($display) { $grantees.Add("User:$display") }
                $display = Get-GraphPropertyValue -Object $identityGroup -Name 'displayName'
                if ($display) { $grantees.Add("Group:$display") }
                $display = Get-GraphPropertyValue -Object $identitySiteGroup -Name 'displayName'
                if ($display) { $grantees.Add("SiteGroup:$display") }
            }

            $link = Get-GraphPropertyValue -Object $permission -Name 'link'
            $linkScope = Get-GraphPropertyValue -Object $link -Name 'scope'
            if ($linkScope) { $grantees.Add("Link:$linkScope") }

            $items.Add([pscustomobject]@{
                driveId = $DriveId
                itemId = $itemId
                itemName = Get-GraphPropertyValue -Object $item -Name 'name'
                itemType = if ($null -ne $itemFolder) { 'Folder' } elseif ($null -ne $itemFile) { 'File' } else { 'Other' }
                webUrl = Get-GraphPropertyValue -Object $item -Name 'webUrl'
                roles = $roles
                inheritance = if ($null -ne (Get-GraphPropertyValue -Object $permission -Name 'inheritedFrom')) { 'Inherited' } else { 'DirectOrUnknown' }
                grantSource = (@($grantees) -join '; ')
                permissionId = Get-GraphPropertyValue -Object $permission -Name 'id'
                createdDateTime = Get-GraphPropertyValue -Object $item -Name 'createdDateTime'
                lastModifiedDateTime = Get-GraphPropertyValue -Object $item -Name 'lastModifiedDateTime'
            })
        }

        if ($null -ne $itemFolder -and $processedDriveItems -lt $MaxItems) {
            $childrenUri = "https://graph.microsoft.com/v1.0/drives/$DriveId/items/$itemId/children?`$top=200&`$select=$select"
            try {
                $children = @(Get-GraphCollection -Uri $childrenUri)
                foreach ($child in $children) { $queue.Enqueue($child) }
            }
            catch {
                $info = Get-GraphErrorInfo -ErrorRecord $_
                Add-InventoryError -Errors $errors -Scope "driveItem.children:$itemId" -Uri $childrenUri -Message $info.Message -StatusCode $info.StatusCode -ErrorCode $info.ErrorCode -Remediation '폴더 탐색 권한, Graph 응답 또는 API 제한을 확인하십시오.'
            }
        }
    }
}
catch {
    $info = Get-GraphErrorInfo -ErrorRecord $_
    Add-InventoryError -Errors $errors -Scope 'sharepointOneDrive.scopeInventory' -Message $info.Message -StatusCode $info.StatusCode -ErrorCode $info.ErrorCode -Remediation 'Drive ID, Graph PowerShell 로그인 상태, Files.Read.All 권한을 확인하십시오.'
}

$limitReached = ($processedDriveItems -ge $MaxItems)
$result = [ordered]@{
    schemaVersion = '0.3'
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    target = [ordered]@{ userPrincipalName = $TargetUserPrincipalName }
    collection = [ordered]@{
        status = $(if ($errors.Count -gt 0 -or $limitReached) { 'completedWithPartialResults' } else { 'completed' })
        tool = 'Microsoft Graph PowerShell SDK'
        scopeType = $ScopeType
        driveId = $DriveId
        maxItems = $MaxItems
        processedDriveItems = $processedDriveItems
        duplicateDriveItemsSkipped = $duplicateDriveItemsSkipped
        errorCount = $errors.Count
        maxItemsReached = $limitReached
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
Export-PermissionCsv -Rows @($items) -Path $csvPath

Write-Host "완료: $jsonPath" -ForegroundColor Green
Write-Host "요약: $csvPath" -ForegroundColor Green
if ($limitReached) { Write-Warning "MaxItems 한도에 도달했습니다. 결과는 부분 수집일 수 있습니다." }
if ($errors.Count -gt 0) { Write-Warning "일부 항목을 수집하지 못했습니다. JSON의 inventory.errors를 확인하십시오." }
