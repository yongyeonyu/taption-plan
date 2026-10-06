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
| SQLite 저장·일자 DB·암호화 백업 | `TaptionPlan/Core/PlanRepository.swift`, `PlanDayDatabase.swift`, `SecurityBackupCore.swift` |
| 활동 기록의 행 저장·증분 변경·시간 인덱스 | `Packages/TaptionPlanCore/Sources/TaptionPlanCore/ActualRecordStore.swift`, `TaptionPlan/Core/PlanActualStorage.swift` |
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
- `TaptionPlanCore`의 정본 Codable envelope는 현재 포맷만 읽고 변환을 한 번만 수행합니다. `SecurityBackupCore` 백업 포맷의 legacy read 경로는 별도 계약이므로 포맷 작업 때 구분해 확인하세요.
- 활동 기록은 `actual_records`의 형식 있는 SQLite 열에 저장합니다. UUID와 중복 출현 순서로 행 키를 만들고 별도 `position`으로 원래 배열 순서를 보존합니다. 시작/종료/생성 시각은 Foundation 기준 시각의 REAL로 저장하며, 제목·분류·연결·source·confidence·provenance·분류 잠금은 별도 열입니다. 가변 evidence만 현재 정본 codec으로 저장합니다. `plan.actuals`에는 형식 버전과 건수만 남고, 이전512건 배열 분할/manifest/원본 중복 테이블은 사용하지 않습니다.
- `actual_record_ranges`의1차원 RTree가 겹치는 시간 구간을 찾습니다. Float 경계의 바깥 반올림으로 얻은 후보를 원래 REAL 시각으로 다시 제한하므로 자정·소수점 경계·진행 중 기록을 유지합니다. 조회는 revision과 행을 같은 WAL 읽기 트랜잭션에서 가져옵니다. DB 트리거가 행 삽입/수정/삭제 시 시간 인덱스와 활동 revision을 함께 갱신합니다.
- `SQLitePlanRepository`는 마지막 확정 snapshot 하나와 영역별 검증 정보·활동 revision·행 키를 재사용합니다. 같은 연결의 `data_version`·`total_changes64`와 삭제 generation이 같으면 payload를 읽지 않습니다. 외부 변경은 작은 snapshot 영역의 바이트와 활동 revision으로 구분하며, 센서·설정만 바뀌면 활동 전체를 다시 읽지 않습니다. 메모리 압력·삭제·로드 실패 때 캐시를 비우고 오래된 계산이 다시 채우지 못하게 합니다.
- `PlanActualEdit`는 불변 원본 배열과 한 건만 바꾼 결과 배열을 묶습니다. 저장소의 확정 배열과 입력 결과가 각각 같은 저장 공간을 공유할 때만 단건 UPSERT를 사용합니다. 다른 수정이 섞였거나 외부 revision이 바뀌면 전체 변경 비교로 돌아가며 변경된 행만 저장합니다. 루틴/계획 연결은 이 API를 사용합니다. 시작 정리 worker는 내용이 바뀌지 않은 활동 배열의 저장 공간을 유지해 이 경로와 범위 조회가 끊기지 않게 합니다. 원본이 없는 전체 가져오기는512행 단위로 SQLite 바인딩을 만듭니다. 같은 트랜잭션 안에서 행별 인덱스 트리거를 잠시 제거하고 정본 행을 넣은 뒤 SQL 한 번으로 RTree를 구성하고 트리거를 복구합니다. 활동 revision도 한 번 올리고 metadata와 함께 확정합니다. 중간 스키마는 다른 연결에 공개되지 않으며 DDL도 rollback 대상입니다. 오류·취소는 전부 rollback합니다.
- 기존 배포본의 활동 배열은 최초 로드에서 한 번만 typed 행으로 이관합니다. 이관과 작은 형식 header 교체를 같은 트랜잭션에서 수행하며 중복 원본은 유지하지 않습니다. 구버전 앱의 DB 읽기/쓰기는 지원하지 않습니다. 개발 단계에서만 사용했던 B01 묶음 형식도 지원하지 않습니다. 실제 사용자 DB·백업 파일을 작업 도구로 삭제하거나 변환하지 않습니다. 다른 작은 snapshot 영역과 portable 백업의 현재 모델은 유지합니다.
- 백업 포맷·암호화·체크섬·세대 참조를 바꾸기 전에는 현재 구현과 요청 기록을 확인합니다. 읽기 호환·복원·rollback 기준 없이 기존 백업을 제거하거나 변환하지 않습니다.

