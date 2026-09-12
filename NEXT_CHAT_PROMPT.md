# Taption Plan 새 채팅 재개 프롬프트

## 최신 상태 · TP0913D001 / TestFlight 148 배포 완료

- 금요일 원본 재조회 수정(f5d99c2)과 백업 Date JSON 왕복 동등성 수정을 소스 `03365a4`·1.0(148)에 통합해 main push했다. 실제 충돌 차단은 유지하며 충돌 진단은 기록 타입만 남긴다. 사용자 원본/백업·키/PIN은 변경하지 않았다.
- 최신 147 로그 `TaptionLogs-20260913-005952.txt`에서 raw 포함 백업 실패 종료가 확인됐다. 날짜 정밀도 결함은 코드로 재현했지만 실제 기기의 정확한 실패 단계는 아직 미확정이다. 아래의 종료 로그 미확인 안내는 과거 상태다.
- 최종 전체 회귀 1,105 PASS·기존 StoreKit 1 SKIP·0 FAIL, Debug·archive/export·Apple 검증/업로드 PASS. 148 `VALID` 및 Internal API 연결, 웹 그룹의 `1.0 (148) 테스트 중`·테스터 1명 노출까지 확인했다. Delivery UUID `eb429725-dd18-4a40-a21e-123cac2fbcf0`. 증거는 test.md의 TP0913D001과 build/validation/TP0913D001.
- 웹 테스터 설치 표시는 147이며 148 클라이언트 설치/실제 복구는 미확인이다. iPhone/iPad/Watch는 unavailable. 아래 이전 버전의 미배포/웹 미확인 문구는 과거 기록이며, 최신 148을 다시 빌드하지 말고 실기기 설치 후 금요일 GPS·백업/복원·복귀 안정성을 확인한다.
- main만 사용, 공유 Xcode lock 준수. 금요일 화면 복구·iCloud 백업/복원·복귀 안정성은 최신 TestFlight 설치와 새 기기 로그로 확인한다. 구매 잠금 해제 유지, 계약·심사·유료화 제외.

## 2026-09-13 TP0913C001 / TP0913C002 · 금요일 기록·백업 오류

- 147 기기 로그 `TaptionLogs-20260913-002628.txt`에서 금요일 원본 GPS 1,687건과 지도 캐시 57건 불일치를 확인했다. 지도 날짜 변경의 선택일 갱신 누락, preview 후 primary 원본 재조회, 로딩 중 source 변경 시 화면 반영 직전 동기 1회 재투영을 수정했다. 최종 회귀 56/56 PASS·0 FAIL·0 SKIP, Debug generic iOS PASS. 증거는 test.md와 build/validation/TP0913C001.
- 이 수정은 147 배포 이후 소스 변경이며 아직 TestFlight 미배포다. 147 API Internal 연결 상태와 이 수정의 설치/실제 금요일 화면 복구를 혼동하지 않는다.
- 백업 파일 2개는 JSON/외부 digest가 정상이나 최신 수동 백업의 종료 로그가 없다. 대표님에게 오류창을 닫고 로그 업로드를 한 번 더 요청했다. 최신 파일의 종료 이벤트를 먼저 확인하고 원인 확정 전 PIN/키·백업 삭제/덮어쓰기나 추측 수정은 하지 않는다.
- main만 사용하고 현재 git 상태·temp.md·test.md를 대조한다. 공용 Xcode lock과 다른 프로젝트 산출물을 보존한다. 실제 기기는 아직 unavailable이며 구매 잠금 해제 유지, 계약·심사·유료화 제외다.

## 2026-09-13 TP0913B001 · 통합 구조 개선 / 후보 147

- 소스 `4631c77`을 main에 push했다. 로컬 화면 우선·센서 갱신 합치기/취소·접수된 로컬 편집 FIFO 보존·후처리 분리·bounded 일자 preview·비동기 snapshot 백업 준비와 커밋 재검증을 구현했다. 네 번들은 `1.0 (147)`이다.
- 최종 앱 회귀 1,097 PASS·기존 StoreKit 1 SKIP·0 FAIL, 패키지 89/89 PASS, generic iOS Debug 및 Release archive PASS. Simulator 날짜 전환·버전/로그 업로드 항목·1회 background/동일 PID 복귀를 확인했다. 증거는 `build/validation/TP0913B001`, 최신 결과는 test.md를 먼저 읽는다.
- 배포: 147 archive/export·검증·업로드 완료, Delivery UUID `43f84236-1f6b-4ba3-9923-5c70ce4fd148`. Apple `VALID`·Internal API build 147 연결/readback·테스터 1명 확인 완료. Chrome Plan 그룹 URL은 재진입/새로고침해도 빈 페이지여서 웹 빌드·테스터 노출은 미확인이다.
- iPhone/iPad/Watch unavailable. 실제 build 146 충돌 OS 보고서는 확보되지 않았고, 147의 TestFlight 실기기 설치·30회 복귀/30분 동작·새 iCloud 로그·PIN 복원은 미확인이다. 구매 잠금 해제 유지, 계약·심사·유료화 금지.

