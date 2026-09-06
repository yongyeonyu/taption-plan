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

- 기준 소스 커밋: `f6386798a84239167fef1c52789cf0d33ee5f829` (`SUB906F001`, 지하철 오탐 수정과 build 138 배포 문서 포함).
- TestFlight 정본: 앱·iOS Widget·Watch 앱·Watch Widget `1.0 (138)`, archive `/private/tmp/SUB906F001-release/TaptionPlan-1.0-138.xcarchive`, IPA `/private/tmp/SUB906F001-release/Export/TaptionPlan.ipa`.
- IPA SHA-256: `9fa557d536c6002294abf2a3435c54f0c8742df533577f69d411f467eb9a36f7`.
- Delivery/build UUID: `9caa4563-2a99-4b1a-ab58-c5b4a74b663c`. App Store Connect App ID: `6797370230`.
- build 138은 API에서 `VALID`·`APP_STORE_ELIGIBLE`·`expired=false`; `TP Taption Plan 내부 테스트`(ID `b4857e5e-d1ff-4bc2-b9ad-a69bcd4603fd`)의 그룹 빌드 관계에 포함된다. 그룹 테스터는 1명(`INSTALLED`)이지만 해당 build 138의 TestFlight 클라이언트 설치 증거로 간주하지 않는다.

## 완료된 최신 구현: 졸라맨 화면 중앙 포커싱

- 문서 분석 ID: `DOC906U001`. [DEVELOPMENT.md](/Users/u_mo_c/Documents/taption%20plan/DEVELOPMENT.md)에 원인을 기록했다.
- 현재 위치 버튼 경로는 `requestAndFollowUserLocation` → `focusUserLocation` → `requestAppleMapCenter` → `MapHomeAppleCameraCommand.center`다.
- 원인은 `TaptionPlan/UI/MapHomeView.swift`의 `MapHomeCameraLayoutMath.targetPoint`가 `x = max(0, sidebarLeft) / 2`를 사용하고, `sidebarLeft = mapViewportSize.width - sidebarInteractionWidth`로 계산되는 것이다. 즉 화면 전체 중심이 아니라 우측 시간 사이드바를 제외한 왼쪽 영역 중심을 목표로 하므로 졸라맨이 왼쪽에 치우친다. `isMapCenteredOnUser`도 같은 목표점을 사용한다.
- `NXT906P002`에서 target point x를 화면 중앙(`viewportSize.width / 2`)으로 통일하고, y의 검색창 아래 여백과 camera center 변환은 유지했다. 미사용 `sidebarLeftX`만 제거했다.
- 수학·현재 위치 camera command·버튼 상태 회귀 3/3과 Simulator Debug build·launch를 통과했다. 실제 손가락 터치, 물리 iPhone 설치·launch와 TestFlight client는 별도 게이트다.

## 남은 외부 게이트

1. iPhone이 연결되면 TestFlight build 138 클라이언트 설치 provenance·버전·launch를 각각 readback하고, 현재 위치 버튼/졸라맨 중앙 정렬을 실제 화면에서 확인한다. 현재 마지막 확인에서는 iPhone·Watch·iPad가 모두 `unavailable`이었다.
2. 실제 두 손가락 pinch, 장시간 발열·배터리, 날짜 전환 체감, Watch 원본 수신·수면, 지하철 오탐 재현, 공백 예상경로, VoiceOver는 코드·시뮬레이터 통과와 분리한다.
3. iCloud 앱 복원·merge, 실제 Apple/Google/Naver 일정, Paid Apps Agreement·첫 IAP·sandbox/TestFlight 구매/복원은 외부 계정 게이트다.

## 검증·배포 규칙

- 관련 단위 테스트와 Debug 빌드를 먼저 실행한다. 실패·스킵·경고를 PASS로 합치지 않는다.
- TestFlight는 archive/export → `altool --validate-app` → upload/processing → Internal 그룹 연결 → 그룹 build/tester API readback 순서로 확인한다. 물리 설치·실행은 별도 보고한다.
- 작업 종료 시 `git diff --check`, `git status --short --branch`, `HEAD == origin/main == ls-remote main`을 확인하고, 요청하지 않은 UI/UX·파일은 변경하지 않는다.