- 앱의 복원 메뉴는 `loadLatestBackupPackage(streamRaw: true)`로 V4 raw 암호문을 파일 페이지로 읽고 `PlanStagedRawRestore`의 SQLite cursor를 최대 256행/기본 1MiB씩 소비합니다. 단일 항목은 하드 4MiB 제한입니다. 기존 `.available(payload)`는 호환·진단 경로이며 전체 배열을 반환합니다.
- `RestoreStaging/restore-journal.sqlite`에는 target snapshot digest·세션·필요 저장소·삭제 generation을 기록합니다. 원본 삽입과 `restore_receipts`/`raw_restore_receipts`는 같은 SQLite 트랜잭션입니다. bootstrap은 snapshot 공개 전에 pending 복원을 확정하거나 동일한 신규 원본만 rollback하며, 필요한 저장소가 없으면 journal을 지우지 않습니다. 원본 DB·App Group 경로·facade는 바꾸지 않습니다.
- 과거 snapshot에 연결된 V1–V3 월은 수동 백업에서 보호된 migration journal을 사용해 V4 불변 세대로 변환하며 원본을 유지합니다. raw-only legacy 월, V1–V3 단일 GCM의 strict streaming, 실제 peak memory는 아직 별도 미완료 기준입니다. CloudKit은 Debug Development만 자동 활성화되며, CAS의 본문 재병합·pending 참조·보존 정책은 실제 두 기기 검증과 구분합니다.

## 비용이 큰 경로를 찾을 때