### 다음 채팅에 그대로 붙여넣기

```text
TP0913B001 잔여 게이트 이어서 진행해. 폴더 /Users/u_mo_c/Documents/taption plan, main만 사용한다. AGENTS.md, temp.md, test.md, NEXT_CHAT_PROMPT.md와 현재 git/ASC 상태부터 대조한다.
소스 4631c77의 구현을 다시 하지 말고 최신 1.0(147) 배포/실기기 게이트만 확인한다. 공유 Xcode 빌드는 studio build_lock.sh로 직렬화하고, 다른 작업의 lock/산출물을 보존한다. Luna만 병렬 사용하며 새 채팅은 필요한 경우에만 만든다.
App Store Connect Plan 그룹의 빈 페이지 문제를 재확인하고 TP Taption Plan 내부 테스트의 147 빌드·테스터 웹 화면을 readback한다. API 연결은 완료됐으며 웹 화면/클라이언트 설치와 별개다. iPhone 연결 시 충돌 보고서와 해당 버전 dSYM을 대조하고 TestFlight 설치 provenance·화면 복귀/저장·새 iCloud TaptionLogs를 검증한다. OS 보고서 없이 실제 충돌 해결을 단정하지 않는다.
판매 계약·심사·유료화는 제외하며 구매 잠금 해제 상태를 유지한다. 실제 PIN 복원/Watch·캘린더 수신/터치·발열은 확인된 것만 test.md에 기록하고 완료된 요청만 temp.md에서 제거한다.
```

## 2026-09-11 TP0911B002 · 저장 취소 오류 수정 및 TestFlight 146

- 소스 수정 커밋은 `6fd7326`이며 앱·iOS Widget·Watch 앱·Watch Widget은 `1.0 (146)`이다. 활동 저장 readback·공통 `persist()`·센서 snapshot 저장의 `CancellationError`를 사용자 오류에서 분리했다.
- 관련 XCTest 2/2, generic iOS Debug build, Release archive/export, `altool --validate-app`, 업로드/처리 `VALID`를 완료했다. Delivery UUID `fca81e99-261d-42c7-8bd8-4bed334e6429`다.
- `TP Taption Plan 내부 테스트`에 build 146을 연결했고 API 그룹 build·테스터 1명 readback을 완료했다. Chrome 그룹 URL은 `Unauthenticated`여서 브라우저 UI readback은 남아 있다.
- 사용자가 올린 최신 iCloud 로그 `TaptionLogs-20260911-105220.txt`(수정 전 build 145)는 현재 Mac에 동기화되어 readback했다. TestFlight 클라이언트 146 설치·launch·터치와 수정 후 새 로그 iCloud readback은 별도 실기기 게이트다.

### 다음 채팅에 그대로 붙여넣기

```text
대표님 요청 `TP0911B002` 이어서 진행해.

작업 폴더는 `/Users/u_mo_c/Documents/taption plan`, 브랜치는 `main`만 사용한다. 먼저 AGENTS.md, NEXT_CHAT_PROMPT.md, temp.md, test.md와 git live 상태를 대조한다.

현재 기준:
- 소스 수정 커밋: `6fd7326`
- 최신 TestFlight: `1.0 (146)`, App Store Connect `VALID`, `TP Taption Plan 내부 테스트` API 연결 완료
- Chrome 그룹 화면: `Unauthenticated`로 브라우저 UI readback 미완료
- 수정 전 build 145의 최신 `TaptionLogs-20260911-105220.txt`는 readback했지만, 수정 후 build 146 TestFlight 클라이언트 설치·launch·터치와 새 로그 readback은 미완료

남은 게이트만 확인한다. 로그인은 대표님이 직접 처리한 뒤 그룹 빌드·테스터 화면을 readback하고, 실기기에서 TestFlight 146 설치 provenance·버전·launch·저장 취소 팝업 재현 여부·설정 로그 업로드 후 iCloud 파일을 각각 확인한다. 개발자 설치와 TestFlight 설치를 혼동하지 않는다. 완료한 항목만 temp.md에서 제거하고 마지막에 git diff --check, clean worktree, HEAD=origin/main을 확인한다.
```

