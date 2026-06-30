# Entra RBAC Map — Offline Korean Edition

브라우저에서 `index.html`을 직접 열어 사용할 수 있는 개인용 Microsoft Entra 역할 관계 지도입니다.

## 현재 범위
- 외부 API, 로그인, 서버, 빌드 과정 없음
- Entra 역할과 Microsoft 365 워크로드의 관계 그래프
- 역할/서비스/기능영역 클릭 연동
- 역할 검색, 기능영역 필터, 즐겨찾기(LocalStorage)
- 실제 역할 부여 전 Microsoft 공식 역할 권한 참조 필요

## 파일
- `index.html`: 오프라인 실행용 단일 HTML

## 다음 버전: UPN 기반 종합 권한 조회
입력한 UPN을 기준으로 아래 결과를 한 화면과 CSV/JSON 내보내기 형태로 묶습니다.

### 1. Entra / Microsoft 365 권한
- Entra 디렉터리 역할: 직접 할당 역할, 역할명, 상태
- PIM: 활성 역할과 적격 역할을 분리 표시
- 그룹: 직접/전이 멤버십, 그룹 유형, 소유 여부
- 객체 소유권: 소유 그룹, Teams/Microsoft 365 그룹, 애플리케이션·서비스 주체 등 디렉터리 객체
- Teams: 가입 Team 및 소유자/구성원 여부
- 엔터프라이즈 앱: 직접 또는 그룹 기반 앱 역할 할당(가능한 경우)

### 2. Azure 권한
- 관리 그룹, 구독, 리소스 그룹, 리소스 범위의 Azure RBAC 할당
- 객체명, 객체 유형, 역할명, Scope, 상속 여부, 할당 경로(직접/그룹), Owner 여부를 분리 표시
- Azure RBAC과 Entra 디렉터리 역할은 서로 다른 권한 체계로 구분 표시

### 3. SharePoint / OneDrive 권한
- 사용자의 OneDrive 소유 여부와 드라이브 정보
- 대상 사용자가 소유하거나 직접 공유받은 파일·폴더, 고유 권한이 확인된 항목
- 사이트/파일 객체명, URL, 권한 수준(Read/Edit/Owner 등), 직접/상속 여부, 부여 방식(사용자·그룹·링크)을 표시
- 제한: Microsoft Graph는 특정 driveItem의 유효 공유 권한을 조회할 수 있지만, 특정 사용자가 접근 가능한 테넌트 전체 파일을 역으로 완전 열거하는 단일 API는 제공하지 않음. 결과에는 조회 범위·누락 가능성을 명시함.

## 권장 아키텍처
- 브라우저 UI: 결과 시각화 전용
- 백엔드: 조직의 표준 인증(OBO 또는 Managed Identity / 인증서 기반 애플리케이션)으로 Graph·Azure Resource Manager 호출
- 권한: 조회 모드와 운영/변경 모드를 분리하고, 최소 권한부터 단계적으로 승인
- 감사: 조회자, 대상 UPN, 실행 시각, 조회 범위, 실패 API를 저장
- 보안: Client Secret, Access Token, 인증서 개인키, Tenant 비밀값을 저장소·브라우저 코드·로그에 포함하지 않음

> 운영 테넌트에서는 전체 파일 권한 역추적보다, 먼저 Entra 역할·Azure RBAC·그룹/소유권·앱 권한을 정확히 수집하고 SharePoint/OneDrive는 사이트 또는 드라이브 범위를 지정하는 조사 모드로 시작하는 것을 권장합니다.
