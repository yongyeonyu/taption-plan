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

- 요청 ID: `TF26PUSH01`
- 배포 소스 SHA(바이너리): `84448b8aa8fc7b9de35b2903561a90095c2bee62`
- 앱·iOS Widget·Watch 앱·Watch Widget: `1.0 (128)`
- Release archive: `/private/tmp/TF26PUSH01-release-r2/TaptionPlan-1.0-128.xcarchive`
- Export IPA: `/private/tmp/TF26PUSH01-release-r2/Export/TaptionPlan.ipa`
- IPA SHA-256: `b6532fc4be01c52a03fe1ef85f60b3bdb5156f77901cdd7483812834db9154e6`
- Delivery/build UUID: `3ce79d87-b2cd-429e-b988-816d0b9af84a`
- App Store Connect App ID: `6797370230`
- Internal 그룹: `TP Taption Plan 내부 테스트`, ID `b4857e5e-d1ff-4bc2-b9ad-a69bcd4603fd`
- build 128은 App Store Connect API에서 `VALID`·`APP_STORE_ELIGIBLE`·`expired=false`, 내부 그룹 빌드 API에 포함, 전체 그룹 빌드 89개, 내부 테스터 1명(`INSTALLED`)으로 readback했다.

## 현재 검증·정리 상태

- `test.md`에 build 128 archive/export·서명·API readback과 iPhone TestFlight 설치·launch 증적이 있다.
- App Store Connect Chrome/in-app Browser의 build 128 그룹 빌드·테스터 화면은 로그인 화면으로 열려 UI readback이 미완료다. 계정 자격 증명을 대신 입력하지 않는다.
- iPhone 14 Pro `C44AF739-127D-572D-AD83-417C7E879045`는 TestFlight build 128 `1.0 (128)` 설치·launch까지 완료했다. iPad Pro `4CEC6BE9-E528-52A1-AB94-654A6CDA7E5E`는 현재 `1.0 (125)`이며 TestFlight 앱이 없어 build 128 다운로드·설치·launch가 남아 있다. beta IPA의 CoreDevice 직접 설치는 `0xe800801f` entitlement 오류로 대체하지 않는다.
- 종료된 구형 Simulator 5대의 data는 삭제했고 iOS/watchOS 26.5 runtime은 보존했다. 현재 다른 작업이 iPad Simulator `2CD5BB05-7C63-4D44-A0B3-170F83F62210`에서 `WBS33GOAL1` XCTest를 실행 중이면 중단하거나 삭제하지 않는다.
- `/private/tmp` 정리 후 약 50G, 데이터 볼륨 여유 61GiB를 readback했다. `XCTestDevices`·Xcode `DerivedData`는 0B, Xcode `Archives`는 1.4G로 보존 중이다. REL release 증적과 활성 카메라 로그도 보존한다.

## 반드시 남은 게이트

1. 로그인된 App Store Connect Chrome에서 internal 그룹의 build 128 빌드 탭과 테스터 탭을 열어 UI 노출을 readback한다. 기존 `REL902A001` build 126 UI 게이트도 `temp.md` 기록대로 유지한다.
2. iPad에 TestFlight를 설치하고 `TP Taption Plan 내부 테스트`의 build 128을 다운로드·설치한 뒤 `1.0 (128)` version/build readback과 launch를 별도로 검증한다. 이후 iPhone·iPad에서 실제 지도 터치와 재생선/점선 정합을 검증한다.
3. Apple Watch 실제 envelope 수신과 `수신 대기 → 최근 수신` 전환을 확인한다.
4. Paid Apps Agreement 활성화, `com.taption.plan.pro` 생성, sandbox 구매·복원을 확인한다.

완료된 `temp.md` 항목만 삭제하고 미완료 게이트는 남긴다. 문서 변경은 승인 파일만 stage하며 마지막에 `HEAD == origin/main == ls-remote main`, tracked/untracked clean을 확인한다.
