# 개발 안내

이 문서는 코드 위치와 재사용 가능한 검증 명령만 설명합니다. 요청 상태는 `temp.md`, 실행 증거는 `test.md`에서 요청 ID로 찾고, 현재 코드를 기준으로 작업하세요.

## 프로젝트 경계

| 영역 | 위치 |
| --- | --- |
| 앱 상태·저장 조정 | `TaptionPlan/UX/AppModel.swift` |
| 일자 데이터 값·원본 정렬·fingerprint | `TaptionPlan/Core/PlanDayDataSnapshot.swift` |
| 공통 캐시·입력 예산·UUID 순서 | `Packages/TaptionPlanCore/Sources/TaptionPlanCore/RuntimeEfficiency.swift` |
| 지도 카메라·터치 정책 | `TaptionPlan/UI/MapHomeInteractionPolicy.swift` |
| 지도·시간축·시간표 UI | `TaptionPlan/UI/MapHomeView.swift`, `MapHomeTimeSidebar.swift`, `ScheduleView.swift` |
| 지도 안개(세기 정책·벡터/Apple 지도 렌더러) | `TaptionPlan/UI/MapHomeFogLayer.swift` |
| 지도 카운터 표·재생 끊김 보정·라이브액티비티 현재 활동 | `TaptionPlan/UI/MapHomeCounterTable.swift`, `MapHomePlaybackContinuity.swift`, `LiveActivityCurrentActivity.swift` |
| 클립 만들기·표기 도우미(편집기 화면 본문과 분리) | `TaptionPlan/UI/MapHomeNLEClipFactory.swift`, `TaptionPlan/UI/MapHomeNLEClipEditor.swift` |
| SQLite 저장소(파일 하나 `taption-store.sqlite`: readings·records·raw_events)·워치 원본·암호화 백업 | `TaptionPlan/Core/TaptionStoreV2.swift`, `TaptionStoreRawEvents.swift`, `TaptionStoreRepository.swift`, `PlanDayDatabase.swift`, `TaptionBackupEngine.swift`·`TaptionBackupFormat.swift`·`TaptionBackupDestination.swift`(월 단위 백업), `PlanBackupEngineAdapter.swift`(앱이 엔진을 부르는 유일한 곳), `PlanBackupPresentation.swift`, `AppLockAndPIN.swift`·`PlanSecurityService.swift`(비밀번호·앱 잠금) |
| 활동 기록 배열의 저장소 공유·바이트 단위 동일성 비교 | `TaptionPlan/Core/PlanActualStorage.swift` |
| 센서 레코드 직접 바이너리 저장·복원 | `TaptionPlan/Core/SensorReadingStorage.swift`, `Packages/TaptionPlanCore/Sources/TaptionPlanCore/CanonicalStorage.swift` |
| 센서·HealthKit·Apple 연동 | `TaptionPlan/Core/SensorDataServices.swift`, `HealthKitImportCoordinator.swift`, `HealthKitImportStore.swift`, `AppleIntegrations.swift` |
| 앱과 엔진 연결 | `TaptionPlan/Core/RouteTimelineData.swift`, `TaptionRouteEngineAdapter.swift`, `TaptionActivityEngineAdapter.swift` |
| 공유 엔진 | `Packages/TaptionPlanCore/`, `Packages/TaptionActivityEngine/`, `Packages/TaptionRouteEngine/`, `Packages/TaptionPlanEngine/` |
| Watch·위젯 | `TaptionPlanWatch/`, `TaptionPlanWidget/`, `TaptionPlanWatchWidget/` |
| 회귀 테스트 | `TaptionPlanTests/`, 각 package의 `Tests/` |

앱 전용 프레임워크와 화면은 Swift Package로 옮기지 않습니다. package import 경계 검사는 `bash scripts/check-app-engine-import-boundary.sh`로 확인합니다.

HealthKit의 앱 읽기/import 허용 목록은 `TaptionHealthReadScope`의 8개 항목(운동·수면·심박·걸음·걷기/달리기 거리·자전거 거리·활동 에너지·운동 경로)입니다. 전체 타입 카탈로그는 기존 원본 해석용이며 신규 권한/수집 범위가 아닙니다. 임상·투약·영양·시력·특성·활동 요약 신규 조회는 하지 않고 기존 저장 원본은 보존합니다.

Apple Watch 데이터는 iPhone HealthKit으로 읽습니다. iPhone의 TaptionPlan target은 Watch 앱을 빌드·임베딩하지 않습니다. 기존 Watch 소스와 독립 target은 역사·호환 유지용으로 보존합니다. 앱 활성화 시 건강 연결이 켜져 있으면 즉시 증분 조회하고, 페어링된 Watch가 있으며 아직 건강 연결을 요청하지 않은 경우 사용자 승인을 요청합니다. Watch 앱 설치·실시간 메시지 응답은 조회 조건이 아닙니다. 건강 데이터의 Watch→iPhone 동기화 시점과 읽기 허용 여부는 앱이 강제로 제어하거나 판별할 수 없습니다.

## 보존해야 할 데이터 계약

