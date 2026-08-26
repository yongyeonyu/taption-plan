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

현재 기준 커밋은 문서 갱신 커밋 `2fa6a7c`이며 `main`과 `origin/main`이 일치해야 한다. 기능 변경 기준 커밋은 `5bcd766`이다. 최근 변경은 다음과 같다.

- `Packages/TaptionPlanCore`: 일자 단위 SQLite 저장소와 generation 기반 60Hz NLE 입력 예산
- `Packages/TaptionActivityEngine`: 센서 근거 활동 taxonomy와 자동 분류 결과 잠금
- `Packages/TaptionRouteEngine`: GPS 정확도·점프·공백 필터, 2D Kalman, RDP 표시 축약
- 앱은 로컬 스냅샷·일자 데이터를 먼저 hydrate하고 사이드바·경로·지도 파생값을 캐시한다.
- 현재·과거 위치는 장소 아이콘보다 앞의 native annotation 졸라맨으로 표시한다. 추적 중 선택 시각 위치를 중앙에 유지하고 지도 이동은 추적을 해제한다.
- 지하철 확정 선로 경로·수면·이동 분류는 원본 센서를 보존한 채 저장 후 유지한다. 예상·점선 경로 오버레이는 비활성화되어 있다.
- 재생 시작 시 경로 투영을 비우고 원본 읽기를 다시 준비한다. 재생 중 플레이헤드가 움직일 때 경로와 졸라맨 위치를 갱신하며, 표시 경로는 플레이헤드 시각까지 생성한다.
- GPS·센서 수집 간격은 슬라이더 설정을 사용한다.
- Dynamic Island 확장형은 전체 폭 우→좌 파형·센서 저장 ECG 1회 펄스·1초 2px 점멸점을 사용한다. 센서 Live Activity의 확장형 leading과 수집 중 compact leading에는 `SensorCollectionAppIcon`이 표시되고, compact trailing 심박 HUD는 10초 정책을 유지한다.
- 날씨 카드는 완성된 스냅샷과 미세먼지 값이 모두 있을 때만 표시하고, 핸들 왼쪽 compact 날씨 칩은 숨긴다.

최근 확인된 사실:

- `TaptionPlanWidget` Debug 시뮬레이터 빌드 성공
- 서명된 iPhone Debug 빌드 `1.0 (102)` 성공
- iPhone 14 Pro(`C44AF739-127D-572D-AD83-417C7E879045`)에 `com.taption.plan` 설치·실행 성공
- `git diff --check` 통과, 워크트리 clean
- TestFlight build 102는 기존 IPA 검증·업로드·처리 완료(`VALID`, `APP_STORE_ELIGIBLE`) 및 `TP Taption Plan 내부 테스트` 노출 확인. Delivery UUID `9bec24ce-e0da-4868-8398-5c75e8b3421b`.
- 이번 아이콘·재생 수정 커밋은 TestFlight에 새로 업로드하지 않았다. 새 배포 요청이면 archive/export·업로드·처리·그룹 연결·노출을 각각 확인한다.
- 테스트/릴리스 증거와 공유 시뮬레이터 데이터는 보존했고, 재생성 가능한 오래된 Taption Plan 캐시와 실기기 임시 빌드는 정리했다.

다음 채팅에서 우선 확인할 항목:

1. 연결된 iPhone에서 Dynamic Island compact/expanded를 실제 센서 로깅 중 확인하고 앱 아이콘·심박·파형을 읽는다.
2. 재생을 시작해 전체 경로가 플레이헤드 시간에 따라 생성되는지, 사이드바를 움직일 때 졸라맨이 즉시 따라가는지 확인한다.
3. 현재 위치·핀치·지도 드래그·지하철 확정 경로·오늘 수면 분류를 실기기에서 확인한다.
4. `IAP73PAID1`은 Paid Apps Agreement·세금/은행·상품 연결·Sandbox 구매/복원 전까지 완료 처리하지 않는다.
5. 새 요청은 영문·숫자 10자리 ID로 `temp.md`에 먼저 기록하고 대표님의 `ㄱㄱ` 또는 `전체 진행` 승인 뒤 실행한다. 완료된 요청은 큐에서 제거한다.
