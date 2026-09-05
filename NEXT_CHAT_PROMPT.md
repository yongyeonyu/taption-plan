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
- 실제 iCloud 2026-08·09 일반·raw 백업은 계정 복구 키로 AES-GCM key unwrap·payload decrypt·LZFSE 해제·JSON v1·월/generation 쌍까지 확인했다: `/private/tmp/BAK905I001-live.5vfwUn/live-backup-readback.log`. 앱 UI의 실제 복원 적용·merge readback은 아직 실기기에서 확인하지 않았다.
- iPad Pro에는 개발자 서명 `1.0 (134)`를 설치·버전 readback했지만 기기 잠금으로 launch가 거부됐다. TestFlight 클라이언트 build 137 설치·실행은 아직 물리 검증하지 않았다.
- App Store version `1.0`에 build 137을 연결했고 한국어 설명·키워드·부제·공개 지원/개인정보/개인정보 선택 URL·저작권·카테고리와 175개 지역 연령등급을 API readback했다. 증적은 `/private/tmp/IAP905G002-api.3i778W`다.
- `com.taption.plan.pro`는 비소모성 `READY_TO_SUBMIT`, 미국 `USD 9.99`, 한국·미국 포함 175개 지역, 한국어·영어 현지화와 심사 이미지 `COMPLETE`다. iPhone 6.7형 앱 스크린샷 2장도 asset `COMPLETE`·세트 2건을 API로 readback했다. 첫 IAP 웹 추가, Paid Apps Agreement, 심사 연락처·판매 지역·개인정보 수집 답변·DSA/비규제 의료기기 선언은 남아 있다.
- build 137 archive·IPA·검증·업로드/API 증적은 `/private/tmp/REL905H011-release.nFPbOf`에, XCTest 증적은 `/private/tmp/BAK905H010-focused.K2HmMB`에 보존한다. 재생성 가능한 DerivedData와 IPA 압축 해제본만 제거한다.
- 최신 ALG904A001 소스는 활동 융합·경로 공백·센서 cache·HealthKit 수면·Watch receipt/raw 재시도·지도 POI cancellation/deletion fence를 보강했다. Package 86/86, 집중 7/7, 전체 앱 1,031건 중 1,030 passed·기존 StoreKit 시스템 skip 1·failed 0, generic iOS·watchOS Debug와 static analyze를 통과했다. 보안 diff scan 17/17 coverage `complete`, 보고 대상 0건이다.
- 최신 시뮬레이터는 설치·launch 뒤 안정화 CPU 5회 `0.0%`, RSS 약 `183.5MiB`였다. 증적은 `/private/tmp/ALG904A001-app-r3.9gBYjO`, `/private/tmp/ALG904A001-full-r2.ByyHu3`, `/private/tmp/ALG904A001-build-r1.TPiSR6` 및 `/private/var/folders/q1/0p9tcvnx7yx5l12y55zm4tdm0000gn/T/codex-security-scans-jOiTAE/taption-plan/af7352832651ca69d5863cff8dc36b0c8d2dbdc0_20260905T162732Z_ehr2iwgg/report.md`다.

## 반드시 남은 게이트

1. iPhone·iPad TestFlight에서 build 137을 다운로드·설치한 뒤 version/build readback과 launch, 실행 속도·장시간 발열/배터리, 두 손가락 pinch, 날짜 변경 시 사이드바 대분류 유지 화면을 검증한다.
2. iPhone/Apple Watch 실제 원본 수신과 `수신 대기 → 최근 수신`, 비이동 졸라맨 정지, 수면·지하철·공백 예상경로 진단 로그 및 장시간 발열·배터리를 확인한다.
3. iCloud 일반·raw 백업을 앱에서 실제 복원·merge하고 Apple·Google·Naver 실제 계정 일정 readback, Paid Apps Agreement 활성화, 앱 버전에 첫 IAP를 웹으로 추가하고 sandbox/TestFlight 구매·복원을 확인한다.
4. 개인정보 수집 답변·판매 지역·심사 연락처·DSA/비규제 의료기기 선언을 확정한다.

완료된 `temp.md` 항목만 삭제하고 미완료 게이트는 남긴다. 문서 변경은 승인 파일만 stage하며 마지막에 `HEAD == origin/main == ls-remote main`, tracked/untracked clean을 확인한다.