- `PlanRepository`와 `HealthKitImportStore`는 기존 날짜 없는 snapshot 키 `0000-00-00`을 읽기 위해 `allowsUndatedSnapshots`를 켭니다. 일반 날짜, event, map 검증은 이 예외를 물려받지 않아야 합니다.
- `TaptionPlanCore`의 정본 Codable envelope는 현재 포맷만 읽고 변환을 한 번만 수행합니다. 백업 파일(`yyyy-MM.taptionbackup`)은 `TaptionBackupFormat` 헤더 버전을 따르며 이전 백업 포맷은 읽지 않습니다.
- 센서 단일 레코드는 `TaptionPlanBinaryRecord`를 통해 `TSR1` 고정 필드 순서로 직접 저장/복원합니다. UUID는 16바이트, 실수/시각은 원래 64비트, 정수는 little-endian 64비트, 문자열은 UTF-8 길이와 원문, optional은 별도 존재 태그를 사용합니다. 52개 필드·중첩 센서·enum의 모든 값을 보존하며 필드 순서/enum 코드를 바꿀 때는 형식 버전을 올려야 합니다. 기존 SHA-256·바이트 수·LZFSE envelope 검사를 생략하지 않습니다. 정상 읽기는 현재 형식만 사용하며, 실패한 센서 행의 envelope·체크섬이 유효하고 내부가 bplist00인 경우에만 기존 PropertyList를 한 번 해석해 조건부 repair 트랜잭션으로 TSR1에 저장합니다. UUID·sequence와 SQLite 시각의 1µs 이내 일치를 확인하고 삭제 generation·원래 행 비교를 유지합니다. 실제 사용자 DB를 도구로 삭제/초기화하지 않습니다. 일반 Codable/JSON 모델과 portable 백업 경로는 독립적으로 유지합니다. 읽을 수 없는 센서 원본 때문에 수동 백업이 중단되면 localSensorArchiveIncomplete로 구분하고 기존 기록/백업을 보존합니다.
- 활동 기록은 `actual_records`의 형식 있는 SQLite 열에 저장합니다. UUID와 중복 출현 순서로 행 키를 만들고 별도 `position`으로 원래 배열 순서를 보존합니다. 시작/종료/생성 시각은 Foundation 기준 시각의 REAL로 저장하며, 제목·분류·연결·source·confidence·provenance·분류 잠금은 별도 열입니다. 가변 evidence만 현재 정본 codec으로 저장합니다. `plan.actuals`에는 형식 버전과 건수만 남고, 이전512건 배열 분할/manifest/원본 중복 테이블은 사용하지 않습니다.
- `actual_record_ranges`의1차원 RTree가 겹치는 시간 구간을 찾습니다. Float 경계의 바깥 반올림으로 얻은 후보를 원래 REAL 시각으로 다시 제한하므로 자정·소수점 경계·진행 중 기록을 유지합니다. 조회는 revision과 행을 같은 WAL 읽기 트랜잭션에서 가져옵니다. DB 트리거가 행 삽입/수정/삭제 시 시간 인덱스와 활동 revision을 함께 갱신합니다.
- `SQLitePlanRepository`는 마지막 확정 snapshot 하나와 영역별 검증 정보·활동 revision·행 키를 재사용합니다. 같은 연결의 `data_version`·`total_changes64`와 삭제 generation이 같으면 payload를 읽지 않습니다. 외부 변경은 작은 snapshot 영역의 바이트와 활동 revision으로 구분하며, 센서·설정만 바뀌면 활동 전체를 다시 읽지 않습니다. 메모리 압력·삭제·로드 실패 때 캐시를 비우고 오래된 계산이 다시 채우지 못하게 합니다.
- `PlanActualEdit`는 불변 원본 배열과 한 건만 바꾼 결과 배열을 묶습니다. 저장소의 확정 배열과 입력 결과가 각각 같은 저장 공간을 공유할 때만 단건 UPSERT를 사용합니다. 다른 수정이 섞였거나 외부 revision이 바뀌면 전체 변경 비교로 돌아가며 변경된 행만 저장합니다. 루틴/계획 연결은 이 API를 사용합니다. 시작 정리 worker는 내용이 바뀌지 않은 활동 배열의 저장 공간을 유지해 이 경로와 범위 조회가 끊기지 않게 합니다. 원본이 없는 전체 가져오기는512행 단위로 SQLite 바인딩을 만듭니다. 같은 트랜잭션 안에서 행별 인덱스 트리거를 잠시 제거하고 정본 행을 넣은 뒤 SQL 한 번으로 RTree를 구성하고 트리거를 복구합니다. 활동 revision도 한 번 올리고 metadata와 함께 확정합니다. 중간 스키마는 다른 연결에 공개되지 않으며 DDL도 rollback 대상입니다. 오류·취소는 전부 rollback합니다.
- 기존 배포본의 활동 배열은 최초 로드에서 한 번만 typed 행으로 이관합니다. 이관과 작은 형식 header 교체를 같은 트랜잭션에서 수행하며 중복 원본은 유지하지 않습니다. 구버전 앱의 DB 읽기/쓰기는 지원하지 않습니다. 개발 단계에서만 사용했던 B01 묶음 형식도 지원하지 않습니다. 실제 사용자 DB·백업 파일을 작업 도구로 삭제하거나 변환하지 않습니다. 다른 작은 snapshot 영역과 portable 백업의 현재 모델은 유지합니다.
- 신규 iCloud 백업은 Gregorian 날짜 키 `yyyy-MM-dd`로 분할합니다. 각 날짜의 snapshot/raw는 기존 V4 페이지 LZFSE 압축·AES-GCM·체크섬 계약을 사용합니다. 로컬 DB 정본 형식과 과거 월별 백업은 유지합니다. 오늘은 매번 갱신하며 지난 날짜는 마지막 하루 범위 원본 저장/검증 후 계정 키로 인증된 작은 `.dailycomplete`를 기록합니다. 전체 날짜의 저장과 검증이 끝난 뒤에만 최근 성공 시각을 갱신합니다. 이후에는 완료 표식과 참조 파일 존재만 확인하고 해당 날짜의 센서 payload·암호문을 다시 읽거나 저장하지 않습니다. 자정 경계는 고정86,400초가 아닌 시간대의 다음 날짜 시작입니다. 미래 계획은 오늘의 미완성 백업에 포함합니다.
- 센서 날짜 목록은 SQLite 시각 메타데이터만 조회합니다. snapshot 날짜 분류는 메모리에 있는 기록 수에 비례하는 비용이 남으며, 첫 일별 백업은 과거 누락 날짜를 모두 저장해야 합니다. 백그라운드 snapshot 갱신은 기존 raw 세대를 참조해 재암호화하지 않고 완료 표식을 만들지 않습니다. 일별 파일 저장은 iCloud Documents가 정본이며 기존 월별 CloudKit manifest 본문 재병합을 실행하지 않습니다. 원래 월별 파일은 복원 시 함께 읽고, 날짜 간 계획/메모 연결은 모든 조각을 합친 뒤 검사합니다. 일별 복원은 기존120개 월 파일 제한으로 잘리지 않으며 최신 날짜 파일을 읽지 못하면 부분 복원을 성공으로 표시하지 않습니다.
- 일별 저장은 최신/직전 snapshot과 동시 분기를 보존합니다. 저장 직전 세대의 조상 중 더 오래된 것만 정리하고, 제거한 snapshot에서만 참조하던 raw 세대만 정리합니다. 다른 기기가 아직 게시 중일 수 있는 고립 raw 파일은 제거하지 않습니다. 실제 두 기기 동시 게시·실기기 전송 시간은 자동 테스트와 구분합니다.
- 진단 로그 패키지는 민감정보 제거 후 표준 gzip(`.txt.gz`)으로 압축하며, latest.json의 파일명·바이트 수는 실제 압축 파일을 가리킵니다. 이전 `.txt` 업로드 파일의 읽기/전송 경로는 유지합니다.
- 백업 포맷·암호화·체크섬·세대 참조를 바꾸기 전에는 현재 구현과 요청 기록을 확인합니다. 읽기 호환·복원·rollback 기준 없이 기존 백업을 제거하거나 변환하지 않습니다.

