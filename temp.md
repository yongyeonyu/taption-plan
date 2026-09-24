# 남은 요청

2026-09-23 기준입니다. 완료한 구현과 상세 이력은 Git 이력에 보존했으며, 아래 항목은 실제 증거 또는 설계 선택이 남아 있어 유지합니다. 빌드·자동 회귀 통과만으로 실기기 항목을 닫지 않습니다.

## ACC0923W01 · 정확도 3종 실측대조 (집→회사→집, 지하철, LG사이언스파크)

정답 동선 확정: 9/22 실제 = 집→회사→집, 이동수단 지하철. 회사 = 서울 강서구 마곡중앙10로 10, LG사이언스파크.

### 1. 회사 위치 복구 (원인·절차 확정)
- 근본원인: `FrequentPlace.defaults`는 `.company`를 `point=nil`(미등록)로만 시드한다. 회사 좌표는 소스가 아니라 **기기 앱 설정(SQLite/UserDefaults)** 에 저장 → 폰 교체로 유실. **소스 편집으로 복구 불가**, 앱 데이터 또는 앱 내 등록으로만 복구.
- 지오코딩(Nominatim): LG 사이언스파크 = **위도 37.5625500, 경도 126.8274380** (실제 등록은 앱이 CLGeocoder/Apple Maps DB로 재해석, 반경 120m면 캠퍼스 포함).
- 복구 절차(앱 내): 설정 → 자주 가는 장소 → 회사 → 위치 지정. 코드 API = `AppModel.setFrequentPlaceLocation(placeID, latitude:37.5625500, longitude:126.8274380, floor:?)` (radius 기본 120m, `setMapLocation` 경유).
- 결정 필요: 회사 캠퍼스가 넓어(여러 동) 반경 120m로 부족할 수 있음 → 반경 상향(예 250~400m) 검토.

### 2. 워치리스 수면 감지 (코드 검증 결과)
- 파이프라인: `PhoneSleepFallbackEngine`가 `PhoneSleepWakeEngine`(화면꺼짐+어두움+무활동, **충전 무관**) + `ChargingInactivitySleepEngine`(**충전 필수**) 병합, HealthKit 수면과 겹치면 제외. watchAvailable 시 둘 다 빈배열.
- `PhoneSleepWakeEngine.isSleepSignal`: `inactive && screenOff && dark`. brightness 없으면 screenOff로 폴백(이미 SLP0922S01에서 보강). inactive = motion `.stationary` 또는 `.unknown`+엄격 임계.
- 검증 결론: 워치 없이(충전 없이도) 화면기반 폴백이 동작하도록 설계됨. **아키텍처는 정상.** 9/22 미확인은 알고리즘 부재가 아니라 입력(연속 stationary+dark run) 부족이 원인일 가능성 → raw 데이터로 확정 필요.

### 3. 9/22 raw 추출 의존성 (블로커)
- iPhone 18 Pro(00008160-000E195A1140000A) **현재 미연결**(연결된 건 시뮬만). 앱그룹 컨테이너는 devicectl 접근불가(error 7000) 확정.
- 유일 경로 = **앱 내 진단 내보내기**(`AppModel.exportDiagnostics` → Files/공유) 후 파일 전달. 이전 추출본 `Packages/TaptionLogs-*.txt`는 현재 없음(정리됨).
- 암호화 페이로드(.taptionbackup, iCloud PIN AES-GCM)는 복호 안 함 — 구조만 참조.

## WRK0922D01 · 회사 체류인데 '업무(근무)' 미표시

- 증상: 2026-09-22 회사에 있었는데도 업무 자동 기록 없음. (회사·집 자주가는 곳 등록됨)
- **로그 확정(9/22 진단 패키지 TaptionLogs-20260923-014921)**: `sensor_activity_classification_completed` 61회 전부 `fresh=0, persisted=0` — 그날 정지-문맥 분류가 **하나도 생성되지 않았다**. 즉 `.work` 이전에 분류 입력(체류) 자체가 비었다. 코드상 `.work`는 `placeKind==.company`일 때만 부여되고(`StationaryContextClassifier`), placeKind는 `FrequentPlaceResolutionEngine.applying`의 3게이트(isAutomaticRecordingEnabled / distance≤radiusMeters 120m / dwell≥minimumDwell) 통과 시에만 붙는다.
- 근본 원인: 9/22 회사 체류가 `.company`로 해석되지 않아 분류 파이프라인에 stationary-context 입력이 없었다(fresh=0). GPS0922J01과 **동일 뿌리**(장소 해석).
- 남은 확정: 회사 등록 좌표·반경 vs 9/22 대표 체류 좌표 거리, autoRecording 플래그, dwell. (분류 fresh=0의 직접 사유가 place 미매칭인지 stay 자체 부재인지 place-resolution 이벤트로 최종 확정 필요.)

