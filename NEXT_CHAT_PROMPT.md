# Taption Plan 다음 채팅 인계 프롬프트

Taption Plan 작업을 이어간다. 작업 디렉터리는 `/Users/u_mo_c/Documents/taption plan`이다.

먼저 `AGENTS.md`를 읽고 다음 현재 상태를 직접 확인한다. 이 문서에 기록된 SHA나 기기 상태를 최신 상태로 가정하지 않는다.

- `git status --short --branch`
- `git log -3 --oneline --decorate`
- `git rev-parse HEAD origin/main`
- `DEVELOPMENT.md`
- `temp.md`
- 연결된 iPhone의 `com.taption.plan` 설치 버전·build와 실행 프로세스

현재 구조와 제품 계약:

- `Packages/TaptionPlanCore`: 일자 단위 SQLite 저장소와 generation 기반 60Hz NLE 입력 예산
- `Packages/TaptionActivityEngine`: 상세·대분류 활동 taxonomy, 센서 근거 분류, 자동 분류 결과 잠금
- `Packages/TaptionRouteEngine`: GPS 경로 필터, 2D Kalman, 정지 드리프트 억제, 점프·15분 공백 세그먼트, RDP 축약
- 앱 시작은 로컬 스냅샷과 일자 데이터 hydrate가 완료된 뒤 홈으로 진입하고, 사이드바·경로·지도 파생값을 캐시한다.
- 현재·과거 위치는 장소 아이콘보다 앞의 native annotation 졸라맨으로 통일한다. 추적 중에는 선택 시각 위치를 중앙에 유지하고 지도 이동은 추적을 해제한다.
- 지하철 확정 분류와 선로 기반 점선 경로, 수면 등 자동 분류 결과는 저장 후 재로딩해도 바꾸지 않는다. 사용자 편집만 덮어쓰고 원본 센서는 보존한다.
- 핀치 줌과 사이드바 핸들의 확장 터치 영역을 유지한다.
- 재생은 걷기·달리기는 빠르게, 자동차·자전거·지하철·기차·배·비행기는 느리게 적용한다.
- GPS·센서 수집 간격은 슬라이더로 설정한다.
- Dynamic Island는 우측에만 GPS 주기의 절반 길이 진행 파형을 표시하고, 센서 저장 때 ECG 1회 펄스 후 평선으로 돌아간다. 1초 주기에서는 시간 진행이 없다.

최근 검증 기준:

- 전체 XCTest 695/695, 실패·스킵 0
- `TaptionPlanCore` 24/24, `TaptionActivityEngine` 4/4, `TaptionRouteEngine` 11/11
- iOS Simulator Debug build 통과
- 서명된 iPhone Debug build 95 통과
- iPhone 14 Pro 설치·실행·readback: `com.taption.plan` `1.0 (95)`, `TaptionPlan` PID `55910`
- `git diff --check` 통과
- TestFlight archive/upload는 이번 배치 범위가 아니므로 수행하지 않았다.

다음 확인 항목:

1. 실기기에서 현재 위치 지연, 지도 핀치·드래그, 졸라맨 중앙 고정·흔들림, 사이드바 핸들을 확인한다.
2. 오늘 수면·지하철 분류와 선로 점선 경로가 재실행 후 유지되는지 확인한다.
3. Dynamic Island 우측 파형과 15분·1분·1초 경계를 실기기에서 확인한다.
4. `IAP73PAID1`은 Paid Apps Agreement·세금/은행·상품 연결·Sandbox 구매/복원 전까지 완료 처리하지 않는다.
5. TestFlight를 요청받으면 업로드, 처리 완료, `TP Taption Plan 내부 테스트` 그룹 연결·노출을 각각 확인한다.
6. 새 요청은 10자리 영문·숫자 ID로 `temp.md`에 먼저 기록하고 대표님의 `ㄱㄱ` 뒤 실행한다.