- 앱의 복원 메뉴는 `loadLatestBackupPackage(streamRaw: true)`로 V4 raw 암호문을 파일 페이지로 읽고 `PlanStagedRawRestore`의 SQLite cursor를 최대 256행/기본 1MiB씩 소비합니다. 단일 항목은 하드 4MiB 제한입니다. 기존 `.available(payload)`는 호환·진단 경로이며 전체 배열을 반환합니다.
- `RestoreStaging/restore-journal.sqlite`에는 target snapshot digest·세션·필요 저장소·삭제 generation을 기록합니다. 원본 삽입과 `restore_receipts`/`raw_restore_receipts`는 같은 SQLite 트랜잭션입니다. bootstrap은 snapshot 공개 전에 pending 복원을 확정하거나 동일한 신규 원본만 rollback하며, 필요한 저장소가 없으면 journal을 지우지 않습니다. 원본 DB·App Group 경로·facade는 바꾸지 않습니다.
- 과거 snapshot에 연결된 V1–V3 월은 수동 백업에서 보호된 migration journal을 사용해 V4 불변 세대로 변환하며 원본을 유지합니다. raw-only legacy 월, V1–V3 단일 GCM의 strict streaming, 실제 peak memory는 아직 별도 미완료 기준입니다. CloudKit은 Debug Development만 자동 활성화되며, CAS의 본문 재병합·pending 참조·보존 정책은 실제 두 기기 검증과 구분합니다.

## 비용이 큰 경로를 찾을 때

