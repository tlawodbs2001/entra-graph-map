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

function Invoke-GraphRequestSafe {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][System.Collections.Generic.List[object]]$Errors
    )

    try { return Invoke-MgGraphRequest -Method GET -Uri $Uri -ErrorAction Stop }
    catch {
        $Errors.Add([pscustomobject]@{
            scope = $Operation
            message = $_.Exception.Message
            remediation = 'Graph PowerShell 로그인 상태, delegated 권한, 대상 객체 존재 여부를 확인하십시오.'
        })
        return $null
    }
}

function Invoke-GraphCollectionSafe {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][System.Collections.Generic.List[object]]$Errors
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    try {
        while (-not [string]::IsNullOrWhiteSpace([string]$next)) {
            $response = Invoke-MgGraphRequest -Method GET -Uri $next -ErrorAction Stop
            foreach ($item in @(Get-GraphPropertyValue -Object $response -Name 'value')) { $items.Add($item) }
            $next = [string](Get-GraphPropertyValue -Object $response -Name '@odata.nextLink')
        }
    }
    catch {
        $Errors.Add([pscustomobject]@{
            scope = $Operation
            message = $_.Exception.Message
            remediation = 'Graph PowerShell 로그인 상태, delegated 권한, Graph 페이징 응답을 확인하십시오.'
        })
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
$user = Invoke-GraphRequestSafe `
    -Uri "https://graph.microsoft.com/v1.0/users/$encodedUpn?`$select=id,displayName,userPrincipalName,accountEnabled,createdDateTime,companyName,userType" `
    -Operation 'entra.user' -Errors $errors

if ($null -eq $user -or [string]::IsNullOrWhiteSpace([string]$user.id)) {
    $failed = [ordered]@{
        schemaVersion = '0.2'
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
        target = [ordered]@{ userPrincipalName = $UserPrincipalName }
        collection = [ordered]@{ status = 'failed'; tool = 'Microsoft Graph PowerShell SDK'; errors = @($errors) }
        inventory = [ordered]@{ entra = @{}; azure = @{}; sharePointOneDrive = @{}; errors = @($errors) }
    }
    $failed | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath (Join-Path $outDir 'access-inventory.json') -Encoding utf8
    throw "대상 사용자를 조회하지 못했습니다. 결과 파일: $outDir\access-inventory.json"
}

$userId = [string]$user.id
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
    $pimActive = Invoke-GraphCollectionSafe `
        -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignmentScheduleInstances?`$filter=$filter&`$expand=$expand&`$top=999" `
        -Operation 'entra.pimActive' -Errors $errors
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

                # Selected subscription context + ObjectId returns assignments under the subscription;
                # do not constrain -Scope here, because resource-group/resource-level assignments must also be included.
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
    schemaVersion = '0.2'
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    target = [ordered]@{
        id = $user.id
        displayName = $user.displayName
        userPrincipalName = $user.userPrincipalName
        userType = $user.userType
        companyName = $user.companyName
        accountEnabled = $user.accountEnabled
        createdDateTime = $user.createdDateTime
    }
    collection = [ordered]@{
        status = 'completedWithPossiblePartialResults'
        tool = 'Microsoft Graph PowerShell SDK + optional Azure PowerShell'
        flags = [ordered]@{
            includeAzure = [bool]$IncludeAzure
            includeTransitiveMembership = [bool]$IncludeTransitiveMembership
            skipPim = [bool]$SkipPim
        }
        outputDirectory = $outDir
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

$summary = @(
    [pscustomobject]@{ Category='Target'; Item='User'; Name=$user.displayName; Detail=$user.userPrincipalName; Level='N/A' }
    $directMembership | ForEach-Object { [pscustomobject]@{ Category='Entra direct membership'; Item=$_.'@odata.type'; Name=$_.displayName; Detail=$_.id; Level='Direct' } }
    $pim | ForEach-Object { [pscustomobject]@{ Category='PIM active'; Item='Directory role'; Name=$_.roleDefinition.displayName; Detail=$_.directoryScopeId; Level='Active' } }
    $owners | ForEach-Object { [pscustomobject]@{ Category='Owned object'; Item=$_.'@odata.type'; Name=$_.displayName; Detail=$_.id; Level='Owner' } }
    $appRoles | ForEach-Object { [pscustomobject]@{ Category='Enterprise app'; Item=$_.resourceDisplayName; Name=$_.appRoleId; Detail=$_.resourceId; Level='Assigned' } }
    $azureAssignments | ForEach-Object { [pscustomobject]@{ Category='Azure RBAC'; Item=$_.subscriptionName; Name=$_.roleName; Detail=$_.scope; Level=if($_.isOwner){'Owner'}else{'Assigned'} } }
)

$summary | Export-Csv -LiteralPath (Join-Path $outDir 'access-inventory-summary.csv') -NoTypeInformation -Encoding utf8BOM

Write-Host "완료: $jsonPath" -ForegroundColor Green
Write-Host "요약: $(Join-Path $outDir 'access-inventory-summary.csv')" -ForegroundColor Green
if ($errors.Count -gt 0) { Write-Warning "일부 영역이 수집되지 않았습니다. access-inventory.json의 inventory.errors를 확인하십시오." }