## GPS0922J01 · 위치가 회사↔집으로 점프 — 코드 수정 완료, 실기기 검증 대기

- 로그 확정(9/22): 점프는 forecast가 아니라 **actual 이동 leg**(projection_actual_movement_count=890, forecast_same_endpoint_pairs=0). source=1608→937 축소 뒤 회사↔집 reading쌍이 sparse-connection을 통과해 직선 leg로 연결됨.
- 원인: `RouteSparseConnectionPolicy.breaksConnection`이 gap>5분 AND 거리>1km 일 때만 끊어, gap이 5분 이하인 원거리 튐은 연결됨.
- 수정 완료: 불가능속도(>55m/s) 규칙 추가로 gap 무관 차단. RouteEngine 39/39 PASS(+1 신규). 상세: test.md GPS0922J01.
- 남은 것(실기기): iPhone 18에서 9/22 같은 날 재생 시 점프 사라짐 확인.

## SLP0922S01 · 수면 미확인 (워치리스 알고리즘 존재) — 코드 수정 완료, 실기기 검증 대기

- 로그 확정(9/22): `sleep_inference_completed` 61회 전부 `reason=conditions_or_continuity_not_met` — 워치리스 경로가 매 윈도 실행됐으나 보조조건 게이트 전량 탈락.
- 수정 완료: `strictSleepActuals`에서 homePoint 있을 때 요구치 3→2, 화면 꺼짐(밝기 nil)을 어두움 근거로 인정. 공유 엔진·기본 config 불변. 패키지 33/33 + 앱 어댑터 26/26 PASS(회귀 2건 신규). 서명 빌드 iPhone 18 설치 완료. 상세: test.md SLP0922S01.
- 남은 것(실기기): 오늘 밤 서명 빌드로 취침 후 다음날 수면 표시 확인. HealthKit 수면이 iPhone14에 묶여 안 넘어온 경우는 별개(소스 기기 연결).

## BAK0922I01 · iCloud 백업 "무결성 통과 못했다" — 코드 수정 완료(A안), 실기기 검증 대기

- 로그 확정(9/22): `icloud_backup_automatic` 반복 실패(error_code 4 invalidArchive / 6 accountUnavailable), 동시각 `cloud_account_status` 전부 authorized. 기기 이전 키 불일치가 원인.
- 원인: `prepare`가 같은 달 기존 아카이브를 병합하려 PIN키→계정키 복호 시도, 둘 다 실패 시 invalidArchive throw.
- 수정 완료(A안): 두 키 복호 실패 시 병합 건너뛰고 이번 기기 키로 새로 봉인해 저장(스키마 불변, 복구 가능 데이터 손실 없음). accountMismatch·load 무결성 검증 불변. SecurityBackupCore 103/103 PASS(신규 회귀 포함). 상세: test.md BAK0922I01.
- 남은 것(실기기): 대표님 PIN 입력 후 iCloud 백업 성공 전환 확인.

## 공통 원인 요약 (로그 확정)

- WRK·GPS는 **장소 해석(FrequentPlaceResolutionEngine.applying)** 을 공유: 9/22 분류 fresh=0 + forecast 점프쌍 0이 이를 뒷받침(문제는 place→분류 입력 부재, 그리고 actual leg 열). 가설(공통 원인=장소 등록/분류)은 **분류 입력 부재 쪽으로 확정**, 단 GPS 점프의 직접 트리거는 forecast가 아니라 actual leg 연결이라는 점에서 부분 반증됨.
- SLP는 별개 축(워치리스 게이트 과도 + HK 이전기기 종속). BAK도 이전기기 키 종속 계열.
- 로그로 미확정 잔여: place-resolution 이벤트(회사 매칭 거리 vs radius), sparse-connection 임계 대조, strict vs fallback 분기(rich-field 로그).

## BUG1909R01 · CPU0922A01 · 실제 watchdog/CPU/file-lock 재현