## 2026-09-10 TP0910A004 · iCloud 진단 오류·지연 수정 및 TestFlight 145

- `main` 최신 커밋은 `6e8b6e3`이며 origin과 일치한다. 앱·iOS Widget·Watch 앱·Watch Widget은 `1.0 (145)`다.
- 반복 `previous_session_unfinished`와 부분 백업/복구 가능한 legacy reading의 오류 등급을 정리하고, 공유 SQLite와 경합하던 map cache를 별도 DB로 분리했다. 관련 XCTest 108/108, Debug build, Release archive/export, `altool --validate-app`을 통과했다.
- Delivery UUID `a5a3ba33-8252-4fbb-b7c4-0104d59b7c57`는 App Store Connect `VALID`·`APP_STORE_ELIGIBLE`·`expired=false`다. `TP Taption Plan 내부 테스트` 연결 및 API 그룹 build 145·테스터 1명 readback을 완료했다.
- Chrome App Store Connect는 로그인 화면이어서 그룹·테스터 브라우저 UI readback은 남아 있다. TestFlight 클라이언트 설치·launch·터치와 실기기 `로그 보내기` 후 iCloud `TaptionLogs` readback도 별도 게이트다.

## 2026-09-09 REL909A001 · 메인 정리·TestFlight 재개 기준

- 워크트리는 `main`에서 clean이며 `origin/main` 일치는 새 채팅 시작 시 live로 확인한다. 임시 브랜치는 사용하지 않는다.
- 앱 소스가 반영된 최신 commit은 `226d105`이고 앱/Widget/Watch/Watch Widget build는 `1.0 (144)`다. 그 이후 main 커밋들은 개발문서·재개 프롬프트만 변경했다.
- build 144는 Release archive/export·서명·`altool --validate-app`·App Store Connect upload/processing `COMPLETE`·build `VALID`까지 완료했다.
- `TP Taption Plan 내부 테스트`에 build 144를 연결했고 그룹 화면에서 `1.0 (144) · 테스트 중`, 테스터 화면에서 1명 노출을 readback했다. 이는 TestFlight 클라이언트 설치 증거가 아니다.
- 대표님 iPhone 14 Pro의 TestFlight 설치 표시는 아직 `1.0 (142)`다. build 144 설치·launch·실제 지도/로그 화면과 설정의 `로그 보내기` 후 iCloud `TaptionLogs` 파일 readback을 다음 채팅에서 확인한다.

### 다음 채팅에 그대로 붙여넣기

```text
대표님 요청 `REL909A001` 이어서 진행해.

작업 폴더는 `/Users/u_mo_c/Documents/taption plan`, 브랜치는 `main`만 사용한다. 먼저 아래를 읽고 live 상태를 대조해.

1. `AGENTS.md`, `NEXT_CHAT_PROMPT.md`, `temp.md`, `test.md`
2. `git status --short --branch --untracked-files=all`
3. `git rev-parse HEAD origin/main` 및 `git ls-remote origin refs/heads/main`
4. `xcrun devicectl list devices`

현재 기준:
- HEAD/origin/main: 새 채팅 시작 시 live readback (앱 소스 기준 `226d105`)
- 앱 소스 기준: `226d105`
- 최신 TestFlight: `1.0 (144)`
- build 144: upload/processing `COMPLETE`, `VALID`, `TP Taption Plan 내부 테스트` 연결 및 그룹/테스터 화면 노출 확인
- 실제 TestFlight 클라이언트 설치: 아직 iPhone에 `1.0 (142)`로 표시

남은 순서:
1. build 144의 TestFlight 실제 설치 provenance·버전·launch를 각각 readback한다. 개발자 설치와 혼동하지 않는다.
2. 실기기에서 지도 현재 위치/졸라맨 중앙·항상 위·등록 장소 좌표를 확인한다.
3. 설정에서 `로그 보내기`를 눌러 iCloud `Documents/TaptionLogs` 파일 생성과 비정상 종료 marker/Watch 로그 포함 여부를 readback한다. 기존 백업은 보존한다.
4. 새 crash 재현 여부를 systemCrashLogs에서 확인하고, 결과를 `temp.md`, `DEVELOPMENT.md`, `test.md`에 기록한다.
5. 소스 변경이 실제로 생길 때만 CURRENT_PROJECT_VERSION을 올려 새 archive/export/upload한다. 변경이 문서뿐이면 build 144를 중복 업로드하지 않는다.

각 게이트를 source/build, 자동 테스트, ASC processing, Internal 그룹 연결/노출, TestFlight 설치, launch, 실제 화면으로 분리해 보고한다. 완료한 항목만 `temp.md`에서 제거하고, 마지막에 `git diff --check`, clean worktree, HEAD=origin/main을 확인한다.
```

