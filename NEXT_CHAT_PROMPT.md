# Taption Plan 새 채팅 재개 프롬프트

대표님을 존댓말로 응대하고 `/Users/u_mo_c/Documents/taption plan`에서 작업한다. 새 채팅 시작 시 아래 파일과 live 상태를 먼저 읽는다.

```bash
cd "/Users/u_mo_c/Documents/taption plan"
sed -n '1,240p' AGENTS.md
sed -n '1,240p' NEXT_CHAT_PROMPT.md
sed -n '1,240p' temp.md
sed -n '1,240p' test.md
git status --short --branch --untracked-files=all
git rev-parse HEAD origin/main
git ls-remote origin refs/heads/main
xcrun devicectl list devices
xcrun simctl list devices
```

`main`만 사용하고 임시 브랜치를 만들지 않는다. 새 요청은 10자리 영숫자 ID로 `temp.md`에 요청·원인·해결 방안을 기록한다. 대표님의 `ㄱㄱ`/`전체 진행` 뒤에 실행하고, 완료한 항목만 삭제한다. 소스/build, 자동 테스트, TestFlight 처리, Internal 그룹 연결, 설치/readback, launch, 실제 화면·터치는 서로 다른 게이트로 보고한다. 비밀값은 출력·문서화하지 않는다.

## 현재 기준

- `WAK907A001`에서 Apple·Vector 졸라맨 발끝 anchor를 선택 시각의 경로 좌표로 통일했다. 집중 회귀 1/1과 Simulator Debug build를 통과했으며 이 변경은 build 140 TestFlight 이후 소스다.
- 최신 작업 소스는 build 140이며 `TaptionCommercePolicy.supportsPaidPurchase=false`로 구매를 임시 비활성화했다. 만료 체험과 무관하게 앱·백그라운드·Watch 접근을 허용하며 구매 UI·상품 로드·구매·복원 호출은 막힌다.
- TestFlight 정본: 앱·iOS Widget·Watch 앱·Watch Widget `1.0 (140)`, archive `/private/tmp/IAP907B001.jpbHS0/TaptionPlan.xcarchive`, IPA `/private/tmp/IAP907B001.jpbHS0/Export/TaptionPlan.ipa`.
- IPA SHA-256: `ebf0161b10decb17765eda07f2dea6d3b304320ab79fea57cf103c14bdbf5147`.
- Delivery/build UUID: `c871d1f4-e933-411d-b840-0d59af3ba6be`. App Store Connect App ID: `6797370230`.
- build 140은 upload `COMPLETE`, build `VALID`·`expired=false`; `TP Taption Plan 내부 테스트`(ID `b4857e5e-d1ff-4bc2-b9ad-a69bcd4603fd`) 그룹에 포함되고 내부 테스터 1명은 `INSTALLED`다.
- build 140 TestFlight 클라이언트 설치·launch·구매 UI 비노출·실제 기능 접근은 별도 물리 게이트다. 판매 재개 시 Paid Apps Agreement와 첫 IAP 연결 완료 후 정책 스위치를 true로 복구한다.
- 최신 Apple Development Debug `1.0 (138)`은 iPhone 설치·`builtByDeveloper=true`·launch PID `16713`까지 readback했다: `/private/tmp/DEV906I001-apps.json`, `/private/tmp/DEV906I001-launch.json`.

## 완료된 최신 구현: 등록 장소 좌표 표시

- `PIN906A001`에서 등록 장소 카드 하단을 좌표에 붙이던 Apple 69pt offset과 Vector bottom anchor를 제거했다.
- Apple·Vector 지도 모두 등록 장소 아이콘 중심이 저장 좌표에 일치한다. 관련 회귀 2/2와 Simulator Debug build·설치·launch PID `17961`을 통과했다: `/private/tmp/PIN906A001-focused-r2.xcresult`.
- 실제 축소 화면의 손가락 확인은 물리 iPhone 게이트다.

## 완료된 최신 구현: 현재 위치 단일 포커싱

