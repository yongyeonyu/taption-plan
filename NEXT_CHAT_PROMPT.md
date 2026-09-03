# Taption Plan 새 채팅 재개 프롬프트

대표님을 존댓말로 응대하고 `/Users/u_mo_c/Documents/taption plan`에서 작업한다. 시작 전에 `AGENTS.md`, `NEXT_CHAT_PROMPT.md`, `temp.md`, `test.md`를 읽고 live 상태를 확인한다.

```bash
git status --short --branch --untracked-files=all
git rev-parse HEAD origin/main
git ls-remote origin refs/heads/main
xcrun devicectl list devices
xcrun simctl list devices
```

`main`만 사용하고 임시 브랜치를 만들지 않는다. 새 요청은 10자리 영숫자 ID로 `temp.md`에 요청·원인·해결 방안을 기록하며, 대표님의 `ㄱㄱ`/`전체 진행` 뒤에만 실행한다. 하위 에이전트는 Luna만 사용하고 SOL·고속 모델은 사용하지 않는다. 소스/build, 자동 테스트, TestFlight 처리, 그룹 연결, 설치/readback, launch, 실제 화면·터치는 서로 다른 게이트로 보고한다.

## 현재 릴리스 정본

- 요청 ID: `TF903B013X`
- 배포 소스 SHA(바이너리): `1829efb1d02c7e81724787e5c787a9d4fff260a1`
- 앱·iOS Widget·Watch 앱·Watch Widget: `1.0 (130)`
- Release archive: `/private/tmp/TF903B013X-release/TaptionPlan-1.0-130.xcarchive`
- Export IPA: `/private/tmp/TF903B013X-release/Export/TaptionPlan.ipa`
- IPA SHA-256: `0904b72f68a00f32bd7cd29b48c027acfb4764c684d3696265b1fb1035218fa8`
- Delivery/build UUID: `064f2803-95d1-458b-96bc-819b087c13c9`
- App Store Connect App ID: `6797370230`
- Internal 그룹: `TP Taption Plan 내부 테스트`, ID `b4857e5e-d1ff-4bc2-b9ad-a69bcd4603fd`
- build 130은 App Store Connect API에서 `VALID`·`APP_STORE_ELIGIBLE`·`expired=false`, 내부 그룹 빌드 API에 포함, 전체 그룹 빌드 91개, 내부 테스터 1명(`INSTALLED`)으로 readback했다.

## 현재 검증·정리 상태

- `test.md`에 build 130 archive/export·서명·API readback과 전체 XCTest 902/902 증적이 있다.
- App Store Connect Chrome/in-app Browser의 build 130 그룹 빌드·테스터 화면은 로그인 화면으로 열려 UI readback이 미완료다. 계정 자격 증명을 대신 입력하지 않는다.
- iPhone 14 Pro의 마지막 확인 설치는 TestFlight build 128이다. iPad Pro는 앱 build 125이고 TestFlight `4.3.0 (659.1)`이 설치돼 있다. 양 기기의 build 129 다운로드·설치·launch는 남은 물리 게이트다.
- 오늘 수면 누락 원인은 HealthKit 연동 비활성화다. build 129는 오늘 수면이 없으면 `수면 연결` 버튼을 표시하며 실제 권한 승인·오늘 수면 재조회는 사용자 탭이 필요하다.
- 종료된 구형 Simulator 5대의 data는 삭제했고 iOS/watchOS 26.5 runtime은 보존했다. 현재 다른 작업이 iPad Simulator `2CD5BB05-7C63-4D44-A0B3-170F83F62210`에서 `WBS33GOAL1` XCTest를 실행 중이면 중단하거나 삭제하지 않는다.
- `/private/tmp` 정리 후 약 50G, 데이터 볼륨 여유 61GiB를 readback했다. `XCTestDevices`·Xcode `DerivedData`는 0B, Xcode `Archives`는 1.4G로 보존 중이다. REL release 증적과 활성 카메라 로그도 보존한다.

## 반드시 남은 게이트

1. 로그인된 App Store Connect Chrome에서 internal 그룹의 build 130 빌드 탭과 테스터 탭을 열어 UI 노출을 readback한다.
2. iPhone·iPad의 TestFlight에서 build 130을 다운로드·설치한 뒤 version/build readback과 launch, 날짜 변경 시 사이드바 대분류 유지 화면을 검증한다. iPhone에서 `수면 연결`을 탭해 수면 읽기 권한을 승인하고 오늘 수면 actual 생성·iCloud 재백업을 확인한다.
3. Apple Watch 실제 envelope 수신과 `수신 대기 → 최근 수신` 전환을 확인한다.
4. Paid Apps Agreement 활성화, `com.taption.plan.pro` 생성, sandbox 구매·복원을 확인한다.

완료된 `temp.md` 항목만 삭제하고 미완료 게이트는 남긴다. 문서 변경은 승인 파일만 stage하며 마지막에 `HEAD == origin/main == ls-remote main`, tracked/untracked clean을 확인한다.
