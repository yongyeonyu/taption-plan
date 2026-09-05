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

- 요청 ID: `REL905H011`
- 배포 소스 SHA(바이너리): `a6e770f64491e97896136a1b7692620bf6c0c62b`
- 앱·iOS Widget·Watch 앱·Watch Widget: `1.0 (137)`
- Release archive: `/private/tmp/REL905H011-release.nFPbOf/TaptionPlan-1.0-137.xcarchive`
- Export IPA: `/private/tmp/REL905H011-release.nFPbOf/Export/TaptionPlan.ipa`
- IPA SHA-256: `18e5516b30726c1ba7862907062c7421ef743fff7f12165bf0e40f0b0a07d405`
- Delivery/build UUID: `1b26a479-4bd6-49df-bda2-2f1bf1f0d28a`
- App Store Connect App ID: `6797370230`
- Internal 그룹: `TP Taption Plan 내부 테스트`, ID `b4857e5e-d1ff-4bc2-b9ad-a69bcd4603fd`
- build 137은 App Store Connect에서 `VALID`·`expired=false`·`APP_STORE_ELIGIBLE`이며 Internal 그룹 추가 후 그룹 빌드 API에 포함, 그룹 빌드 98개와 내부 테스터 1명 `INSTALLED`로 readback했다.

## 현재 검증·정리 상태

- `test.md`에 snapshot 실패 raw 롤백 집중 회귀 1/1, 보안·백업 50/50, 전체 앱 1,027건 중 1,026 passed·1 skipped·0 failed와 build 137 archive/export·서명·업로드·API readback 증적이 있다. skip은 iOS 26.5 Simulator의 StoreKit 시스템 오류로 한정된다.
- 실제 iCloud 2026-09 일반·raw 센서 백업은 JSON v1 구조와 암호문 SHA-256 digest 일치를 확인했다. PIN 복호화·적용 readback은 아직 실기기에서 확인하지 않았다.
- iPad Pro에는 개발자 서명 `1.0 (134)`를 설치·버전 readback했지만 기기 잠금으로 launch가 거부됐다. TestFlight 클라이언트 build 137 설치·실행은 아직 물리 검증하지 않았다.
- `com.taption.plan.pro`는 비소모성 `READY_TO_SUBMIT`, 미국 `USD 9.99`, 한국·미국 포함 175개 지역, 한국어·영어 현지화와 심사 이미지 `COMPLETE`다. Paid Apps Agreement와 앱 버전 상품 연결은 브라우저 재인증이 필요하다.
- build 137 archive·IPA·검증·업로드/API 증적은 `/private/tmp/REL905H011-release.nFPbOf`에, XCTest 증적은 `/private/tmp/BAK905H010-focused.K2HmMB`에 보존한다. 재생성 가능한 DerivedData와 IPA 압축 해제본만 제거한다.

## 반드시 남은 게이트

1. iPhone·iPad TestFlight에서 build 137을 다운로드·설치한 뒤 version/build readback과 launch, 실행 속도·장시간 발열/배터리, 두 손가락 pinch, 날짜 변경 시 사이드바 대분류 유지 화면을 검증한다.
2. iPhone/Apple Watch 실제 원본 수신과 `수신 대기 → 최근 수신`, 비이동 졸라맨 정지, 수면·지하철·공백 예상경로 진단 로그를 확인한다.
3. iCloud 일반·raw 백업을 PIN으로 실제 복호화·적용하고 Apple·Google·Naver 실제 계정 일정 readback, Paid Apps Agreement 활성화, 앱 버전의 `com.taption.plan.pro` 연결, sandbox/TestFlight 구매·복원을 확인한다.

완료된 `temp.md` 항목만 삭제하고 미완료 게이트는 남긴다. 문서 변경은 승인 파일만 stage하며 마지막에 `HEAD == origin/main == ls-remote main`, tracked/untracked clean을 확인한다.