- `LOC906F001`에서 현재 위치 버튼이 캐시 좌표로 먼저 이동한 뒤 새 GPS로 다시 이동하던 순서를 제거했다.
- 버튼 탭은 새 표본 저장을 기다리며 `locating` 중 위치 콜백은 카메라를 움직이지 않는다. 새 표본이 확인된 뒤 한 번만 포커싱하고, 시간 초과면 기존 좌표로 이동하지 않는다.
- 집중 회귀 1/1과 Simulator Debug build·설치·launch PID `13086`을 통과했다: `/private/tmp/LOC906F001-focused-r3.xcresult`. 실제 손가락·GPS는 물리 게이트다.

## 완료된 최신 구현: 졸라맨 화면 중앙 포커싱

- 문서 분석 ID: `DOC906U001`. [DEVELOPMENT.md](/Users/u_mo_c/Documents/taption%20plan/DEVELOPMENT.md)에 원인을 기록했다.
- 현재 위치 버튼 경로는 `requestAndFollowUserLocation` → `focusUserLocation` → `requestAppleMapCenter` → `MapHomeAppleCameraCommand.center`다.
- 원인은 `TaptionPlan/UI/MapHomeView.swift`의 `MapHomeCameraLayoutMath.targetPoint`가 `x = max(0, sidebarLeft) / 2`를 사용하고, `sidebarLeft = mapViewportSize.width - sidebarInteractionWidth`로 계산되는 것이다. 즉 화면 전체 중심이 아니라 우측 시간 사이드바를 제외한 왼쪽 영역 중심을 목표로 하므로 졸라맨이 왼쪽에 치우친다. `isMapCenteredOnUser`도 같은 목표점을 사용한다.
- `NXT906P002`에서 target point x를 화면 중앙(`viewportSize.width / 2`)으로 통일하고, y의 검색창 아래 여백과 camera center 변환은 유지했다. 미사용 `sidebarLeftX`만 제거했다.
- 수학·현재 위치 camera command·버튼 상태 회귀 3/3과 Simulator Debug build·launch를 통과했다. 실제 손가락 터치, 물리 iPhone 설치·launch와 TestFlight client는 별도 게이트다.

## 완료된 최신 구현: 00:17 자동차 기록의 지하철 오탐

- 요청 ID는 `SUB906R001`. 00:17 당시 물리 앱은 build 137이었고, 동일 날짜 진단은 철도·역 이름·대중교통·승차 후보·노선이 모두 0인데 재투영 뒤 지하철 1건과 잠금 5건을 남겼다.
- `TravelModeClassifier`의 역 주변 상대고도 하강 점수는 역 인접만으로 허용하지 않고 반복 철도 일치·좌표 궤적·역 상태·사용자 노선 중 하나가 확인될 때만 적용한다.
- 관련 회귀 4/4와 Simulator Debug build·설치·launch PID `5406`을 통과했다: `/private/tmp/SUB906R001-focused-r4.xcresult`.
- 최신 Apple Development Debug `1.0 (138)`은 iPhone 설치·`builtByDeveloper=true`·launch PID `16511`까지 readback했다. 실제 자동차 이동 재현과 TestFlight 배포·클라이언트 설치는 별도 게이트다.

## 남은 외부 게이트

1. TestFlight build 138 클라이언트 설치 provenance·버전·launch를 각각 readback하고, 현재 위치 버튼/졸라맨 중앙 정렬을 실제 화면에서 확인한다. 최신 개발자 앱 `1.0 (138)` 설치·launch는 통과했지만 TestFlight 증거가 아니다.
2. 실제 두 손가락 pinch, 장시간 발열·배터리, 날짜 전환 체감, Watch 원본 수신·수면, 지하철 오탐 재현, 공백 예상경로, VoiceOver는 코드·시뮬레이터 통과와 분리한다.
3. iCloud 앱 복원·merge, 실제 Apple/Google/Naver 일정, Paid Apps Agreement·첫 IAP·sandbox/TestFlight 구매/복원은 외부 계정 게이트다.

## 검증·배포 규칙

- 관련 단위 테스트와 Debug 빌드를 먼저 실행한다. 실패·스킵·경고를 PASS로 합치지 않는다.
- TestFlight는 archive/export → `altool --validate-app` → upload/processing → Internal 그룹 연결 → 그룹 build/tester API readback 순서로 확인한다. 물리 설치·실행은 별도 보고한다.
- 작업 종료 시 `git diff --check`, `git status --short --branch`, `HEAD == origin/main == ls-remote main`을 확인하고, 요청하지 않은 UI/UX·파일은 변경하지 않는다.
