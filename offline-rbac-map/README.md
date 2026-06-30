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

## 다음 버전 계획
1. 입력 UPN의 Entra 디렉터리 역할과 PIM 활성 역할 조회
2. 특정 대상의 Microsoft 365 객체 및 SharePoint/OneDrive 권한 조사

> 보안 원칙: Client Secret, Access Token, Tenant 비밀값을 저장소·브라우저 코드·로그에 포함하지 않습니다.