## 2026-09-09 CRH909A001 · 크래시 및 진단 로그

- iPhone crash report는 build 140의 `RUNNINGBOARD/0xDEAD10CC` SIGKILL이며 build 142 새 crash report는 미확인이다. `/tmp/CRH909A001`에 원본을 보존했다.
- 비정상 종료 세션 marker와 기존 설정의 iCloud `TaptionLogs` 전송을 보강했다. DiagnosticsLogSupportTests 10/10, Debug device build/install/launch `1.0 (144)` PASS. Release build 144는 App Store Connect `제출 준비 완료`, Internal 그룹 연결 및 그룹/테스터 화면 readback까지 완료했으며 실제 TestFlight 설치는 142다.

## 2026-09-08 REV908A001 · 리뷰 및 다음 배포

- 저장·백업, 지도·활동, Watch·Live Activity, 릴리스 경계를 병렬 검토했다. snapshot 크기 제한, MapKit stale 좌표 덮어쓰기, Dynamic Island catalog title fallback을 수정했다.
- build 143은 문서/프로젝트 버전 갱신 후 archive/export → 처리 → Internal 그룹 API/UI → 실기기 게이트 순서로 확인한다.

## 2026-09-08 BAK908A001 · 최신 백업 오류 수정

- 실제 iCloud 백업이 version 1인데 앱이 version 2/AAD만 허용해 `백업 파일의 암호화 또는 무결성을 확인하지 못했습니다.`를 표시했다. v1 AES-GCM 무-AAD 읽기를 복구하고 v2 metadata AAD 검증은 유지했다.
- 원본 복사·ciphertext digest 확인: `/tmp/BAK908A001.pgwpKC`; SecurityBackupCoreTests 55/55 PASS·Debug generic build PASS. 실제 PIN 복호화·iPhone 복원은 별도 게이트다.
- build 142 TestFlight archive/export·검증·업로드·처리 `VALID`, Internal API 연결·테스터 1명 readback 완료. Delivery `ded15358-7e3b-4360-917a-7c264accfe48`; 브라우저 새로고침 뒤 AX 트리가 비어 142 UI readback은 미완료.

## 2026-09-08 INT908A001 · 최신 진행 정본

- 소스 `e170ba3` + `7ddb22d`, build 142. 기존 전체 1,077 PASS·1 SKIP·0 FAIL, BAK908A001 집중 55/55 PASS와 앱·위젯·Watch Debug/Release archive PASS. `/tmp/BAK908A001.pgwpKC`.
- ‘전체 설정’ 버튼만 제거하고 다이나믹 아일랜드 축소 화면은 정상 활동 그림/현재 활동명으로 변경했다. Watch 일반 명령 단회 capability·외부 HealthKit 운동 소스 검증도 적용했다. 구매 잠금 해제는 유지한다.
- PID 12968의 15:02 post-fix DEAD10CC가 raw 읽기 decode/file lock에서 발생해 LOG908B001로 decode 잠금 분리·DB background assertion·취소를 보완했다. BAK907A001 암호화 실패 원인은 별도로 미확정이다.
- Release archive/export·서명·검증·업로드·처리 PASS, 141 `VALID`. UUID `4a600796-ed30-4c23-9749-d4fb3b0af819`. Internal 그룹 연결(204) 후 API 및 Chrome 그룹 빌드 `1.0 (141)` ‘테스트 중’·테스터 1명 화면까지 확인했다. 테스터의 실제 설치는 아직 140이며 141 설치/실행으로 보고하지 않는다.
- Chrome 인증 복구 후 유료 계약 ‘신규’와 법인/규정 준수 잔여 항목을 확인했다. 계약·심사·유료화는 건드리지 않는다. BAK907A001·실기기·판매 게이트만 이어서 확인한다.
- 현재 iPhone/Watch unavailable, iPad connected. 아래 과거 기기 버전/빌드 기록은 역사이며 최신 설치 성공을 의미하지 않는다.

