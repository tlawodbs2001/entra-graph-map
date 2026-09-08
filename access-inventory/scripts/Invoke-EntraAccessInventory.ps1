[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[^\s@]+@[^\s@]+\.[^\s@]+$')]
    [string]$UserPrincipalName,
    [string]$OutputRoot = 'C:\scripts\entra-access-inventory\output',
    [switch]$IncludeAzure,
    [switch]$IncludeTransitiveMembership,
    [switch]$SkipPim
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function New-SafeFileName {
    param([Parameter(Mandatory)][string]$Value)
    return ($Value -replace '[^a-zA-Z0-9._-]', '_')
}

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
    param([AllowNull()]$Object, [Parameter(Mandatory)][string]$Name)
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
    param([AllowNull()]$Object, [Parameter(Mandatory)][string]$Name, [AllowNull()]$Default=$null)
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
    param(
        [Parameter(Mandatory)][string]$Uri,
        [int]$MaxAttempts = 5
    )

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

function Add-GraphInventoryError {
    param(
        [Parameter(Mandatory)][System.Collections.Generic.List[object]]$Errors,
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Message,
        [string]$Remediation,
        [Nullable[int]]$Page,
        [Nullable[int]]$StatusCode,
        [string]$ErrorCode
    )

    $Errors.Add([pscustomobject]@{
        scope = $Operation
        uri = $Uri
        page = $Page
        statusCode = $StatusCode
        errorCode = $ErrorCode
        message = $Message
        remediation = $Remediation
    })
}

function Invoke-GraphRequestSafe {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][System.Collections.Generic.List[object]]$Errors
    )

    try { return Invoke-GraphGetWithRetry -Uri $Uri }
    catch {
        $info = Get-GraphErrorInfo -ErrorRecord $_
        Add-GraphInventoryError -Errors $Errors -Operation $Operation -Uri $Uri -Message $info.Message -StatusCode $info.StatusCode -ErrorCode $info.ErrorCode -Remediation 'Graph PowerShell 로그인 상태, delegated 권한, 대상 객체 존재 여부를 확인하십시오.'
        return $null
    }
}

function Invoke-GraphCollectionSafe {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][System.Collections.Generic.List[object]]$Errors,
        [int]$MaxPages = 10000
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    $page = 0
    $seenLinks = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    try {
        while (-not [string]::IsNullOrWhiteSpace([string]$next)) {
            if ($page -ge $MaxPages) { throw "MaxPages($MaxPages)를 초과했습니다. URI=$next" }
            $page++
            if (-not $seenLinks.Add([string]$next)) { throw "동일한 @odata.nextLink가 반복되었습니다. URI=$next" }

            $response = Invoke-GraphGetWithRetry -Uri $next
            if ($null -eq $response) { throw "Graph 응답이 null입니다. page=$page" }

            $valueResult = Get-GraphPropertyResult -Object $response -Name 'value'
            if (-not $valueResult.Exists) { throw "Collection 응답에 value 배열이 없습니다. page=$page type=$($response.GetType().FullName)" }
            foreach ($item in @($valueResult.Value)) { if ($null -ne $item) { $items.Add($item) } }
            $next = [string](Get-GraphPropertyValue -Object $response -Name '@odata.nextLink')
        }
    }
    catch {
        $info = Get-GraphErrorInfo -ErrorRecord $_
        $errorUri = if ([string]::IsNullOrWhiteSpace([string]$next)) { $Uri } else { [string]$next }
        Add-GraphInventoryError -Errors $Errors -Operation $Operation -Uri $errorUri -Page $page -Message $info.Message -StatusCode $info.StatusCode -ErrorCode $info.ErrorCode -Remediation 'Graph 로그인/권한, 응답 구조, pagination 상태를 확인하십시오. 반환 결과는 부분 수집일 수 있습니다.'
    }
    return @($items)
}

