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
- 지하철 확정 분류와 확정 선로 경로, 수면 등 자동 분류 결과는 저장 후 재로딩해도 바꾸지 않는다. 예상·점선 경로 오버레이는 현재 비활성화하고 사용자 편집만 덮어쓰며 원본 센서는 보존한다.
- 핀치 줌과 사이드바 핸들의 확장 터치 영역을 유지한다.
- 재생은 걷기·달리기는 빠르게, 자동차·자전거·지하철·기차·배·비행기는 느리게 적용한다.
- GPS·센서 수집 간격은 슬라이더로 설정한다.
- Dynamic Island는 확장 영역 전체 폭을 우→좌로 흐르는 파형으로 표시하고 compact 좌·우 영역도 연속 위상을 공유한다. 센서 저장 때 ECG 1회 펄스 후 평선으로 돌아가며, 우측 상단 2px 점만 로깅 중 1초 주기로 점멸한다.
- 시간 레일 핸들 왼쪽 compact 날씨 칩은 표시하지 않는다. 시간축 날씨 카드는 수집 시각·비 stale·조건·심볼·온도가 완성된 스냅샷일 때만 표시하고, 포함된 미세먼지 필드가 불완전하면 카드 전체를 숨긴다.

최근 검증 기준:

- 전체 XCTest 성공, 실패·스킵 0
- iOS Simulator Debug build와 Release archive/export 통과
- 최신 TestFlight build 102는 IPA 검증·업로드·처리 완료(`VALID`, `APP_STORE_ELIGIBLE`) 후 `TP Taption Plan 내부 테스트` 그룹 연결·그룹 빌드 목록 노출까지 확인했다. Delivery UUID `9bec24ce-e0da-4868-8398-5c75e8b3421b`.
- 실기기 설치·실행·readback은 아직 별도 게이트이며, 마지막 확인된 기기 기록은 `1.0 (95)`이다.
- `git diff --check` 통과
- 최신 센서 미터·상태·Dynamic Island 파형 수정은 TestFlight build 102에 포함됐다. 실기기 설치·실행·readback은 별도 게이트다.

다음 확인 항목:

1. build 102를 연결된 iPhone에 설치·실행하고 버전/readback 및 실제 터치 화면을 확인한다.
2. 현재 위치 지연, 지도 핀치·드래그, 졸라맨 중앙 고정·흔들림, 사이드바 핸들을 확인한다.
3. 오늘 수면·지하철 분류와 선로 경로, Dynamic Island 우측 파형·15분·1분·1초 경계를 실기기에서 확인한다.
4. `IAP73PAID1`은 Paid Apps Agreement·세금/은행·상품 연결·Sandbox 구매/복원 전까지 완료 처리하지 않는다.
5. 다음 TestFlight 요청은 build 102 이상을 사용하고, 업로드·처리 완료·`TP Taption Plan 내부 테스트` 그룹 연결·노출을 각각 확인한다.
6. 새 요청은 10자리 영문·숫자 ID로 `temp.md`에 먼저 기록하고 대표님의 `ㄱㄱ` 뒤 실행한다.