전체 snapshot의 변경 여부는 연결의 변경 토큰으로 먼저 확인합니다. 다른 연결은 [data_version](https://www.sqlite.org/pragma.html#pragma_data_version), 같은 연결은 [total_changes64](https://www.sqlite.org/c3ref/total_changes.html)로 감지하며 연결 간 토큰을 비교하지 않습니다. 토큰은 SELECT 전에 읽습니다. `repository_local_load`는 SQL 읽기·작은 영역 검증·모델 생성 시간과 `actual_rows_read`를 기록합니다. `repository_local_save`는 읽기·모델 변환·SQL 쓰기·작은 영역 검증 시간, `compared_actual_records`·`written_actual_records`를 기록합니다. 대량 가져오기의 `write_ms`는 바인딩용 evidence 변환과 인덱스 구성도 포함합니다. 개별 시간 필드를 실제 디스크 I/O나 UI 지연과 동일시하지 않습니다.

일자 지도 문서의 생성·재계산은 `actuals(in:matching:)`으로 현재 확정 원본에 대응하는 날짜만 읽습니다. 저장 전 수정, 외부 변경 또는 메모리 압력으로 원본 일치가 보장되지 않으면 캡처한 메모리 원본을 사용하며 오래된 비동기 결과는 revision으로 폐기합니다. `repository_actual_range`에는 조회 건수·전체 건수·경과 시간만 기록합니다. 이미 완성된 일자 캐시의 조회는 정본 DB를 추가로 읽지 않습니다. 전체 앱 초기 로드·portable 백업·일괄 분석은 여전히 전체 모델을 구성하며, 일반 배열 변경의 비교와 전체 재정렬은 전체 건수에 비례합니다. 단건 API의 저장 시간은 Swift 배열 복사·화면 갱신을 포함한 전체 편집 지연과 구분합니다.

활동 전체 조회는 SQLite cursor를 한 번 순회하면서 최종 모델과 행 키를 만듭니다. 중간 전체 `ActualRow` 배열을 유지하지 않으며 순서·건수·원본 해석 오류나 취소는 부분 결과를 반환하지 않습니다. 날짜 조회는 같은 WAL 읽기 트랜잭션에서 generation·revision·root를 확인한 뒤 RTree로 `position`만 조회하고, 이미 확정한 불변 배열의 해당 항목을 반환합니다. 범위 조회에서 제목·evidence를 다시 읽거나 decode하지 않습니다. 전체 조회의 `read_ms`에는 cursor의 모델 변환도 포함되므로 이전 기록의 SQL/변환 분리 시간과 직접 비교하지 않습니다.

전체 cursor의 제목·분류·출처·확신도·행동·모델 버전과 evidence는 열마다 최대 4KiB 값 하나만 재사용합니다. SQLite의 원문 바이트와 정확히 같을 때만 기존 값을 돌려주며 Unicode 정규화 동등성으로 대체하지 않습니다. 캐시는 조회 종료/오류 시 폐기하며, 큰 값이나 다른 원문은 다시 읽고 검증합니다.

센서 조회는 `TimeSpan.contains`와 같은 양 끝 포함 조건을 SQL의 `domain`·`timestamp` 범위에 전달합니다. 날짜 키를 만든 시간대가 바뀌어도 실제 시각이 범위 안이면 가져옵니다. `events_domain_timestamp_index`는 기존 대형 DB의 동기 초기화를 늦추지 않도록 저장소 actor의 첫 범위 조회 때 생성하고, 이후 재사용합니다. payload decode 후 원래 시각 필터·원본 복구·generation·취소 검사는 유지합니다. 한 날짜 전체를 읽고 Swift에서 대부분을 버리는 경로는 사용하지 않습니다.

시작 화면은 복원 journal·잠금·접근 상태를 확인하고 설정 및 지도 shell이 준비되면 열린다. 초기 진행 표시는 0.36 → 0.86 목표에 닿아도 준비가 끝나지 않았으면 0.97까지 계속 올라가고, 준비가 끝난 뒤 1.0으로 마무리합니다(`AppShellInitialLaunchProgressMath`, `AppShellView`). SQLite의 `loadStartupSnapshot()`은 metadata·settings·categories만 읽으며 전체 이력의 성공을 보증하거나 조회 캐시에 빈 이력을 넣지 않는다. pending 복원 journal·legacy 저장소·설정 읽기 실패 때는 기존 전체 로드 절차를 따른다. 전체 로드 전 일자 DB preview는 읽기 전용이며 편집·저장을 차단한다. 전체 로드 실패 때도 기존 원본 덮어쓰기 차단을 유지한다. `prepareLocalDataForDisplay()`는 전체 로컬 원본까지만 기다리고, 데이터 변경에 쓰는 `bootstrap()`은 기록 정리·저장 완료까지 기다린다. 정리 worker는 현재 revision과 일치하는 결과만 반영하며 그 결과를 메인 actor에서 다시 정리하지 않는다. `startup_settings_ready`, `initial_launch_ready`, `bootstrap_local_snapshot` / `bootstrap_preparation`으로 설정·화면 진입·전체 로드·정리 시간을 구분한다.

권한 새로고침의 동시 요청은 한 작업을 기다립니다. 조회가 끝난 뒤 최신 settings에 실제 변경만 반영하고, 동일 상태의 권한·센서 상태를 다시 공개하거나 저장하지 않습니다. 지도 일자 revision이 같으면 fingerprint를 만들지 않으며, 현재 활동 캐시는 해당 시각의 기록·이동·체류·근접 이동 센서·Watch 수면 근거만 hash합니다. 활성 원본의 모든 필드는 비교에 포함합니다.

GPS 경로는 낮은 정확도의 경계 표본도 시간·거리 검사를 거치며, 급이탈을 거른 뒤에도 마지막 정상 위치를 비교 기준으로 유지합니다. 정지 표본을 줄일 때 마지막 시각과 15분 이하의 경로 체크포인트를 남깁니다. 현재 위치 마커는 일자 worker가 검증한 위치를 사용합니다. 원본 저장 형식은 그대로이며 파생 일자 projection은 버전 3, 지도 문서 캐시 키는 `route-document-v9`입니다.

분홍 발자국은 경로 좌표에 대응하는 시각을 캐시에 함께 보존합니다. 탭한 시점의 지도 좌표 변환으로 발자국을 고르고 재생·현재 위치 추적·대기 중인 위치 요청을 멈춘 뒤 초 단위 시각과 위치로 이동합니다. 회색 발자국은 전체 예상 경로와 연결하며 선택 시 강조와 변경/삭제 메뉴를 엽니다. 변경은 전체 좌표·구간·예상 좌표 출처를 사용자 확정으로 저장하고, 삭제는 해당 경로의 제외 결정을 저장합니다. 저장 후 공개하며 실패 시 경로/메뉴를 유지합니다. 이동 ID 재생성·좌표 재계산 뒤에도 선택을 적용하고, 실제 원본 센서는 수정하지 않습니다. 확정 경로의 분홍 발자국 시각은 저장된 구간의 거리 비례 시각이며 센서에서 직접 관측한 시각으로 취급하지 않습니다. 화면 시각이 다른 오래된 회색 tap 입력을 버리며 지도 드래그·확대 제스처는 지도 렌더러가 처리합니다.

발자국 표시 상한은 전체 220개입니다. 거리 간격 후보를 경로 끝까지 만든 뒤 전체 구간에 고르게 나누고, 경로별 표시 수를 순환 배정하여 앞선 긴 경로가 이후 경로를 지우지 않게 합니다. 한 개만 배정되면 마지막 좌표를 사용하고 경로 수가 상한을 넘으면 최근 시각의 경로부터 남깁니다. 예상·사용자 확정 추정 경로에는 먼저 최대 96개를 예약하고, 관측 경로의 남는 표시 수를 재사용합니다. 화면 발자국·지도 좌표 변환 마커·탭 판정은 같은 샘플 목록을 사용합니다. 지도 배율에 따른 한도 변경이나 원본 기록 삭제는 하지 않습니다.

벡터 지도의 경로는 스타일이 먼저 준비되거나 다시 로드돼도 소스·레이어를 확인해 복구합니다. 점선에는 gradient용 거리 metrics를 사용하지 않습니다. 일자 입력이 준비 중이면 같은 날의 확정된 표시를 유지하고, 준비된 revision의 빈 경로만 삭제로 반영합니다. 지하철 탑승 결정에는 선택 당시의 검증된 역 노선 좌표와 추정 근거를 저장합니다. 저장소 쓰기가 끝난 뒤 화면에 공개하며 재분석 시 같은 이동의 사용자 확정 경로·시각을 유지합니다.

탑승 결정은 선택한 이동 ID 또는 유일하게 일치하는 저장 구간에만 재적용합니다. 현재 다른 이동에 이미 연결된 노선을 ID 재생성의 fallback으로 가져오지 않습니다. 확정 취소·수단 변경 때 해당 이동의 이전 탑승 결정과 사용자 확정 노선 근거를 정리하며 같은 결정의 다른 이동은 보존합니다. 후보 삭제도 쓰기 완료와 최신 revision 확인 후 공개하고 실패 시 화면을 유지합니다.

지도 화면 진입과 백그라운드에서 활성 상태로 복귀할 때 중심·방향·기울기를 유지하고 초기 카메라 거리 3,000m를 적용합니다. 일시적인 inactive 전환과 사용 중 화면 갱신은 수동 배율을 유지합니다. 벡터 지도 크기가 0이면 카메라 명령의 revision을 소비하지 않고 첫 렌더링 프레임에서 재시도합니다. 비활성 상태 또는 이전 카메라 revision의 화면 콜백은 복귀 배율을 덮지 못합니다.

백업 manifest의 복호화·병합은 `PlanManifestBodyPreparation` actor가 세대를 순서대로 처리합니다. raw 암호문을 한 세대씩 전달하고 임시 Foundation 객체는 변환 구간에서 해제합니다. 호출자는 각 반환과 최종 저장 전에 PIN·취소·삭제 fence를 확인합니다. `backup_manifest_prepare`는 시간·개수·메인 스레드 여부만 기록하며 원본 자료를 기록하지 않습니다.

월별 백업의 저장 후 identity 검증은 JSON에 기록되는 `createdAt.timeIntervalSince1970` 값을 비교합니다. Date 내부 epoch의 추가 정밀도를 파일 왕복 값과 직접 비교하면 정상 암호문도 무결성 오류가 됩니다. digest·계정·세대·취소/삭제 검증은 유지합니다.

기록 공백은 경로 선분을 나누는 조건이며 GPS 타당성 검사를 생략하는 조건이 아닙니다. 공백 중 관측되지 않은 이동수단을 고려해 공백용 최대 속도는 별도로 검사합니다. 필터 변경 시 일자 projection version과 지도 algorithm key를 함께 올려 파생 값만 재계산하며 센서 정본은 보존합니다.

HealthKit 운동 경로를 보완할 때는 기존 위치와 20초 시간 중복을 제외한 뒤, 합친 시간순 경로로 위치 타당성을 검사합니다. 반환하는 보완 표본은 검사 통과 ID의 원래 값이며 저장 원본은 바꾸지 않습니다. 백그라운드 `sensor_timeline_evidence_loaded`의 `quality_rejections`는 수치 품질 판정 합계이고, `impossible_location_count`/`innovation_outlier_count`는 별도의 센서 경로 거부 건수입니다. 좌표나 장소 이름은 이 진단에 기록하지 않습니다.

백그라운드 전환은 지도 선계산과 메모리 캐시를 정리하며 운동 구간 종료와 지속 수집 종료를 구분합니다. `SystemDiagnostics.swift`는 앱 target에만 포함합니다. MetricKit은 iOS가 실제 제공한 종료 집계/숫자 코드만 기록하고 원문 예외·스택은 내보내지 않습니다. 이전 종료 콜백의 부재는 crash 확정 근거가 아니며 마지막 scene 단계와 OS 진단을 함께 확인합니다.

`python3 scripts/runtime-code-inventory.py`는 제품 Swift 파일의 위치·길이·import와 정렬/필터/입력 콜백 위치 수를 출력합니다. 생성물과 캐시는 검색하지 않습니다. 이 수치는 탐색용이며 실제 병목 판정은 측정으로 합니다.

- `TaptionBoundedCache`는 actor 또는 MainActor 소유자가 동기 접근합니다. 조회는 O(1), 용량 초과 삽입 때만 제한된 항목을 검사합니다. `peek`은 recency를 바꾸지 않으며 메모리 압력 시 소유자가 비웁니다.
- `AppModel`의 일자 fingerprint 캐시는 actuals/places/travel 변경 revision에 연결합니다. 캡처한 revision이 현재와 다르면 비동기 결과를 캐시에 넣지 않습니다. `PlanDayLoadCoordinator`에 공급하는 fingerprint는 동일하게 캡처한 source의 값이어야 합니다.
- 지도는 날짜·source revision이 바뀔 때 utility worker에서 불변 일자 입력을 준비합니다. 준비 중 전체 과거 이력으로 돌아가지 않으며 UI의 유효성 확인은 revision·날짜·projection version만 비교합니다. 카메라 좌표 콜백에는 준비된 활동·재생 정보를 전달합니다.
- 재생·시간축 선택의 마커와 카메라는 `MapHomePlaybackLocation`에서 같은 시각으로 조회합니다. 현재 frame(수면 포함)·확정 지하철·표시 중 예상 경로를 반영하고 나머지는 준비된 일자 GPS를 이진 탐색합니다. 시각 없는 위치 캐시·그리기용 경로 cutoff로 돌아가지 않으며 미래 첫 표본이나 다른 날짜 표본을 현재 선택 시각의 GPS로 사용하지 않습니다. 위치 조회마다 전체 센서 정렬·수면 anchor 계산을 반복하지 않습니다. 네 갈래가 모두 비어 화랑이가 사라지는 구간은 이동 구간의 출발·도착 장소 좌표를 시각 비율로 보간합니다(`resolveOrGap`, `MapHomePlaybackContinuity.swift`). 장소 좌표가 없으면 좌표를 지어내지 않고 표시하지 않습니다.
- 재생 배속은 이동 수단이 아니라 **대분류**로 정합니다(`MapHomePlaybackCategoryRanges`). 대분류 '이동'은 이동 배속(걷기는 3배), 수면·업무·식사·취미·운동·활동은 정지 배속입니다. 확정 여부와 센서 유무는 배속을 바꾸지 않으며, 미확인 이동도 이동 구간으로 재생합니다.
- 지도 카운터는 재생 중에는 재생 시각까지로 잘라 세어(`MapHomeCounterTimelinePolicy`) 시간을 따라 올라갑니다. 하루 전체 합계는 1분 버킷으로 캐시(`MapHomeCounterValueCache`)해 30Hz 재생 틱마다 하루 phase를 다시 계산하지 않습니다. 표시 형태는 `MapHomeCounterTable`이 정합니다(1줄=알약, 2줄 이상=한 상자에 줄을 붙여 세로로 길어짐). 연봉도 **같은 상자의 마지막 줄**(머리에 가장 가까운 줄)로 넣습니다. 알약을 따로 띄우고 그 위에 표를 쌓으면 두 덩어리로 보이므로, 창은 하나만 세웁니다. 연봉이 들어가면 값이 `1,234,567원`까지 길어져 창 폭을 132→176pt로 넓힙니다.
- 잠금화면·다이나믹 아일랜드의 현재 활동 이름·아이콘은 앱 화면과 같은 시간 레일 엔진(`MapHomeTimeRailSegmentEngine`)에서 읽습니다. 잠금 상태이거나 그 시각에 미확인뿐이면 기존 '확인 중' 표시로 물러섭니다.
- 클립 편집기(`MapHomeNLEClipEditor`)는 경계를 고르지 않은 클립에서도 다듬기로 받습니다. 대분류 경계는 `NLETrack.roll`로 **양쪽 끝을 함께** 밉니다(롤 편집). 한쪽이 늘어난 만큼 맞닿은 이웃이 줄고 빈 시간은 생기지 않으며, 클립은 자기 원본 구간을 넘어설 수 있습니다. 넘어선 시간은 `editRequests`가 그 시간을 소유한 이웃 구간의 `cover` 조각으로 실어 보내므로 원본 기록의 출처는 그대로 남습니다. 서브클립 줄은 자기 구간 안에서만 다듬습니다. 손잡이를 그릴 높이가 안 되는 짧은 클립(하루 전체 보기에서 1시간 남짓)은 자기 경계 대신 `shortClipBoundary`로 맞닿은 이웃의 경계를 넘겨받습니다 — 같은 경계라 어느 쪽에서 잡아도 결과가 같고, 이웃도 짧으면 집어 들기로 넘깁니다. 몸통은 0.4초를 누르고 있어야 집어 들고(`NLEReorderHoldPolicy`), 그 전에 18pt 넘게 움직이면 클립을 딸고 가지 않고 화면이 흐릅니다. 집어 든 클립은 그림자로 표시하고, 제자리에서 손을 떼면 되돌리기 흔적을 남기지 않습니다. 가장자리 자동 스크롤은 손가락이 닿은 깊이와 무관하게 60Hz 타이머로 360pt/s를 유지합니다. 같은 원본 구간 안에서 맞닿은 미확인 조각은 `NLETrack.normalized`가 하나로 합칩니다.
- 일자 DB는 원본 digest를 검증한 materialized 값을 한 번 읽고, source가 다르면 그 값의 raw로 다시 projection합니다. stale preview는 별도 읽기 계약을 유지합니다. 같은 날 source가 바뀌어 projection을 취소할 때 진행 중인 센서 원본 읽기는 공유합니다. raw 변경·삭제·전체 무효화·메모리 압력에는 원본 읽기도 취소합니다. 삭제 generation·취소·강제 raw 갱신을 우회하지 않습니다. Watch 원본 replay와 센서 결합·정렬은 utility worker에서 처리하고, 취소 로그는 원문 없이 호출 취소·generation 변경·archive 읽기 실패를 구분합니다.
- `DayPhaseEngine`은 하루 앞뒤35분의 근거 범위로 기록·이동·체류를 먼저 거른 뒤 제목 판정·장소 그룹을 계산합니다. 자정을 넘는 기록과 출퇴근 경계를 보존하고 원본을 수정하지 않습니다. 수면 위치도 날짜/cutoff 교집합을 확인한 뒤 기존 제목 판정을 적용합니다. 전체 과거 기록에 대한 반복 제목 검색을 화면 계산에 넣지 않습니다.
- `TaptionLatestValueProjection`과 `TaptionInputFrameGate`가 공통 입력 정책입니다. 동일 상태로 갱신 예산을 소비하지 않고, 종료 이벤트는 최종값을 즉시 반영합니다. UIKit/MapKit 제스처와 표시 좌표는 앱에 남깁니다.
- Release에서 패키지 경계를 넘는 제네릭 캐시가 특수화되도록 작은 조회 함수는 `@inlinable`입니다. Debug 측정만으로 성능 개선을 판단하지 않습니다. 공통 UUID 비교는 기존 대문자 UUID 문자열 순서와 같아 fingerprint 호환성을 유지합니다.

## 화면 규칙

- 지도 안개는 `MapHomeFogStrength`(끄기 0.0 · 옅게 0.28 · 진하게 0.55) 세 단계만 두고 `@AppStorage(MapHomeFogStrength.storageKey)`에 저장합니다. 기본은 옅게입니다. 걷어내는 반경(`revealRadius` 72pt · `currentLocationRadius` 96pt)과 세기는 `MapHomeFogLayer.swift`의 값 하나를 벡터 지도와 Apple 지도가 함께 씁니다. 지도 스타일을 추가해도 안개 정책을 따로 만들지 않습니다.
- 하단 1급 항목은 `달력 · 현재 위치 · 집 · 재생 · 녹화 · 메모` 여섯 개입니다. 메뉴만 좌상단 원형 버튼에 둡니다. 「녹화」는 재생 바로 오른쪽에 둡니다 — 재생을 마친 사람이 다음에 누르는 버튼이라 메뉴 안(메뉴 열기 → 화면 그룹)에 두면 그 자리에서 보이지 않습니다. 0f2987d에서 다섯 개로 줄이며 메뉴로 내렸다가 되돌렸습니다. 항목을 더 늘려야 하면 먼저 무엇을 내릴지 정합니다.
- 화면 항목을 되돌릴 때는 그때 대신 넣었던 줄도 함께 지웁니다. 하단에 「녹화」를 되살리면서 메뉴 > 화면의 「재생 화면 녹화」를 남겨 두면 같은 동작이 두 곳에 있어 어느 쪽이 정본인지 알 수 없습니다.
- 안내 알림은 말한 목적지로 갈 수 있는 버튼을 반드시 함께 둡니다. "메뉴 > 위치에서 등록하세요"라고 하면서 확인 버튼만 두지 않습니다(`openLocationSettings()`가 메뉴를 열고 해당 그룹을 펼칩니다).
- 글자·배지 색은 배경 대비 4.5:1(WCAG AA)을 지킵니다. 토큰을 바꾸면 `build/validation/UIX1025A01/contrast.py` 같은 계산으로 실제 조합을 확인하고, 눈으로 판단하지 않습니다. `tpSecondary`·`tpAccent`·`tpNow`는 9~10pt 글자와 흰 글자 배지에 쓰이므로 명도를 낮춰 맞춰 두었습니다.
- 화면 캡처로 판단할 때는 한 장에 기대지 않습니다. 시뮬레이터는 실행 직후 캡처가 검게 나올 수 있고, 알림·시트가 뒤 화면을 어둡게 만듭니다. 세기·밝기 비교는 같은 조건의 두 장을 평균 밝기로 재서 남깁니다.
- 클립 편집기 도구는 아이콘만 두지 않습니다. 이름을 아이콘 아래에 붙이고 높이 44pt를 지킵니다(`NLEToolButton`). 무엇을 하는 단추인지 눌러서 알아내게 만들지 않습니다.
- 하루 전체 배율에서는 1시간 클립도 9pt라 경계 손잡이가 나타나지 않습니다. 그래서 확대는 두 손가락만 두지 않고 도구 막대의 「확대 → 더 확대 → 전체」 단추로도 돌 수 있게 합니다(`NLEZoomPolicy`). 확대 단계를 바꾸면 고른 클립을 화면 가운데에 둡니다.
- 클립 줄처럼 화면 밖까지 넓혀 그리는 요소는 눈금 띠 너비에 넘친 폭(`railBleed`)을 더해야 합니다. 빼먹으면 30분 눈금 `08:30`의 앞자리가 화면 밖으로 밀려 `30`만 남습니다.
- 재생 헤드처럼 화면을 가로지르는 잡기 영역은 다른 잡기를 이기지 않습니다. 경계 16pt 안에서는 자르기가 먼저입니다(`isNearClipBoundary`).
- 되돌리기는 상태를 실제로 바꾼 뒤에만 쌓습니다. 지울 것이 없는데 쌓으면 눌러도 화면이 그대로인 빈 되돌리기가 생깁니다.
- 오른쪽 위 날짜 배지를 누르면 이번 주 날짜 줄이 펼쳐지고, 그 줄을 좌우로 밀면 **한 번에 하루**씩 넘어갑니다(`weekSwipeGesture`). 손가락이 움직인 거리에 비례해 넘기지 않습니다 — 줄 폭이 한 주(274pt)라 한 번 쓸면 6~7일이 지나, 손짓 하나가 '주 단위'로 보였습니다(대표 지적). 손가락은 한 칸까지만 따라오고, 반 칸(19pt)을 넘겨야 날짜가 바뀝니다. 줄과 배지는 화면 시험에서 집을 수 있게 `mapHomeDateWeekStrip`·`mapHomeDateBadge` 식별자를 둡니다(배지의 접근성 이름에는 날짜가 들어 있어 날마다 달라집니다).
- 여러 개로 나뉜 클립은 「전체 덮기」로 한 번에 바꿉니다(`MapHomeNLEOverwriteSheet` · `NLEOverwritePolicy`). 클립마다 분류를 하나씩 고르게 하면 센서가 잘게 나눈 하루는 손으로 고칠 수 없습니다. 범위는 **하루 전체 / 같은 분류만** 둘입니다 — 「지금 보이는 구간」은 두지 않습니다. 이 편집기는 하루를 세로로 세운 타임라인이라 같은 손짓이 배율에 따라 다른 시간을 덮게 됩니다. `NLETrack.overwrite`는 `parent.sourceIDs`가 빈 시간(기록 없이 채운 구멍)을 건드리지 않고, 이미 같은 분류인 클립을 다시 세지 않습니다. 창이 보여 주는 수는 `NLEOverwritePolicy.affectedCount`가 실제로 바꾸는 수와 같은 함수에서 나옵니다.
- 덮기와 합치기는 **한 창**에 둡니다. BOKKI STUDIO의 자막 합치기와 같은 자리이고, 덮은 뒤 같은 분류가 된 이웃을 붙이는 것이 실제로 원하는 결과입니다. `NLETrack.mergeAdjacent`는 `origin`이 이어져 있으면 합친 구간으로 넓히므로 가르기→합치기는 저장할 것이 없는 왕복이 되고, 한쪽이라도 분류를 바꿨으면 합쳐진 구간 전체가 바뀐 것으로 남습니다. 합칠 곳이 없으면 「합치기만」을 내밀지 않습니다.
- 하루 재생은 하루를 24초에 지나갑니다(정지 120분/초). 재생 화면을 시험할 때는 하루 끝까지 남은 구간을 먼저 셉니다. 남은 구간이 짧으면 재생이 1초 만에 스스로 끝나 단추 상태를 볼 수 없고, 이때 「종료」는 진행을 되돌리지 않습니다(`resetProgress`는 저장만 건너뜁니다). 앱이 멈춘 것으로 오해하지 않도록, 두 번째 재생은 앱을 새로 켜 자정부터 시작합니다.

## 검증 명령

집 성장 그림은 `HomeEvolution001...366` 자산명과 기존 저장 레벨을 유지합니다. `scripts/home_evolution_artwork_manifest.json`이 승인한 122종 × 3레벨 원본 해시와 매핑을 기록합니다. `python3 scripts/generate_home_evolution_artwork.py --check`로 현재 자산을 대조하고, `--write`는 manifest에 지정된 디자인 원본을 기존 자산에 반영합니다. 512px 출력 원본의 내부 도형/viewBox를 유지하며 앱 벡터 기준 크기는 128pt, vector representation은 보존합니다. 성장·보상 회귀와 실제 번들 그림의 48pt 렌더 검사는 `MapHomeGrowthPolicyTests`에 있습니다.

현재 scheme과 target은 프로젝트에서 확인합니다.

```sh
xcodebuild -list -project TaptionPlan.xcodeproj
```

바꾼 공유 package만 테스트합니다. 예를 들어 저장 계약 변경은 다음 명령을 사용합니다.

```sh
swift test --package-path Packages/TaptionPlanCore
```

앱 Debug 빌드는 generic iOS destination으로 실행합니다. 아래 플래그는 현재 검증 기록에 사용한 Swift macro sandbox 우회입니다. 프로젝트의 기존 DerivedData를 재사용하고 실패하면 첫 관련 오류만 확인합니다.

```sh
xcodebuild build -project TaptionPlan.xcodeproj -scheme TaptionPlan \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath build/ArchiveDD -skipPackagePluginValidation \
  COMPILER_INDEX_STORE_ENABLE=NO \
  OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox'
```

Watch 코드를 바꾼 경우 Watch scheme도 별도로 빌드합니다.

```sh
xcodebuild build -project TaptionPlan.xcodeproj -scheme TaptionPlanWatch \
  -configuration Debug -destination 'generic/platform=watchOS' \
  -derivedDataPath build/ArchiveDD -skipPackagePluginValidation \
  COMPILER_INDEX_STORE_ENABLE=NO \
  OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox'
```

빌드 번호는 project setting만 바꾸면 충분하지 않습니다. 앱·iPhone 위젯·Watch 앱·Watch 위젯 네 `Info.plist`의 고정 `CFBundleVersion`도 같은 값이어야 합니다. 현재 iPhone 배포에는 앱·iPhone Widget 두 제품만 포함하며 Watch 디렉터리가 없어야 합니다. 독립 Watch target의 원본 번호도 일치시키되 Watch 제품을 배포에 추가하지 않습니다. 설치·TestFlight 전 최종 `.app`/`.appex`의 `CFBundleIdentifier`와 `CFBundleVersion`을 읽어 확인하세요. `CURRENT_PROJECT_VERSION`과 산출물 번호가 일치한다고 가정하지 않습니다.

실기기 설치본 버전은 `xcrun devicectl device info apps --device "$DEVICE_ID" --bundle-id com.taption.plan`으로 읽습니다. 설치 및 앱 실행만으로 권한, 저장, 센서, 계정 기능을 통과 처리하지 않습니다.

앱 테스트는 현재 사용 가능한 Simulator UDID를 먼저 조회하고 관련 테스트만 선택합니다. 매 실행마다 요청 ID 아래 새 result bundle 경로를 사용합니다.

```sh
xcrun simctl list devices available
mkdir -p "build/validation/$TASK_ID"
xcodebuild test -project TaptionPlan.xcodeproj -scheme TaptionPlan \
  -configuration Debug -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  -derivedDataPath build/ArchiveDD \
  -resultBundlePath "build/validation/$TASK_ID/app-tests.xcresult" \
  -only-testing:TaptionPlanTests/$TEST_CLASS
```

`TASK_ID`는 요청의 10자리 ID, `SIMULATOR_UDID`는 위 목록의 값, `TEST_CLASS`는 변경에 맞는 테스트 클래스로 설정합니다. 전체 앱 테스트를 실행했다면 xcresult의 실제 테스트 수·실패·건너뜀을 확인합니다. 시뮬레이터 결과는 설치·실기기 기능 검증이나 TestFlight 결과를 뜻하지 않습니다.
