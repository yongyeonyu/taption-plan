# Taption Plan 다음 채팅 인계 프롬프트

Taption Plan 작업을 이어간다. 작업 디렉터리는 `/Users/u_mo_c/Documents/taption plan`이다.

먼저 `AGENTS.md`를 끝까지 읽고 현재 상태를 직접 확인한다. 아래 기록의 SHA·기기 상태·TestFlight 상태를 최신 사실로 가정하지 않는다.

```sh
cd "/Users/u_mo_c/Documents/taption plan"
git status --short --branch
git log -5 --oneline --decorate
git rev-parse HEAD origin/main
sed -n '1,360p' DEVELOPMENT.md
test -f temp.md && sed -n '1,200p' temp.md || true
xcrun devicectl list devices
xcrun devicectl device info apps --device C44AF739-127D-572D-AD83-417C7E879045
```

현재 `main`에는 `ZIDX27A1B2` 지도 졸라맨 최전면 수정까지 반영되어 있으며, 작업 시작 시 `main`과 `origin/main`의 실제 SHA 일치를 다시 확인한다. 최근 변경은 다음과 같다.

- `Packages/TaptionPlanCore`: 일자 단위 SQLite 저장소와 generation 기반 60Hz NLE 입력 예산
- `Packages/TaptionActivityEngine`: 센서 근거 활동 taxonomy와 자동 분류 결과 잠금
- `Packages/TaptionRouteEngine`: GPS 정확도·점프·공백 필터, 2D Kalman, RDP 표시 축약
- 앱은 로컬 스냅샷·일자 데이터를 먼저 hydrate하고 사이드바·경로·지도 파생값을 캐시한다.
- 현재·과거 위치는 MapKit의 투명 위치 앵커를 따라가는 SwiftUI overlay 졸라맨으로 표시해 모든 지도 annotation보다 앞에 둔다. 추적 중 선택 시각 위치를 중앙에 유지하고 지도 이동은 추적을 해제한다.
- 지하철 확정 선로 경로·수면·이동 분류는 원본 센서를 보존한 채 저장 후 유지한다. GPS 공백 구간의 예상 경로는 점선으로 표시한다.
- 재생 시작 시 경로 투영을 비우고 원본 읽기를 다시 준비한다. 재생 중 플레이헤드가 움직일 때 경로와 졸라맨 위치를 갱신하며, 표시 경로는 플레이헤드 시각까지 생성한다.
- GPS·센서 수집 간격은 슬라이더 설정을 사용한다.
- Dynamic Island 확장형은 전체 폭 우→좌 파형·센서 저장 ECG 1회 펄스·1초 2px 점멸점을 사용한다. 센서 Live Activity의 확장형 leading과 수집 중 compact leading에는 `SensorCollectionAppIcon`이 표시되고, compact trailing 심박 HUD는 10초 정책을 유지한다.
- 날씨 카드는 완성된 스냅샷과 미세먼지 값이 모두 있을 때만 표시하고, 핸들 왼쪽 compact 날씨 칩은 숨긴다.

최근 확인된 사실:

- 전체 `TaptionPlanTests` 732/732와 Swift Testing 10/10 통과, iOS generic Debug build 성공
- iPhone 14 Pro(`C44AF739-127D-572D-AD83-417C7E879045`)에 `com.taption.plan` `1.0 (106)` 설치·실행 및 PID readback 성공
- 시뮬레이터에서 현재 위치와 인천광역시청 핀을 겹쳐 졸라맨이 최전면에 남는 것을 확인했다.
- `git diff --check` 통과, 관련 변경은 main에 커밋·푸시했고 워크트리 clean을 확인했다.
- TestFlight build 106은 업로드·처리 완료(`VALID`, `APP_STORE_ELIGIBLE`) 후 `TP Taption Plan 내부 테스트` 그룹 연결·노출까지 확인했다. Delivery UUID `41dc832d-5a98-4a77-8122-aad743df6e28`.
- 2026-08-27 07:00~07:30 iPhone 앱 raw 센서 표본은 0건이며, 현재 raw 저장소의 최신 표본은 2026-08-25 22:17:35 KST다. HealthKit 원본 종료 시각은 별도 readback 경로가 없어 미확정이다.

다음 채팅에서 우선 확인할 항목:

1. 연결된 iPhone에서 Dynamic Island compact/expanded를 실제 센서 로깅 중 확인하고 앱 아이콘·심박·파형을 읽는다.
2. 재생을 시작해 전체 경로가 플레이헤드 시간에 따라 생성되는지, 사이드바를 움직일 때 졸라맨이 즉시 따라가는지 확인한다.
3. 현재 위치·핀치·지도 드래그·지하철 확정 경로·오늘 수면 분류를 실기기에서 확인한다.
4. `IAP73PAID1`은 Paid Apps Agreement·세금/은행·상품 연결·Sandbox 구매/복원 전까지 완료 처리하지 않는다.
5. 새 요청은 영문·숫자 10자리 ID로 `temp.md`에 먼저 기록하고 대표님의 `ㄱㄱ` 또는 `전체 진행` 승인 뒤 실행한다. 완료된 요청은 큐에서 제거한다.
