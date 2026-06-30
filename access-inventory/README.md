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
- Azure RBAC(로컬 `az` CLI가 있고 로그인된 경우)
- SharePoint/OneDrive는 지정 드라이브 또는 사이트 범위 조사 스크립트로 분리
- JSON 결과를 `ui/index.html`에 불러와 오프라인으로 확인

## 실행 전제

- `mgc` 로그인 완료
- 다른 사용자의 디렉터리 멤버십을 읽으려면 일반적으로 `User.Read.All` 또는 `Directory.Read.All` 계열 권한이 필요합니다.
- PIM 활성 역할은 `RoleAssignmentSchedule.Read.Directory`와 지원되는 Entra 역할이 필요합니다.
- Azure RBAC 수집은 `az login` 및 대상 구독에 대한 읽기 권한이 필요합니다.
- SharePoint/OneDrive 파일 권한은 범위를 지정해야 합니다. 특정 사용자가 접근 가능한 테넌트 전체 파일을 역으로 완전 열거하는 단일 API는 제공되지 않습니다.

## 실행 예시

```powershell
Set-ExecutionPolicy -Scope Process Bypass
cd C:\scripts\entra-access-inventory\scripts
.\Invoke-EntraAccessInventory.ps1 -UserPrincipalName user@contoso.com -IncludeAzure
```

결과 기본 경로:

```text
C:\scripts\entra-access-inventory\output\<UPN_안전한파일명>\access-inventory.json
```

## UI 사용

1. `ui\index.html`을 브라우저에서 엽니다.
2. **결과 JSON 불러오기**를 누릅니다.
3. `access-inventory.json`을 선택합니다.

## 보안 원칙

- 조회 전용입니다. 쓰기/삭제/권한 변경 명령을 포함하지 않습니다.
- Access Token, Client Secret, 인증서 개인키, 실제 결과 파일은 저장소에 올리지 않습니다.
- 조회 대상 UPN과 결과물은 로컬 보관을 기본으로 합니다.