function Assert-AzPowerShellAvailable {
    $required = @('Get-AzContext', 'Connect-AzAccount', 'Get-AzSubscription', 'Set-AzContext', 'Get-AzRoleAssignment')
    $missing = @($required | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
    if ($missing.Count -gt 0) {
        throw "Azure PowerShell 모듈이 필요합니다. 누락 명령: $($missing -join ', '). 설치: Install-Module Az.Accounts,Az.Resources -Scope CurrentUser"
    }
}

$errors = [System.Collections.Generic.List[object]]::new()
$safeUpn = New-SafeFileName -Value $UserPrincipalName
$outDir = Join-Path $OutputRoot $safeUpn
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

$scopes = [System.Collections.Generic.List[string]]::new()
foreach ($scope in @('User.Read.All', 'Group.Read.All', 'Directory.Read.All', 'Files.Read.All')) { $scopes.Add($scope) }
if (-not $SkipPim) { $scopes.Add('RoleManagement.Read.Directory') }
Ensure-GraphConnection -Scopes @($scopes | Select-Object -Unique)

$encodedUpn = [uri]::EscapeDataString($UserPrincipalName)
$userUri = "https://graph.microsoft.com/v1.0/users/$encodedUpn?`$select=id,displayName,userPrincipalName,accountEnabled,createdDateTime,companyName,userType"
$user = Invoke-GraphRequestSafe -Uri $userUri -Operation 'entra.user' -Errors $errors
$userId = [string](Get-GraphPropertyValue -Object $user -Name 'id')

if ($null -eq $user -or [string]::IsNullOrWhiteSpace($userId)) {
    $failed = [ordered]@{
        schemaVersion = '0.3'
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
        target = [ordered]@{ userPrincipalName = $UserPrincipalName }
        collection = [ordered]@{ status = 'failed'; tool = 'Microsoft Graph PowerShell SDK'; errors = @($errors) }
        inventory = [ordered]@{ entra = @{}; azure = @{}; sharePointOneDrive = @{}; errors = @($errors) }
    }
    $failed | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath (Join-Path $outDir 'access-inventory.json') -Encoding utf8
    throw "대상 사용자를 조회하지 못했습니다. 결과 파일: $outDir\access-inventory.json"
}

$memberOf = Invoke-GraphCollectionSafe -Uri "https://graph.microsoft.com/v1.0/users/$userId/memberOf?`$top=999" -Operation 'entra.memberOf' -Errors $errors
$transitiveMemberOf = @()
if ($IncludeTransitiveMembership) {
    $transitiveMemberOf = Invoke-GraphCollectionSafe -Uri "https://graph.microsoft.com/v1.0/users/$userId/transitiveMemberOf?`$top=999" -Operation 'entra.transitiveMemberOf' -Errors $errors
}
$ownedObjects = Invoke-GraphCollectionSafe -Uri "https://graph.microsoft.com/v1.0/users/$userId/ownedObjects?`$top=999" -Operation 'entra.ownedObjects' -Errors $errors
$appRoleAssignments = Invoke-GraphCollectionSafe -Uri "https://graph.microsoft.com/v1.0/users/$userId/appRoleAssignments?`$top=999" -Operation 'entra.appRoleAssignments' -Errors $errors
$drive = Invoke-GraphRequestSafe -Uri "https://graph.microsoft.com/v1.0/users/$userId/drive?`$select=id,driveType,webUrl,quota,owner" -Operation 'onedrive.drive' -Errors $errors

$pimActive = @()
if (-not $SkipPim) {
    $filter = [uri]::EscapeDataString("principalId eq '$userId'")
    $expand = [uri]::EscapeDataString('roleDefinition($select=id,displayName)')
    $pimActive = Invoke-GraphCollectionSafe -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignmentScheduleInstances?`$filter=$filter&`$expand=$expand&`$top=999" -Operation 'entra.pimActive' -Errors $errors
}

$azureAssignments = @()
$azureCollection = [ordered]@{ attempted = [bool]$IncludeAzure; status = 'notRequested'; subscriptions = @(); assignments = @() }
if ($IncludeAzure) {
    try {
        Assert-AzPowerShellAvailable
        $azContext = Get-AzContext -ErrorAction SilentlyContinue
        if (-not $azContext -or -not $azContext.Account) { Connect-AzAccount -ErrorAction Stop | Out-Null }

        $subscriptions = @(Get-AzSubscription -ErrorAction Stop | Where-Object { $_.State -eq 'Enabled' })
        $azureCollection.status = 'completed'
        foreach ($subscription in $subscriptions) {
            try {
                $subscription | Set-AzContext -ErrorAction Stop | Out-Null
                $subId = [string]$subscription.Id
                $azureCollection.subscriptions += [pscustomobject]@{
                    id = $subId
                    name = $subscription.Name
                    tenantId = [string]$subscription.TenantId
                }

                $assignments = @(Get-AzRoleAssignment -ObjectId $userId -ErrorAction Stop)
                foreach ($item in $assignments) {
                    $azureAssignments += [pscustomobject]@{
                        subscriptionId = $subId
                        subscriptionName = $subscription.Name
                        roleName = $item.RoleDefinitionName
                        scope = $item.Scope
                        principalType = $item.ObjectType
                        assignmentType = 'AzureRBAC'
                        description = $item.Description
                        isOwner = ($item.RoleDefinitionName -eq 'Owner')
                    }
                }
            }
            catch {
                $errors.Add([pscustomobject]@{
                    scope = "azure.rbac.$($subscription.Id)"
                    uri = ''
                    page = $null
                    statusCode = $null
                    errorCode = 'AzureRoleAssignmentFailed'
                    message = $_.Exception.Message
                    remediation = '해당 구독 컨텍스트와 Reader 이상 조회 권한, Az.Resources 모듈 상태를 확인하십시오.'
                })
            }
        }
        $azureCollection.assignments = @($azureAssignments)
    }
    catch {
        $azureCollection.status = 'partialOrFailed'
        $errors.Add([pscustomobject]@{
            scope = 'azure.rbac'
            uri = ''
            page = $null
            statusCode = $null
            errorCode = 'AzureCollectionFailed'
            message = $_.Exception.Message
            remediation = 'Azure PowerShell 로그인, Az.Accounts/Az.Resources 모듈, 구독 조회 권한을 확인하십시오.'
        })
    }
}

$directMembership = @($memberOf)
$transitiveMembership = @($transitiveMemberOf)
$owners = @($ownedObjects)
$appRoles = @($appRoleAssignments)
$pim = @($pimActive)

$result = [ordered]@{
    schemaVersion = '0.3'
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    target = [ordered]@{
        id = $userId
        displayName = Get-GraphPropertyValue -Object $user -Name 'displayName'
        userPrincipalName = Get-GraphPropertyValue -Object $user -Name 'userPrincipalName'
        userType = Get-GraphPropertyValue -Object $user -Name 'userType'
        companyName = Get-GraphPropertyValue -Object $user -Name 'companyName'
        accountEnabled = Get-GraphPropertyValue -Object $user -Name 'accountEnabled'
        createdDateTime = Get-GraphPropertyValue -Object $user -Name 'createdDateTime'
    }
    collection = [ordered]@{
        status = $(if ($errors.Count -gt 0) { 'completedWithPartialResults' } else { 'completed' })
        tool = 'Microsoft Graph PowerShell SDK + optional Azure PowerShell'
        flags = [ordered]@{
            includeAzure = [bool]$IncludeAzure
            includeTransitiveMembership = [bool]$IncludeTransitiveMembership
            skipPim = [bool]$SkipPim
        }
        outputDirectory = $outDir
        errorCount = $errors.Count
    }
    inventory = [ordered]@{
        entra = [ordered]@{
            directMembership = $directMembership
            transitiveMembership = $transitiveMembership
            ownedObjects = $owners
            appRoleAssignments = $appRoles
            pimActiveRoleAssignments = $pim
        }
        azure = $azureCollection
        sharePointOneDrive = [ordered]@{
            drive = $drive
            collectionScope = 'OneDrive drive metadata only. Use Invoke-SharePointOneDriveScopeInventory.ps1 for a specified drive.'
        }
        errors = @($errors)
    }
}

$jsonPath = Join-Path $outDir 'access-inventory.json'
$result | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $jsonPath -Encoding utf8

$summary = [System.Collections.Generic.List[object]]::new()
$summary.Add([pscustomobject]@{ Category='Target'; Item='User'; Name=(Get-GraphPropertyValue -Object $user -Name 'displayName'); Detail=(Get-GraphPropertyValue -Object $user -Name 'userPrincipalName'); Level='N/A' })
foreach ($entry in $directMembership) {
    $summary.Add([pscustomobject]@{ Category='Entra direct membership'; Item=(Get-GraphPropertyValue -Object $entry -Name '@odata.type'); Name=(Get-GraphPropertyValue -Object $entry -Name 'displayName'); Detail=(Get-GraphPropertyValue -Object $entry -Name 'id'); Level='Direct' })
}
foreach ($entry in $pim) {
    $roleDefinition = Get-GraphPropertyValue -Object $entry -Name 'roleDefinition'
    $summary.Add([pscustomobject]@{ Category='PIM active'; Item='Directory role'; Name=(Get-GraphPropertyValue -Object $roleDefinition -Name 'displayName'); Detail=(Get-GraphPropertyValue -Object $entry -Name 'directoryScopeId'); Level='Active' })
}
foreach ($entry in $owners) {
    $summary.Add([pscustomobject]@{ Category='Owned object'; Item=(Get-GraphPropertyValue -Object $entry -Name '@odata.type'); Name=(Get-GraphPropertyValue -Object $entry -Name 'displayName'); Detail=(Get-GraphPropertyValue -Object $entry -Name 'id'); Level='Owner' })
}
foreach ($entry in $appRoles) {
    $summary.Add([pscustomobject]@{ Category='Enterprise app'; Item=(Get-GraphPropertyValue -Object $entry -Name 'resourceDisplayName'); Name=(Get-GraphPropertyValue -Object $entry -Name 'appRoleId'); Detail=(Get-GraphPropertyValue -Object $entry -Name 'resourceId'); Level='Assigned' })
}
foreach ($entry in $azureAssignments) {
    $summary.Add([pscustomobject]@{ Category='Azure RBAC'; Item=$entry.subscriptionName; Name=$entry.roleName; Detail=$entry.scope; Level=$(if($entry.isOwner){'Owner'}else{'Assigned'}) })
}

$summary.ToArray() | Export-Csv -LiteralPath (Join-Path $outDir 'access-inventory-summary.csv') -NoTypeInformation -Encoding utf8BOM

Write-Host "완료: $jsonPath" -ForegroundColor Green
Write-Host "요약: $(Join-Path $outDir 'access-inventory-summary.csv')" -ForegroundColor Green
if ($errors.Count -gt 0) { Write-Warning "일부 영역이 수집되지 않았습니다. access-inventory.json의 inventory.errors를 확인하십시오." }