- 원인: 배포 149 OS 보고서에서 반복 분류/경로 전체 스캔에 의한 watchdog·CPU 점유, 별도로 background raw decode 중 App Group 잠금으로 인한 `0xDEAD10CC`를 확인했다.
- 구현: interval index, 취소·generation fence, 비활성 화면 계산 차단, 잠금 밖 decode와 짧은 SQLite snapshot, migration·저장 경합 보호는 반영·자동 검증됐다.
- 남은 검증: 최신 소스로 정확한 9/9 장시간 지도 재생 CPU workload 및 9/20 background raw backup workload를 재현하고 OS report/UUID/dSYM을 대조한다. 180초 생존·신규 report 없음은 선행 부분 증거이며 장시간 완료가 아니다.

## REV0922E01 · REV0921A01 · 현재 변경의 후속 코드 검토

- 원인: 기존 watchdog 한정 리뷰가 저장·백업·Watch·HealthKit·분류·경로·앱 통합 변경 전체를 보장하지 않는다.
- 해결: 현재 코드에서 재현 가능한 correctness/concurrency/data-loss/performance 결함만 좁게 수정하고 해당 회귀로 확인한다. 이미 수정한 항목을 반복하지 않는다.
- 검증 기준: 경로·재현 조건·기존 동작/수정 차이·관련 테스트 근거. 수동 대조에서 새 결함을 확정하지 못한 것과 전체 검토 완료를 구분한다.

## WPC0920A01 · WSD0922A01 · WCE0920A01 · WST0920A01 · WPD0920A01 · Watch 실기기

- 원인: 연결 실패 시 전송 재시도/중복 payload, 비-main callback actor trap, 운동 lifecycle/purge 경합, 삭제 중 반환된 HealthKit workout 및 재시작 spool 보존 문제가 있었다.
- 구현: SQLite outbox·영구 저장 ACK, stable ID/revision, 불필요 callback 제거, lifecycle gate, generation 검사, durable spool·purge intent는 반영했고 자동 회귀는 통과했다.
- 남은 검증: paired Watch 강제 종료 후 실제 재전송·iPhone 영구 저장·ACK/receipt 전환, 운동 시작/정지·purge 경합 및 실제 HealthKit 삭제. 마지막 연결은 paired/developer mode enabled이지만 tunnel disconnected/timeout이었다. 연결·실제 전송 증거 없이는 닫지 않는다.

## WKT0922A01 · WeatherKit 실제 응답

- 원인: 실기기 WeatherKit HTTP 401이 보고됐다. capability와 entitlement 및 대상 UDID를 포함한 profile의 설치·실행은 확인됐다.
- 해결/검증: 최신 서명 설치본에서 실제 provider 응답과 401 해소를 앱 로그로 확인한다. 현재 6시간 인증 실패 억제·Open-Meteo fallback이 있어 날씨 표시만으로 성공 처리하지 않는다.

## TP0913C001 · TP0913C002 · BAK907A001 · BAK908A001 · 실제 기록·백업·복원

- 원인: 과거 날짜 원본/지도 표시 불일치와 raw 백업 `invalidArchive`가 있었다. 원본 재조회·Date JSON 왕복 동일성 및 충돌 진단 수정은 배포 148에 포함됐다.
- 남은 해결/검증: 최신 수정본으로 9/11 원본·지도·시간축의 날짜 왕복/재열기와 건수 비교, 수동/자동 full-raw 백업·월간 snapshot/raw 복원 및 새 TaptionLogs 종료 결과를 확인한다. PIN은 대표님이 기기에서 입력하며 기존 백업·원본·키를 보존한다.
- 제한: 외부 JSON/digest 정상이나 Simulator 테스트만으로 실제 복호화 성공을 단정하지 않는다. 옛 기기 오류가 수정한 Date 결함과 같았다는 근거도 별도로 확인한다.

## TP0913A001 · DEV903V001 · IPD905G001 · MAP904A001 · TF906R0001 · 실기기 품질