## 2026-09-08 WAK908C001 집/졸라맨 겹침 재수정

- 최신 아이폰은 이 변경을 포함한 Apple Development Debug `1.0 (140)`이다. 빌드·서명·설치·버전 및 launch PID `12968`를 readback했다: `/tmp/WAK908C001`.

- WAK908B001은 실화면에서 재발했다. 졸라맨을 native annotation 목록에서 제거하고 지도 자체의 전용 subview로 분리했다. 발끝 좌표·기존 60Hz 갱신·검색창/시간표 계층은 유지한다.
- 같은 좌표 집 선택·3단계 줌·직접 subview 순서·발끝 좌표 및 기존 계층 회귀 3/3과 Simulator Debug build를 통과했다: `/tmp/WAK908C001/final-tests.xcresult`.

## 2026-09-08 WAK908B001 졸라맨 표시 순서

- 최신 아이폰은 이 수정이 포함된 Apple Development Debug `1.0 (140)`이며 설치·버전·launch PID `12802`를 확인했다: `/tmp/WAK908B001`.

- 졸라맨을 다른 지도 마커보다 위에 표시하도록 Apple 콘텐츠 갱신·카메라 변경 완료·다른 마커 선택 후 재정렬을 보강했다. Vector·좌표·크기·검색창/시간표 계층은 유지한다.
- 관련 회귀 2/2 및 Simulator Debug build 통과: `/tmp/WAK908B001/tests.xcresult`. 실제 겹침·줌 화면은 별도 확인한다.

## 2026-09-08 CAN908A001 취소 오류 팝업 보완

- 최신 아이폰은 이 수정이 포함된 Apple Development Debug `1.0 (140)`이며 설치·버전·launch PID `12388`를 readback했다: `/tmp/CAN908A001`.

- `refreshSensorTimeline`에서 센서 읽기 `CancellationError`를 실제 실패로 표시하던 경로를 분리했다. 취소는 조용히 종료하고 실제 읽기 오류는 계속 알린다.
- 취소/실패 구분 및 기존 기록 보존 회귀 2/2와 Simulator Debug build를 통과했다: `/tmp/CAN908A001/tests.xcresult`.

## 2026-09-08 LOG908A001 최신 수정·아이폰 설치

- 최종 앱 저장소 18/18 및 DayStore 19/19로 관련 회귀 총 37/37 PASS·0 SKIP·0 FAIL다. 설치 후 짧은 확인 구간에서 추가 crash report는 없었다.

- 최신 아이폰 crash에서도 build 140의 인코딩 및 SQLite 트랜잭션 중 `0xDEAD10CC`가 확인됐다. 기존 인코딩 lock 분리에 iOS 저장·삭제 background assertion과 만료 시 SQLite 취소·rollback을 추가했다.
- DayStore 회귀 19/19, 아이폰 Debug build·서명·데이터 유지 설치·launch PID `12262`, 약 1분 백그라운드 후 같은 PID 복귀를 확인했다: `/tmp/LOG908A001`.
- 현재 아이폰은 수정 소스의 Apple Development Debug `1.0 (140)`이며 TestFlight build 140 배포본과 다르다. 새 TestFlight 업로드·Internal 화면 확인과 장시간 물리 재현은 남아 있다.

## 완료된 최신 구현: build 140 충돌·지도 CPU 완화

- `CRH907A001`에서 build 140의 `0xDEAD10CC` stack과 맞춰 연간 리뷰 등 모든 domain payload 인코딩을 SQLite 파일 lock 획득 전으로 옮겼다.
- `MapHomeView` 생성 시 시간 레일 전체 계산을 제거하고 placeholder 뒤 기존 비동기 refresh에서 계산한다.
- 관련 회귀 727건 중 726 PASS·1 SKIP·0 FAIL 및 Simulator Debug build를 통과했다. 이 수정은 TestFlight build 140 이후 소스이며, 새 빌드의 반복 launch·백그라운드 전환·로그 저장은 물리 게이트다.

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

- `ICO907A001`에서 업무·식사·수업·취미 졸라맨을 제거하고 모니터 글자·그릇과 수저·책장·음표 전용 애니메이션으로 교체했다. 지도 마커 회귀 37/37 PASS, 기능 회귀 557 PASS·1 SKIP·0 FAIL 및 Simulator Debug build를 통과했으며 build 140 이후 소스다.
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
