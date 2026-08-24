# Taption Plan 다음 채팅 핸드오프

아래 내용을 새 채팅에 그대로 붙여넣고 작업을 이어가세요.

```text
작업 디렉토리: /Users/u_mo_c/Documents/taption plan
먼저 AGENTS.md를 읽고 main 최신 SHA와 git status를 확인한다.

현재 기준
- 현재 main에는 사용자 추가 지하철역·지하철 Wi-Fi 우선 판정, GPS 1초·10초·30초 기록, 지도 상세도·팝업·시간 레일 개선, 광고 완전 제거, C2 고양이 벡터 앱 아이콘이 반영되어 있다.
- `BATCH2WK01`로 지도 오버레이 핀치 전달·위치 추가 취소·저장 위치 이동/편집·사용자 위치 관리 UI·실제 헤딩 나침반·선택 날씨 배경을 통합했고 CloudKit 비공개 복구 백업의 아카이브 키 래핑을 보정했다.
- Pro는 Keychain+iCloud KVS 기반 14일 앱 자체 체험과 StoreKit 2 비소모성 `com.taption.plan.pro` 영구 구매·복원으로 구현했다. 기존 기록도 `startedAt` 기준 14일로 재계산하며, 체험 만료 시 전체 앱과 백그라운드 작업을 잠근다.
- 최신 main SHA와 `git status`를 먼저 확인한다. 현재 통합에는 GPS·센서 1초 고정, 필수 권한 게이트, MKDirections 예상 경로, 현재위치 추적 해제, 팬토그래픽 과거 위치 마커, 중앙 몸통·발·수염 고양이 스플래시가 포함돼 있다.
- 전체 XCTest 636/636, iOS Debug build, `git diff --check`를 통과했다.
- 연결된 iPhone 14 Pro에 `com.taption.plan` `1.0 (88)`을 설치·실행했고 프로세스 `TaptionPlan` PID `49149`를 readback했다.
- build 88 TestFlight archive/upload는 아직 수행하지 않았다. 이전 build 77 TestFlight Delivery UUID는 f962c2b8-f430-44e0-88a8-0a00b7b489c4이며 VALID/제출 준비 완료 상태였고 내부 그룹 노출까지 확인했다.

남은 외부 게이트
- App Store Connect Paid Apps Agreement가 `신규` 상태다. 계정 소유자가 법인 정보와 계약·세금·은행 정보를 완료해야 실제 US$0.99 상품을 생성할 수 있다.
- 계약 완료 후 App Store Connect에 비소모성 상품 ID `com.taption.plan.pro`, 가격 US$0.99, 한국어·영어 현지화를 만들고 TestFlight에서 구매·복원을 검증한다.

주의
- TestFlight 업로드 성공, 처리 VALID, 내부 그룹 연결·노출은 서로 다른 게이트로 계속 확인한다.
- 원본 센서·HealthKit 데이터는 삭제·수정하지 않는다.
- StoreKit 상품이 생성되기 전에는 TestFlight 구매 버튼 성공을 완료로 보고하지 않는다.
- 새 요청은 temp.md에 10자리 ID로 등록하고 대표님의 `ㄱㄱ` 후 실행한다.

2026-08-24 코드뷰 후속 UI 통합
- `MPRV8X2K1A`로 검색 결과 영역을 행 높이 48pt·최대 320pt로 제한해 검색창 밖의 지도 탭·팬·줌을 다시 사용할 수 있게 했다.
- `WTHANDL001`로 날씨 사이드바 OFF 상태의 날씨 캡슐을 플레이헤드 핸들과 같은 높이에 맞추고 왼쪽 4pt 간격을 유지한다.
- 전체 XCTest 578/578, iOS Simulator Debug, 서명된 iPhone Debug build와 `git diff --check`를 통과했다.

2026-08-25 통합 후속
- GPS 및 센서는 필수·실시간 1초 기록으로 고정되며, `RequiredPermissionGate`가 모든 필수 권한을 확인하기 전에는 기록 화면을 열지 않는다.
- 확정 지하철 경로는 저장된 노선 경로를 유지하고, 그 밖의 이동 구간은 자동차·대중교통·도보별 `MKDirections` 예상 경로를 지도에 표시한다. 예상 경로는 표시 전용이며 원본 GPS와 사용자 분류를 변경하지 않는다.
- 사이드바를 움직이거나 지도를 한 손가락으로 드래그하면 현재위치 추적을 해제하고, 현재위치 버튼을 다시 누를 때만 추적을 재개한다.
- 새 시작 화면 자산은 `TaptionPlanLaunchCat.svg` 기반이며 몸통·앞발·뒷발·수염, 기존 여정 꼬리, 중앙 배치를 사용한다. 네이티브 시작 화면과 SwiftUI 오버레이는 각각 불투명·투명 자산을 사용한다.
- 새 요청은 10자리 영문·숫자 ID로 `temp.md`에 등록하고 대표님의 `ㄱㄱ` 후 실행한다.
```