- 원인: 자동 테스트·Debug 설치만으로 최신 TestFlight와 실제 장시간 사용을 확인할 수 없다.
- 남은 검증: 최신 TestFlight 설치 provenance·실행, 화면 켜기/복귀 30회·30분 사용, 날짜 이동·저장/대분류 편집, GPS 공백 경로/재수신 제거, iPhone/iPad pinch·지도 재생·VoiceOver·발열/배터리.
- 현재 근거: 선행 iPhone Debug 지도·재생 및 iPad Debug 실행 확인은 있다. iPad 권한 입력 이후 UX와 최신 TestFlight 동작은 별도다. 구버전 설치 요청은 최신 배포 기준으로 통합하고 전체 SettingsView 진입 버튼을 복원하지 않는다.
- 관련 포괄 요청 `PRD904A001`, `PAY906Q001`, `PRD906A001`, `PLAN906P001`의 남은 품질 범위도 이 항목·백업·캘린더에 포함한다.

## CALA090601 · 실제 캘린더 계정

- 원인: 선택·권한·계정 교체의 자동 회귀는 통과했지만 실제 계정 연동 증거가 없다.
- 해결/검증: Apple·Google·Naver 계정에서 교체·재허용 후 선택 상태와 일정 원본을 readback한다. 연결 전에는 완료 처리하지 않는다.

## RST0920A01 · MIG0921A01 · 대용량 복원·migration 설계 선택

- 원인: rawEventPage에 cursor revision·read transaction·행/바이트 제한을 넣었지만 v1/v2 월 단일 AES-GCM/LZFSE/Codable blob의 전체 decode, merge/preflight 결과 집적 및 V3 day 단일 payload는 메모리 상한이 없다. 64MiB 저장 제한도 인코딩 뒤 검사이므로 peak 상한이 아니다.
- 선택 1: V3 계약을 유지하며 streaming 입력과 사전 day/row cap을 적용하고 초과일은 완료 marker 없이 안전 중단한다.
- 선택 2: V4에서 readings를 bounded rows/pages로 분리하고 load/query/migration 계약을 함께 변경한다.
- 복원 추가 선택: v3 청크 인증/압축, 보호된 SQLite stage와 ID unique index, 검증 후 bounded commit·rollback recovery journal, 손상 raw의 snapshot-only 부분 복원 및 앱 재실행 복구 보장 범위. 구버전 strict streaming에는 검토된 incremental GCM 구현이 선행돼야 한다.
- 검증 기준: 기존 v1/v2 fixture·원본 보존, malformed/conflict/cancel/retry, commit/rollback 복구와 실제 peak memory. 선택 전에 스키마를 바꾸지 않는다.

## BKC0920A01 · 다중 기기 백업 원자성 선택

- 원인: iCloud 파일의 이전 값 비교는 서버 CAS가 아니어서 두 기기가 같은 월 snapshot을 덮어쓰면 한쪽 raw generation이 복원에서 빠질 수 있다.
- 후보: 불변 snapshot/raw generation과 CloudKit change-tag manifest CAS, 충돌 시 재병합. Production schema·오프라인 재시도·혼합 버전 계약이 필요한 별도 확장이다.
- 검증 기준: 두 기기 경합·중단·재시도·구버전 복원. 설계 선택 전 보류한다.

## BRT0920A01 · 백업 generation 보존 정책 선택

- 원인: 성공한 raw 백업과 실패한 staged 파일의 generation/orphan이 누적될 수 있다. 정상 복원은 committed snapshot의 정확한 generation을 직접 읽으며 enumeration cap과 구분된다.
- 후보/검증: offline 기기·동기화 중 이전 snapshot 참조를 고려한 보존 수와 정리 시점을 먼저 선택하고 참조된 파일의 보존·삭제 실패/재시도를 검증한다. 임의로 오래된 백업을 삭제하지 않는다.

## PKG0920A01 · App Group 소유 경계 선택

- 원인: 공개 Core API가 앱 전용 App Group ID를 소유하고 여러 host target이 이에 의존한다.
- 후보/검증: host에서 ID/컨테이너 URL을 주입할지 선택한 뒤, 실제 identifier와 저장 위치를 유지하면서 앱·Watch·위젯·패키지 회귀를 확인한다.

## IAP905G002 · IAP907A001 · 판매 작업 보류

- 현재 결정: 구매 잠금 해제와 내부 테스트를 유지한다. Paid Apps Agreement, 판매정보, IAP 심사 연결·심사 제출·유료화·실제 구매/복원은 별도 재개 요청 전까지 실행하지 않는다.
- 검증 기준: 재개 시 현재 계약·권한·StoreKit 상태와 실제 구매/복원을 확인한다. 과거 READY_TO_SUBMIT 또는 로컬 메모는 현재 판매 가능/실행 승인 증거가 아니다.
