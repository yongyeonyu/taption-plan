# 검증 기록

현재 실행 근거만 간결하게 유지합니다. 이전 상세 개발·검증 기록은 Git 이력에 보존했습니다. `build/validation/`은 로컬 증거이며 Git에 포함되지 않습니다.

## KIR0923A01 · 2026-09-23 Kiro 인수인계 준비

- 환경: Apple Silicon arm64, macOS 26.6.2 (25G83), Xcode 27.0 (27A266a), Swift 6.4. 프로젝트 언어 모드 6.0, iOS 18/watchOS 11 이상, 네 번들 버전 1.0(149).
- 기존 구현·회귀·개발 기록을 `a8e3d5c` 커밋으로 보존하고 `KIRO_HANDOFF.md`에 환경·명령·아키텍처·다음 개발 범위를 통합했다.
- 삭제: `DEVELOPMENT.md`, `NEXT_CHAT_PROMPT.md`, `plan.md`, `design-qa.md`, `STICKMAN_ANIMATION_GUIDE.md`, `SENSOR_FUSION_SOURCES.md`, `ui-draft-iphone.html`.
- 유지: `AGENTS.md`, README, 지원·개인정보 문서, 미완료 요청과 이번 검증 기록. 기존 로컬 전용 `temp.md`는 미완료 항목을 압축해 인수인계 자료로 함께 추적한다. `.codex/`·`.workbuddy-ai/`는 로컬에 보존하고 Git에서 제외했다. 사용자 데이터·기존 빌드 증거·다른 프로젝트 작업은 삭제하지 않았다.
- 기준 파일 281개 중 276개는 SHA-256이 동일하다. 검증에서 발견한 아래 비일자 snapshot 호환 회귀의 최소 수정 5개 파일만 변경했다. 문서·`.gitignore`는 정리 대상이라 이 비교에서 제외했다. 증거: `build/validation/KIR0923A01/preservation-check.json`.
- README/인수인계의 로컬 링크, 문서 내 shell 예제 구문, 앱 엔진 import 경계와 `git diff --check` 통과. 원격 fetch 시 기존 main은 origin/main과 일치했으며 새 브랜치는 만들지 않았다.
- 최종 검증: 패키지 Core 99/99·Activity 33/33·Route 38/38·facade 1/1 PASS(총 171), 앱 전체 1,344 PASS·기존 StoreKit 1 SKIP·0 FAIL·runtime warning 0. StoreKit 스킵은 iOS 26.5 Simulator의 SKInternalErrorDomain Code 3 제한이다.
- 최종 iOS·watchOS generic device Debug 빌드 모두 PASS, error/warning/analyzer warning 0. `CODE_SIGNING_ALLOWED=NO` 빌드이므로 서명·실기기 설치 검증을 뜻하지 않는다.
- 실행 증거: `build/validation/KIR0923A01/TaptionPlanCore-final.log`, `TaptionActivityEngine.log`, `TaptionRouteEngine.log`, `TaptionPlanEngine-final.log`, `app-tests-r3.xcresult`, `ios-debug-r3.xcresult`, `watch-debug-r3.xcresult` 및 각 summary JSON.
- 소스·인수인계 정리 커밋 `881d433b111e8e411e6cd8535e195c8dc79e2dc2`를 main에 푸시한 뒤 HEAD·origin/main·서버 refs/heads/main 일치와 빈 `git status --porcelain=v1`을 확인했다. 이 완료 증거에 따라 `KIR0923A01`을 요청 큐에서 제거했다.

## HKD0923A01 · HealthKit·계획 저장소의 비일자 snapshot 호환

- 최초 전체 실행에서 `HealthKitImportStore`가 기존 `0000-00-00` snapshot을 조회할 때 Core의 강화된 날짜 검증이 `invalidDay`를 반환했다. 동기화 gate 진입 전 실패해 후속 테스트도 대기했다. 최초 결과는 673 PASS·1 SKIP·4 FAIL(직접 오류·시간초과·후속 오류·중단 포함), exit 75이며 통과 결과로 사용하지 않는다: `build/validation/KIR0923A01/app-tests.xcresult`.
- `TaptionPlanDayStore`에 기본 false인 비일자 snapshot 허용 옵션을 추가하고 HealthKit 저장소와 SQLite 계획 저장소만 명시적으로 사용한다. 기존 SQLite 키·payload·anchor·revision·원자적 event/checkpoint 갱신은 유지하며 스키마 migration은 하지 않는다. event·map·V3 및 일반 저장소 날짜 검증은 유지한다.
- 새 회귀는 기존 SQLite row의 읽기, event/checkpoint 갱신 후 재열기, 일반 저장소 기본 거부, 비일자 event/map·부분 무효 날짜 거부를 검사한다.
- HealthKit 집중 35/35 PASS. 중간 전체 실행은 계획 저장소의 같은 키 호환 누락으로 1,331 PASS·1 SKIP·13 FAIL이었다. 소비자와 직접 readback하는 테스트를 수정한 뒤 최종 전체 1,344 PASS·1 SKIP·0 FAIL 및 iOS/Watch Debug 빌드로 저장·재열기·revision·Watch summary ACK 경로까지 통과했다. 완료 항목을 요청 큐에서 제거했다.

## 선행 실기기 증거와 아직 남은 검증

- 2026-09-22 iPhone의 날짜·지도 재생 입력, 9/9 항공 경로 readback 및 일부 실제 저장 재열기는 기존 기록에서 확인됐다. 같은 날 iPad Debug 설치·실행은 첫 권한 화면까지 확인했고 후속 UX는 미완료다. 이전 전체 테스트 통과 수를 이번 최종 소스의 전체 검증으로 재사용하지 않는다.
- 2026-09-23 iPhone 18 Pro Max 대상 profile을 포함한 Debug 149 설치·foreground 실행과 약 1분 app/widget 생존, 새 OS crash report 없음이 기록됐다. 이는 TestFlight 설치나 정확한 9/9 장시간 CPU workload 완료가 아니다: `build/validation/HAR0922A01/device-targeted-build.xcresult`, `device-targeted-install.json`, `device-targeted-processes.json`.
- Watch는 paired/developer mode enabled 상태에서도 tunnel disconnected/timeout이었다. 실제 강제 종료 후 재전송·ACK/receipt 전환·HealthKit 삭제는 미검증이다.
- WeatherKit capability·entitlement와 대상 기기 profile은 확인했으나 실제 provider/401 해소 로그는 없었다. iCloud 실제 PIN 복원·다중 기기 경합, 장시간 CPU/file-lock workload도 별도 남아 있다.
- 마지막 배포 기록은 2026-09-13 TestFlight 149의 처리·`TP Taption Plan 내부 테스트` 그룹 빌드·테스터 노출 확인이다. 그 이후 코드와 이번 정리는 새 TestFlight 업로드가 아니다. 이번에는 ASC live 조회·실기기 설치·실제 판매 작업을 수행하지 않았다.
