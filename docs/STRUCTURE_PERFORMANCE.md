# 구조 성능 개선 안 목록 (ARC1103A01)

앱 전체 구조에서 성능을 깎는 곳을 재서 효과 순으로 정리한다. 적용 결과는 항목별 커밋과 아래 「적용 결과」에 남긴다.

## 측정 조건

| 근거 | 조건 | 한계 |
| --- | --- | --- |
| 기기 로그 | `CRS1101A01/bench/latest.txt`(아이폰 11 Pro, 2026-10-31~11-01). 세션 58회의 집계값만 쓴다 | 지난 빌드. 이번 작업으로 다시 재지 못했다(실기기 설치 안 함) |
| 측정 시험 | `TaptionPlanTests/StructurePerformanceProbeTests`(시뮬레이터 iPhone 17 Pro, Debug, 부하 큰 Mac). 합성 자료는 기기 로그의 행 수에 맞췄다: 장소 27,873 · 층 이동 3,640 · 활동 617 · 이동 342 | 절대값은 기기와 다르다. 전후 배율로 본다 |
| 타입 검사 | `-warn-long-function-bodies=400`, `-warn-long-expression-type-checking=400` | 다른 세션이 함께 빌드하는 중이라 값이 부풀었을 수 있다 |

## 재서 확인한 것

| 항목 | 값 | 뜻 |
| --- | --- | --- |
| 시작 저장소 읽기(기기) | 중앙값 1,630ms(읽기 581 · 해석 1,053), 상위 10% 3,727ms, 최대 12,591ms | 전체 32,950행 중 **장소가 27,873행(85%)** |
| 첫 화면 준비(기기) | 중앙값 3,046ms, 상위 10% 4,944ms | 저장소 읽기가 절반 이상 |
| `lifecycleModifiers` 타입 검사 | **43.0초**(`MapHomeView.swift:1391`) | `MapHomeView`를 고칠 때마다 든다 |
| `appLifecycleContent` 타입 검사 | **17.2초**(`AppShellView.swift:42`) | 같음 |
| 저장 뒤 시각만 바뀐 대입 | 관찰자 1회 발동, 지도 홈 본문 평가 10회/10쓰기, 58.4ms | 내용이 그대로인데 지도 홈 전체를 다시 평가한다 |
| 활동 등 내용이 바뀐 대입 | 본문 10회/10쓰기, 69.0ms | 정상 |
| GPS 새 값 | 본문 10회/10쓰기, 12.4ms | 회당 1.2ms |
| 저장(내용 그대로) | 62.3ms/회 | 저장 때마다 약 3만 건을 해시하고 id 문자열을 만든다. main 밖이지만 배터리를 쓴다 |
| 위젯 payload 만들기 | 11.9ms/회, **main** | 입력에 `updatedAt`이 있어 저장마다 다시 계산한다 |
| `known`이 쥐고 있는 본문 | 장소만 8.18MB | 저장소 actor가 전체 JSON 본문을 메모리에 계속 둔다 |
| 값 크기 | `SensorReading` 800바이트, `ActualRecord`·`PlaceStay` 224바이트, `TaptionDataSnapshot` 472바이트 | 측정값 배열의 필터·정렬 복사가 크다 |

## 재 보니 문제가 아니었던 것

- **같은 값 대입의 무효화**: 다시 대입해도 관찰자가 0회 발동한다. `@Observable`이 `Equatable` 값은 이미 비교해서 거른다. `setIfChanged` 같은 일괄 도구는 만들지 않는다.
- **`snapshot.didSet` 비교 비용**: 한 필드 쓰기 0.009ms, 활동 하나 쓰기 0.93ms. 배열 저장 공간이 같으면 비교가 바로 끝난다.
- **재생 중 지도 홈 본문**: 기기 재생 로그에 `body` 항목이 없다. 앞선 작업(ARC1030A01, PRF1101A01)으로 이미 분리됐다.
- **행 묶음 JSON 해석**(`[행,행,…]`을 한 번에): 행별 222ms → 묶음 204ms(8%). 해석 실패 처리가 복잡해지는 값을 못 한다. 넣지 않는다.
- **`AppModel.init`**: 3.8ms. 문제가 아니다.
- **위젯 타임라인 다시 읽기**: PRF1101A01에서 이미 묶었다.