전체 snapshot의 변경 여부는 연결의 변경 토큰으로 먼저 확인합니다. 다른 연결은 [data_version](https://www.sqlite.org/pragma.html#pragma_data_version), 같은 연결은 [total_changes64](https://www.sqlite.org/c3ref/total_changes.html)로 감지하며 연결 간 토큰을 비교하지 않습니다. 토큰은 SELECT 전에 읽습니다. `repository_local_load`는 SQL 읽기·작은 영역 검증·모델 생성 시간과 `actual_rows_read`를 기록합니다. `repository_local_save`는 읽기·모델 변환·SQL 쓰기·작은 영역 검증 시간, `compared_actual_records`·`written_actual_records`를 기록합니다. 대량 가져오기의 `write_ms`는 바인딩용 evidence 변환과 인덱스 구성도 포함합니다. 개별 시간 필드를 실제 디스크 I/O나 UI 지연과 동일시하지 않습니다.

일자 지도 문서의 생성·재계산은 `actuals(in:matching:)`으로 현재 확정 원본에 대응하는 날짜만 읽습니다. 저장 전 수정, 외부 변경 또는 메모리 압력으로 원본 일치가 보장되지 않으면 캡처한 메모리 원본을 사용하며 오래된 비동기 결과는 revision으로 폐기합니다. `repository_actual_range`에는 조회 건수·전체 건수·경과 시간만 기록합니다. 이미 완성된 일자 캐시의 조회는 정본 DB를 추가로 읽지 않습니다. 전체 앱 초기 로드·portable 백업·일괄 분석은 여전히 전체 모델을 구성하며, 일반 배열 변경의 비교와 전체 재정렬은 전체 건수에 비례합니다. 단건 API의 저장 시간은 Swift 배열 복사·화면 갱신을 포함한 전체 편집 지연과 구분합니다.

센서 조회는 `TimeSpan.contains`와 같은 양 끝 포함 조건을 SQL의 `domain`·`timestamp` 범위에 전달합니다. 날짜 키를 만든 시간대가 바뀌어도 실제 시각이 범위 안이면 가져옵니다. `events_domain_timestamp_index`는 기존 대형 DB의 동기 초기화를 늦추지 않도록 저장소 actor의 첫 범위 조회 때 생성하고, 이후 재사용합니다. payload decode 후 원래 시각 필터·원본 복구·generation·취소 검사는 유지합니다. 한 날짜 전체를 읽고 Swift에서 대부분을 버리는 경로는 사용하지 않습니다.

시작 화면은 복원 journal·잠금·접근 상태를 확인하고 설정 및 지도 shell이 준비되면 열린다. SQLite의 `loadStartupSnapshot()`은 metadata·settings·categories만 읽으며 전체 이력의 성공을 보증하거나 조회 캐시에 빈 이력을 넣지 않는다. pending 복원 journal·legacy 저장소·설정 읽기 실패 때는 기존 전체 로드 절차를 따른다. 전체 로드 전 일자 DB preview는 읽기 전용이며 편집·저장을 차단한다. 전체 로드 실패 때도 기존 원본 덮어쓰기 차단을 유지한다. `prepareLocalDataForDisplay()`는 전체 로컬 원본까지만 기다리고, 데이터 변경에 쓰는 `bootstrap()`은 기록 정리·저장 완료까지 기다린다. 정리 worker는 현재 revision과 일치하는 결과만 반영하며 그 결과를 메인 actor에서 다시 정리하지 않는다. `startup_settings_ready`, `initial_launch_ready`, `bootstrap_local_snapshot` / `bootstrap_preparation`으로 설정·화면 진입·전체 로드·정리 시간을 구분한다.

권한 새로고침의 동시 요청은 한 작업을 기다립니다. 조회가 끝난 뒤 최신 settings에 실제 변경만 반영하고, 동일 상태의 권한·센서 상태를 다시 공개하거나 저장하지 않습니다. 지도 일자 revision이 같으면 fingerprint를 만들지 않으며, 현재 활동 캐시는 해당 시각의 기록·이동·체류·근접 이동 센서·Watch 수면 근거만 hash합니다. 활성 원본의 모든 필드는 비교에 포함합니다.

GPS 경로는 낮은 정확도의 경계 표본도 시간·거리 검사를 거치며, 급이탈을 거른 뒤에도 마지막 정상 위치를 비교 기준으로 유지합니다. 정지 표본을 줄일 때 마지막 시각과 15분 이하의 경로 체크포인트를 남깁니다. 현재 위치 마커는 일자 worker가 검증한 위치를 사용합니다. 원본 저장 형식은 그대로이며 파생 일자 projection은 버전 2, 지도 문서 캐시 키는 `route-document-v8`입니다.

분홍 발자국은 경로 좌표에 대응하는 시각을 캐시에 함께 보존합니다. 탭한 시점의 지도 좌표 변환으로 가장 가까운 분홍 발자국을 고르고 재생·현재 위치 추적·대기 중인 위치 요청을 멈춘 뒤 초 단위 시각과 위치로 이동합니다. 회색 예상 발자국은 시간 선택 대상에서 제외하며 지도 드래그·확대 제스처는 지도 렌더러가 처리합니다.

백업 manifest의 복호화·병합은 `PlanManifestBodyPreparation` actor가 세대를 순서대로 처리합니다. raw 암호문을 한 세대씩 전달하고 임시 Foundation 객체는 변환 구간에서 해제합니다. 호출자는 각 반환과 최종 저장 전에 PIN·취소·삭제 fence를 확인합니다. `backup_manifest_prepare`는 시간·개수·메인 스레드 여부만 기록하며 원본 자료를 기록하지 않습니다.

`python3 scripts/runtime-code-inventory.py`는 제품 Swift 파일의 위치·길이·import와 정렬/필터/입력 콜백 위치 수를 출력합니다. 생성물과 캐시는 검색하지 않습니다. 이 수치는 탐색용이며 실제 병목 판정은 측정으로 합니다.

- `TaptionBoundedCache`는 actor 또는 MainActor 소유자가 동기 접근합니다. 조회는 O(1), 용량 초과 삽입 때만 제한된 항목을 검사합니다. `peek`은 recency를 바꾸지 않으며 메모리 압력 시 소유자가 비웁니다.
- `AppModel`의 일자 fingerprint 캐시는 actuals/places/travel 변경 revision에 연결합니다. 캡처한 revision이 현재와 다르면 비동기 결과를 캐시에 넣지 않습니다. `PlanDayLoadCoordinator`에 공급하는 fingerprint는 동일하게 캡처한 source의 값이어야 합니다.
- 지도는 날짜·source revision이 바뀔 때 utility worker에서 불변 일자 입력을 준비합니다. 준비 중 전체 과거 이력으로 돌아가지 않으며 UI의 유효성 확인은 revision·날짜·projection version만 비교합니다. 카메라 좌표 콜백에는 준비된 활동·재생 정보를 전달합니다.
- 일자 DB는 원본 digest를 검증한 materialized 값을 한 번 읽고, source가 다르면 그 값의 raw로 다시 projection합니다. stale preview는 별도 읽기 계약을 유지합니다. 같은 날 source가 바뀌어 projection을 취소할 때 진행 중인 센서 원본 읽기는 공유합니다. raw 변경·삭제·전체 무효화·메모리 압력에는 원본 읽기도 취소합니다. 삭제 generation·취소·강제 raw 갱신을 우회하지 않습니다. Watch 원본 replay와 센서 결합·정렬은 utility worker에서 처리하고, 취소 로그는 원문 없이 호출 취소·generation 변경·archive 읽기 실패를 구분합니다.
- `DayPhaseEngine`은 하루 앞뒤35분의 근거 범위로 기록·이동·체류를 먼저 거른 뒤 제목 판정·장소 그룹을 계산합니다. 자정을 넘는 기록과 출퇴근 경계를 보존하고 원본을 수정하지 않습니다. 수면 위치도 날짜/cutoff 교집합을 확인한 뒤 기존 제목 판정을 적용합니다. 전체 과거 기록에 대한 반복 제목 검색을 화면 계산에 넣지 않습니다.
- `TaptionLatestValueProjection`과 `TaptionInputFrameGate`가 공통 입력 정책입니다. 동일 상태로 갱신 예산을 소비하지 않고, 종료 이벤트는 최종값을 즉시 반영합니다. UIKit/MapKit 제스처와 표시 좌표는 앱에 남깁니다.
- Release에서 패키지 경계를 넘는 제네릭 캐시가 특수화되도록 작은 조회 함수는 `@inlinable`입니다. Debug 측정만으로 성능 개선을 판단하지 않습니다. 공통 UUID 비교는 기존 대문자 UUID 문자열 순서와 같아 fingerprint 호환성을 유지합니다.

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
