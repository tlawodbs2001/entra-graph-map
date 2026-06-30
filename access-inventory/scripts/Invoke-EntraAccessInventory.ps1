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

function New-SafeFileName {
    param([Parameter(Mandatory)][string]$Value)
    return ($Value -replace '[^a-zA-Z0-9._-]', '_')
}

function Invoke-MgcJson {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][System.Collections.Generic.List[object]]$Errors
    )

    try {
        $raw = & mgc @Arguments --output JSON 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw ($raw | Out-String)
        }
        $text = ($raw | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return ($text | ConvertFrom-Json -Depth 100)
    }
    catch {
        $Errors.Add([pscustomobject]@{
            scope = $Operation
            message = $_.Exception.Message
            remediation = 'mgc 로그인 상태, Graph 권한, 대상 사용자 존재 여부를 확인하십시오.'
        })
        return $null
    }
}

function Get-GraphValueArray {
    param($Response)
    if ($null -eq $Response) { return @() }
    if ($Response.PSObject.Properties.Name -contains 'value') { return @($Response.value) }
    return @($Response)
}

if (-not (Get-Command mgc -ErrorAction SilentlyContinue)) {
    throw 'mgc를 찾을 수 없습니다. Microsoft Graph CLI 설치 및 PATH 등록 후 다시 실행하십시오.'
}

$errors = [System.Collections.Generic.List[object]]::new()
$safeUpn = New-SafeFileName -Value $UserPrincipalName
$outDir = Join-Path $OutputRoot $safeUpn
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

try { & mgc profile show | Out-Null } catch { }

$user = Invoke-MgcJson -Arguments @(
    'users','with-user-principal-name','--user-principal-name',$UserPrincipalName,
    'get','--select','id,displayName,userPrincipalName,accountEnabled,createdDateTime,companyName,userType'
) -Operation 'entra.user' -Errors $errors

if ($null -eq $user -or [string]::IsNullOrWhiteSpace($user.id)) {
    $result = [ordered]@{
        schemaVersion = '0.1'
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
        target = [ordered]@{ userPrincipalName = $UserPrincipalName }
        collection = [ordered]@{ status = 'failed'; tool = 'mgc'; errors = @($errors) }
        inventory = [ordered]@{ entra = @{}; azure = @{}; sharePointOneDrive = @{}; errors = @($errors) }
    }
    $result | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath (Join-Path $outDir 'access-inventory.json') -Encoding utf8
    throw "대상 사용자를 조회하지 못했습니다. 결과 파일: $outDir\access-inventory.json"
}

$memberOf = Invoke-MgcJson -Arguments @(
    'users','with-user-principal-name','--user-principal-name',$UserPrincipalName,
    'member-of','list','--all'
) -Operation 'entra.memberOf' -Errors $errors

$transitiveMemberOf = $null
if ($IncludeTransitiveMembership) {
    $transitiveMemberOf = Invoke-MgcJson -Arguments @(
        'users','with-user-principal-name','--user-principal-name',$UserPrincipalName,
        'transitive-member-of','list','--all'
    ) -Operation 'entra.transitiveMemberOf' -Errors $errors
}

$ownedObjects = Invoke-MgcJson -Arguments @(
    'users','with-user-principal-name','--user-principal-name',$UserPrincipalName,
    'owned-objects','list','--all'
) -Operation 'entra.ownedObjects' -Errors $errors

$appRoleAssignments = Invoke-MgcJson -Arguments @(
    'users','with-user-principal-name','--user-principal-name',$UserPrincipalName,
    'app-role-assignments','list','--all'
) -Operation 'entra.appRoleAssignments' -Errors $errors

$drive = Invoke-MgcJson -Arguments @(
    'users','with-user-principal-name','--user-principal-name',$UserPrincipalName,
    'drive','get','--select','id,driveType,webUrl,quota,owner'
) -Operation 'onedrive.drive' -Errors $errors