## 지금 적용하는 안

효과 순이다. 저장 포맷과 사용자 기록은 건드리지 않는다.

| # | 문제 | 변경 | 예상 효과 | 위험 |
| --- | --- | --- | --- | --- |
| 1 | 수식어 사슬 하나의 타입 검사가 43초·17초 | `MapHomeView.lifecycleModifiers`와 `AppShellView.appLifecycleContent`를 타입을 지운 작은 묶음 함수로 나눈다. 동작은 그대로 | 해당 파일을 고칠 때마다 약 1분 절약 | 수식어 순서가 바뀌면 동작이 달라진다. 순서를 유지한다 |
| 2 | 시각만 바뀐 저장이 지도 홈 전체를 다시 평가 | `snapshot`을 직접 관찰하는 구조로 바꿔 시각만 바뀐 대입은 관찰자를 깨우지 않는다. 시각을 보는 곳은 따로 관찰하는 `snapshotSavedAt`을 읽는다 | 저장당 본문 평가 1회 → 0회. 11 Pro에서 저장마다 한 프레임 이상 절약(추정) | 시각에 기대던 화면이 갱신을 놓칠 수 있다. `updatedAt`을 읽는 곳은 `AppShellView` 한 곳임을 확인했다 |
| 3 | 내용 그대로인 저장도 전체를 해시 | 마지막으로 맞춘 스냅샷의 배열과 같으면 그 종류를 건너뛴다(저장 공간이 같으면 비교가 바로 끝난다) | 저장 62ms → 수 ms, 배터리 절약 | 건너뛴 쪽의 변경 누락. 쓰기 성공 뒤에만 기준을 갱신하고, 삭제·메모리 압력에 기준을 비운다 |
| 4 | 위젯 payload를 저장마다 main에서 계산 | 입력을 `updatedAt` 대신 내용이 바뀔 때만 오르는 개정 번호로 바꾼다 | 내용 그대로인 저장의 main 12ms 제거. 분이 바뀌면 그대로 다시 계산 | 위젯 갱신 누락. 분 단위 입력을 유지한다 |
| 5 | 저장소 actor가 전체 JSON 본문을 상주 | `known`에 본문 대신 본문 해시를 둔다 | 상주 메모리 약 8MB 이상 감소 | 해시 충돌로 쓰기 누락(2^-64). 항목 해시(`knownHashes`)가 이미 같은 위험을 지고 있다 |
| 6 | `MapHomeView`의 `@State` 199개 중 화면에 안 쓰는 값 | 본문이 읽지 않는 시각·작업 핸들·세대 번호를 묶음 객체 하나로 옮긴다. 뷰 값이 작아진다 | 측정해 효과가 있을 때만 남긴다 | 옮긴 값을 본문이 읽고 있으면 갱신이 사라진다. 읽는 곳을 확인한다 |

## 합친 뒤 (다른 세션 파일)

아래는 지금 구현하지 않는다. 해당 세션이 합쳐진 뒤 그대로 적용할 수 있게 변경 내용을 적어 둔다.

### A. 하루치 파생 계산을 main 밖으로 (`algorithm-upgrade`, `AppModel+Classification.swift`)

