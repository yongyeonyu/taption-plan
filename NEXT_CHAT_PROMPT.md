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

- 요청 ID: `TFB904A133`
- 기능 소스 SHA: `8d041e9284d8393cbbf1157cf2b795c1cb6b51cf`
- 배포 소스 SHA(바이너리): `3930b808c86f20b003e474c56846252156303b41`
- 앱·iOS Widget·Watch 앱·Watch Widget: `1.0 (133)`
- Release archive: `/private/tmp/TFB904A133-release/TaptionPlan-1.0-133.xcarchive`
- Export IPA: `/private/tmp/TFB904A133-release/Export/TaptionPlan.ipa`
- IPA SHA-256: `422bcb43a8822b7eac2ff7935471acecddd5a46c2ade6a506ccf6cebdda92f4a`
- Delivery/build UUID: `bc2b0f81-83f2-4001-80f2-19707a1b1fcc`
- App Store Connect App ID: `6797370230`
- Internal 그룹: `TP Taption Plan 내부 테스트`, ID `b4857e5e-d1ff-4bc2-b9ad-a69bcd4603fd`
- build 133은 App Store Connect API에서 `VALID`·`APP_STORE_ELIGIBLE`·`expired=false`, 내부 그룹 빌드 API에 포함, 전체 그룹 빌드 94개, 내부 테스터 1명(`INSTALLED`)으로 readback했다.

## 현재 검증·정리 상태

- `test.md`에 build 133 집중 테스트·archive/export·서명·업로드·API/Chrome readback 증적이 있다.
- Chrome의 Internal 그룹 빌드 화면에서 build `1.0 (133) · 테스트 중 · iOS`, 테스터 화면에서 내부 테스터 1명과 그룹 build 94개를 확인했다.
- 테스터 화면의 마지막 설치 표시는 TestFlight build 132다. iPad Pro의 마지막 별도 readback은 앱 build 125이고 TestFlight `4.3.0 (659.1)`이 설치돼 있다. build 133 다운로드·설치·launch·실제 발열은 남은 물리 게이트다.
- 오늘 수면 누락 원인은 HealthKit 연동 비활성화다. build 129는 오늘 수면이 없으면 `수면 연결` 버튼을 표시하며 실제 권한 승인·오늘 수면 재조회는 사용자 탭이 필요하다.
- 종료된 구형 Simulator 5대의 data는 삭제했고 iOS/watchOS 26.5 runtime은 보존했다. 현재 다른 작업이 iPad Simulator `2CD5BB05-7C63-4D44-A0B3-170F83F62210`에서 `WBS33GOAL1` XCTest를 실행 중이면 중단하거나 삭제하지 않는다.
- build 133 배포 중 재생성 가능한 성능 검증·build 132·build 133 DerivedData 약 3.2G를 영구 삭제했고 당시 데이터 볼륨 여유 약 8.9GiB를 확인했다. build 132/133 archive·IPA, build 133 XCTest 결과와 다른 작업의 활성 산출물은 보존했다.

## 반드시 남은 게이트

1. iPhone·iPad의 TestFlight에서 build 133을 다운로드·설치한 뒤 version/build readback과 launch, 실행 속도·발열, Watch 설정 위치·비이동 졸라맨 정지·날짜 변경 시 사이드바 대분류 유지 화면을 검증한다. 지하철 이동과 수면 권한·조회 뒤 iCloud 로그를 올려 이동 판정·예상경로·HealthKit 이벤트를 확인한다.
2. Apple Watch 실제 envelope 수신과 `수신 대기 → 최근 수신` 전환을 확인한다.
3. Paid Apps Agreement 활성화, `com.taption.plan.pro` 생성, sandbox 구매·복원을 확인한다.

완료된 `temp.md` 항목만 삭제하고 미완료 게이트는 남긴다. 문서 변경은 승인 파일만 stage하며 마지막에 `HEAD == origin/main == ls-remote main`, tracked/untracked clean을 확인한다.
