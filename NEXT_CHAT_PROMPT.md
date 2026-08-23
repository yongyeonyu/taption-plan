# Taption Plan 다음 채팅 핸드오프

아래 내용을 새 채팅에 그대로 붙여넣고 작업을 이어가세요.

```text
요청 ID: REFA042A01
작업 디렉토리: /Users/u_mo_c/Documents/taption plan
먼저 AGENTS.md를 읽고, 시작 시 main 최신 SHA와 git status를 확인한다.

현재 기준
- main에는 센서 수집 전원 정책, 백그라운드 보관 완료 대기, 보안 키 생성 안전성,
  경로·집계 강제 언래핑 제거, 백업 진단 통합이 반영되어 있다.
- build 72를 업로드했고 현재 App Store Connect 처리 중이다. build 72 Delivery UUID는
  58eaab2b-f245-4b90-800e-a07f3ecddc3b이다. 직전 TestFlight build 71의 Delivery UUID는
  defe3686-57cc-4319-9b41-aeb2b3bc8f43이다.
- `temp.md`는 새 요청을 등록할 때만 만들고, 모든 항목 완료 후 삭제한다.

확인된 게이트
- `git diff --check` 통과
- REFA042A01 Debug iOS Simulator build 성공
- build 72 IPA export 및 App Store Connect 업로드 성공, 현재 `PROCESSING`
- XCTest는 현재 두 시뮬레이터에서 테스트 러너 부트스트랩 크래시로 본문 실행 불가
- CloudKit 복구 테스트는 시뮬레이터 entitlement 환경과 분리해 판단

다음 작업 우선순위
1. build 72 TestFlight 처리가 완료되어 테스터 그룹에 노출되는지 확인
2. iPhone 설치·실행·센서 백그라운드 기록을 실기기로 확인
4. `MapHomeView`·`AppModel` 대규모 분해는 테스트 범위를 먼저 정한 뒤 별도 요청으로 진행
5. 센서 대분류를 Dynamic Island에 반영할 상태 계약과 실기기 검증 설계
6. AppIcon과 햄버거 홈 아이콘을 동일 원본으로 교체하고 시각/해시 확인
7. 강제 종료와 백그라운드 센서 기록의 지원 범위를 QA 문구로 분리

주의
- 원본 센서·HealthKit 데이터는 삭제·수정하지 않는다.
- 고빈도 제스처는 60Hz 화면 갱신 예산을 유지한다.
- 기존 사용자 변경을 덮어쓰지 말고, 요청 범위를 벗어난 asset·제품 동작 변경은 먼저 알린다.
- 커밋·푸시·TestFlight·iPhone 설치는 각각 결과를 확인한 뒤 다음 게이트로 진행한다.
```