- 문제: `performSensorTimelineRefresh`(`:171`)가 `@MainActor`에서 `PlaceDetectionEngine.detectStays`(`:518`), `FrequentPlaceResolutionEngine.applying`, `FloorTimelineEngine.apply`(`:564` 근처), `WalkingLocationEngine.build`, `MovementRouteBuilder.build`(`:573`), `AppleDeviceGroundTruthEngine.mergingTravel`을 차례로 돌린다. `knownPlaces`가 2만 8천 건이다.
- 변경: 입력(읽은 측정값, `settings`, `snapshot.places`, `snapshot.travel`)을 `Sendable` 값으로 묶고 위 계산을 `nonisolated static`으로 옮겨 `Task.detached(priority: .utility)`에서 돈다. 장소 이름 조회(`placeNameResolver`)는 지금처럼 `await`로 둔다. 돌아온 뒤 `acceptsDataMutation()`과 `snapshotRevision`을 다시 확인하고, 어긋나면 지금의 취소 경로를 탄다.
- 함께 고칠 것: `:665-682`의 `snapshot.places.removeAll` · `append` · `sort`가 쓰기마다 `didSet`을 부른다. `var next = snapshot`에 모아 마지막에 한 번 대입한다.
- 효과: 「적용 결과」의 `derive.*` 수치만큼 main이 빈다.
- 위험: revision fence를 놓치면 사용자 편집을 덮어쓴다. `userEditedDuringSensorRefresh` 경로 시험을 그대로 통과해야 한다.

### B. 위젯 소스 직접 컴파일 줄이기 (`refactor-mechanical`, `WidgetShared.swift`)

- 문제: 위젯 target이 소스 21개를 직접 컴파일한다. `WidgetShared.swift`는 3,005행이고 앱·위젯에서 따로 컴파일한다.
- 변경: RFA1102A01의 1,014행 삭제가 합쳐진 뒤 남은 공유 타입을 `TaptionPlanCore` 또는 새 패키지로 옮긴다. 패키지 2차(`SensorReading` 이동)와 묶는다.
- 효과: 재지 못했다. 깨끗한 빌드에서 target 수만큼 줄어드는 것은 확실하다.

### C. 장소 행 다이어트 (`refactor-mechanical`, 저장소 패키지와 함께)

- 문제: 시작 비용의 85%가 장소 행이다. 10-31 기기 로그에서 한 세션 안에 363건, 170건씩 묶음으로 늘었다(14:33, 15:06). 평소 갱신 한 번은 4건 이하라, 평소 증가가 아니라 일회성 묶음 증가로 보인다. **원인은 확인하지 못했다.**
- 변경: 저장소를 복사해 오래된 날의 장소 분포를 먼저 본다. 중복이면 원인을 고치고, 정상이면 최근 N일만 먼저 해석하고 나머지는 배경에서 이어 붙인다(`snapshot.places` 읽는 곳 62곳을 조사해야 한다).
- 위험: 사용자 확정 장소(`isConfirmed`)를 지우면 안 된다. 먼저 조사부터 한다.

### D. `SensorReading` 값 크기 (`refactor-mechanical`, 분할 뒤)

- 문제: 800바이트 값이라 배열 필터·정렬에서 큰 복사가 일어난다.
- 변경: 안쪽 저장을 참조 박스로 옮기는 COW로 바꾼다. 필드 이름·`TSR1` 순서·Codable 키는 그대로 둔다.
- 효과: 「적용 결과」의 `sort.readings` 수치를 보고 판단한다. 읽기마다 간접 참조가 늘어 오히려 느려질 수 있어 측정 없이 넣지 않는다.

## 안 하기로 한 것

- **`AppModel` 스냅샷을 필드별로 관찰**: `MapHomeView`가 거의 모든 필드를 읽어 얻는 것이 적다. 읽는 곳 500곳 이상을 바꿔야 한다.
- **`AppModel` 분해(리팩토링 11번)**: 효과는 관찰 단위로 정해지는데 `@Observable`이 이미 속성 단위로 추적한다. 저장 프로퍼티를 옮겨도 무효화는 줄지 않는다. 성능 안이 아니라 정리 안으로 남긴다.

## 적용 결과

(항목을 적용한 뒤 채운다.)