$pimActive = $null
if (-not $SkipPim) {
    $pimActive = Invoke-MgcJson -Arguments @(
        'role-management','directory','role-assignment-schedule-instances','list','--all',
        '--filter',"principalId eq '$($user.id)'",
        '--expand','roleDefinition($select=id,displayName)'
    ) -Operation 'entra.pimActive' -Errors $errors
}

$azureAssignments = @()
$azureCollection = [ordered]@{ attempted = [bool]$IncludeAzure; status = 'notRequested'; subscriptions = @(); assignments = @() }
if ($IncludeAzure) {
    if (Get-Command az -ErrorAction SilentlyContinue) {
        try {
            $accountsText = & az account list --all --output json 2>&1
            if ($LASTEXITCODE -ne 0) { throw ($accountsText | Out-String) }
            $accounts = $accountsText | ConvertFrom-Json -Depth 20
            $azureCollection.status = 'completed'
            foreach ($account in @($accounts | Where-Object { $_.state -eq 'Enabled' })) {
                $subId = $account.id
                $azureCollection.subscriptions += [pscustomobject]@{ id = $subId; name = $account.name; tenantId = $account.tenantId }
                $raw = & az role assignment list --assignee-object-id $user.id --subscription $subId --all --include-inherited --output json 2>&1
                if ($LASTEXITCODE -ne 0) {
                    $errors.Add([pscustomobject]@{ scope = "azure.rbac.$subId"; message = ($raw | Out-String); remediation = '구독 Reader 이상 권한 및 az 로그인 컨텍스트를 확인하십시오.' })
                    continue
                }
                $items = $raw | ConvertFrom-Json -Depth 50
                foreach ($item in @($items)) {
                    $azureAssignments += [pscustomobject]@{
                        subscriptionId = $subId
                        subscriptionName = $account.name
                        roleName = $item.roleDefinitionName
                        scope = $item.scope
                        principalType = $item.principalType
                        assignmentType = $item.assignmentType
                        description = $item.description
                        isOwner = ($item.roleDefinitionName -eq 'Owner')
                    }
                }
            }
            $azureCollection.assignments = @($azureAssignments)
        }
        catch {
            $azureCollection.status = 'partialOrFailed'
            $errors.Add([pscustomobject]@{ scope = 'azure.rbac'; message = $_.Exception.Message; remediation = 'az login, 구독 목록 조회 권한, 각 구독 Reader 권한을 확인하십시오.' })
        }
    }
    else {
        $azureCollection.status = 'azNotFound'
        $errors.Add([pscustomobject]@{ scope = 'azure.rbac'; message = 'az CLI를 찾을 수 없습니다.'; remediation = 'Azure CLI 설치 또는 Azure RBAC 수집 생략을 선택하십시오.' })
    }
}

$directMembership = Get-GraphValueArray $memberOf
$transitiveMembership = Get-GraphValueArray $transitiveMemberOf
$owners = Get-GraphValueArray $ownedObjects
$appRoles = Get-GraphValueArray $appRoleAssignments
$pim = Get-GraphValueArray $pimActive

$result = [ordered]@{
    schemaVersion = '0.1'
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
        tool = 'mgc + optional az'
        flags = [ordered]@{ includeAzure = [bool]$IncludeAzure; includeTransitiveMembership = [bool]$IncludeTransitiveMembership; skipPim = [bool]$SkipPim }
        outputDirectory = $outDir
    }
    inventory = [ordered]@{
        entra = [ordered]@{
            directMembership = @($directMembership)
            transitiveMembership = @($transitiveMembership)
            ownedObjects = @($owners)
            appRoleAssignments = @($appRoles)
            pimActiveRoleAssignments = @($pim)
        }
        azure = $azureCollection
        sharePointOneDrive = [ordered]@{
            drive = $drive
            collectionScope = 'OneDrive drive metadata only. Use Invoke-SharePointOneDriveScopeInventory.ps1 for a specified site or drive.'
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
