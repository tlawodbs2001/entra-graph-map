# Entra Access Inventory

입력한 UPN을 기준으로 Microsoft Entra, Microsoft 365, Azure RBAC, SharePoint/OneDrive 조사 결과를 **읽기 전용**으로 수집하고, 오프라인 HTML에서 검토하기 위한 도구입니다.

## 현재 구현 범위

- Entra 사용자 기본 정보
- 직접 그룹/디렉터리 역할/관리 단위 멤버십
- 전이 그룹 멤버십
- 대상 사용자가 소유한 디렉터리 객체
- 사용자에게 직접 할당된 엔터프라이즈 앱 역할
- PIM 활성 역할(권한·역할 조건이 충족되는 경우)
- OneDrive 드라이브 기본 정보
- Azure RBAC(Azure PowerShell 사용)
- SharePoint/OneDrive 지정 드라이브 범위 조사
- JSON 결과를 `ui/index.html`에 불러와 오프라인으로 확인

## 실행 전제

- PowerShell 7 권장
- Microsoft Graph PowerShell SDK
- Azure RBAC 수집 시 Azure PowerShell `Az.Accounts`, `Az.Resources`

Graph SDK가 없으면 예를 들어 다음과 같이 설치합니다.

```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
```

Azure 기능을 사용할 경우 필요한 모듈 예시:

```powershell
Install-Module Az.Accounts -Scope CurrentUser
Install-Module Az.Resources -Scope CurrentUser
```

스크립트는 필요한 경우 `Connect-MgGraph -UseDeviceCode`로 Graph 세션을 연결합니다. Azure 수집을 요청했고 현재 Azure PowerShell 세션이 없으면 `Connect-AzAccount`를 사용합니다.

주요 읽기 권한:

```text
User.Read.All
Group.Read.All
Directory.Read.All
Files.Read.All
RoleManagement.Read.Directory  # PIM 조회 시
Sites.Read.All                 # Drive 범위 조사 시
```

실제 테넌트 정책과 관리자 동의 상태에 따라 일부 권한은 사전 승인이 필요할 수 있습니다.

## 실행 예시

```powershell
Set-ExecutionPolicy -Scope Process Bypass
cd C:\scripts\entra-access-inventory\scripts
.\Invoke-EntraAccessInventory.ps1 -UserPrincipalName user@contoso.com -IncludeAzure
```

Graph만 수집:

```powershell
.\Invoke-EntraAccessInventory.ps1 -UserPrincipalName user@contoso.com
```

PIM을 제외해서 최소 범위로 실행:

```powershell
.\Invoke-EntraAccessInventory.ps1 -UserPrincipalName user@contoso.com -SkipPim
```

지정 Drive 권한 조사:

```powershell
.\Invoke-SharePointOneDriveScopeInventory.ps1 `
  -ScopeType Drive `
  -DriveId "<drive-id>" `
  -TargetUserPrincipalName "user@contoso.com"
```

결과 기본 경로:

```text
C:\scripts\entra-access-inventory\output\<UPN_안전한파일명>\access-inventory.json
```

## 구현 기준

- Microsoft Graph CLI(`mgc`) 사용 안 함
- Azure CLI(`az`) 사용 안 함
- Microsoft Graph PowerShell SDK 사용
- Azure 기능은 Azure PowerShell 사용
- Secret, Token, Client Secret을 스크립트나 저장소에 저장하지 않음
- 조회 전용 유지

## UI 사용

1. `ui\index.html`을 브라우저에서 엽니다.
2. **결과 JSON 불러오기**를 누릅니다.
3. `access-inventory.json`을 선택합니다.

## 보안 원칙

- 조회 전용입니다. 쓰기/삭제/권한 변경 명령을 포함하지 않습니다.
- Access Token, Client Secret, 인증서 개인키, 실제 결과 파일은 저장소에 올리지 않습니다.
- 조회 대상 UPN과 결과물은 로컬 보관을 기본으로 합니다.
