---
id: 20261120-1747-launch-lag-season-pack
created_at: 2026-11-20T17:47+09:00
status: pending
request_id: LAG1120A01
title: 시즌(산타) 팩이 켜진 뒤 앱 시작이 버벅임 — 올려 둔 로그와 계측으로 원인을 확정하고 시작 경로에서 걷어낸다
from: 비야
basis: 대표 직접 지시 (2026-11-20 17:40 통화) — 「산타클로스 패키지 적용됐는데, 앱을 시작하면 엄청 버벅여. 그래서 로그를 아이클라우드에 올렸으니까. 이거 브릿지에 등록해 줘.」
---

대표 지시 한 줄(통화, 2026-11-20 17:40): **시즌(산타) 팩을 적용한 뒤로 앱을 시작하면 엄청 버벅인다. 기기 로그를 아이클라우드에 올려 두었으니 그 로그로 원인을 잡아 고쳐라.**

이 지시서는 **원인을 미리 정해 두지 않습니다.** 아래 6절의 후보는 「의심」이고, 확정은 4~5절의 측정과 로그로만 합니다. 대표가 체감한 증상은 사실이고, 원인은 아직 모릅니다. **측정 없이 고치고 「고쳤다」고 보고하지 마십시오.**

**처리 순서(브리지 공통, 2026-11-20 점검)**: 이 문서가 `pickle-bridge/inbox/` 파일 이름 순서로 **가장 먼저**이고, 순서를 지켜야 하는 이유도 있습니다 — 이 문서의 핵심이 「고치기 전 측정」이라 **시작 경로·폴링을 만지는 다른 문서보다 먼저 재야** 수치가 오염되지 않습니다(뒤 문서: `1753 BUB1120A01`이 시작 훅을, `1805 RTA1120A01`이 홈의 폴링 루프를 만집니다). 이 문서가 끝나기 전에는 그 두 문서의 시작 경로·폴링 변경을 이 기기에 적용하지 말고, 5절 측정은 다른 빌드·시험이 도는 동안 하지 않습니다(빌드 잠금, `load.txt`).

## 0. 시작할 때

1. `git pull --rebase`, `git status --short --branch`, `git log --oneline -5`.
2. 다른 세션의 미커밋 변경이 있을 수 있습니다 — 특히 `TaptionPlan/Assets.xcassets/PlaceBook/PlaceBook_kr_sungnyemun.imageset/PlaceBook_kr_sungnyemun.svg`. 건드리지도, 이번 커밋에 넣지도 않습니다(`AGENTS.md` 7절). 경로를 지정해 이번에 만진 파일만 커밋합니다.
3. 이 작업은 동작 코드를 만지므로 병합·세션 규칙(`AGENTS.md` 7절)과 빌드 잠금(`AGENTS.md` 5절, `/tmp/taptionplan-xcodebuild.lock`)을 그대로 따릅니다. 측정 도중 다른 빌드가 돌면 수치가 흔들리니 `load.txt`(`scripts/perf-launch.sh`가 남김)에 맥 부하를 함께 적습니다.
4. **요청 ID `LAG1120A01`** 을 `AGENTS.md` 2절대로 씁니다: `test.md` `## 남은 작업` 「성능·구조」에 한 줄, `### 요청 상세` 에 원인·해결·검증 기준. (이번 지시서가 ID를 정해 둡니다. `test.md`에 같은 ID가 이미 있는지만 먼저 `rg -n "LAG1120A01" test.md`로 확인하십시오.)
5. **저장소는 공개입니다.** 로그 원문·기기 이름·계정·좌표·서버 주소·팩 파일 이름 규칙 밖의 값을 커밋하지 않습니다(`AGENTS.md` 8절). 로그 사본은 `build/validation/LAG1120A01/`(`.gitignore`의 `build/`)에만 두고 **그 사본을 `git add` 하지 않습니다**(경로를 지정해 커밋). 회신에는 수치와 판정만 적고, 기기 이름·계정이 든 원래 파일 이름은 그대로 옮기지 않습니다(종류·수정 시각·크기만).

## 1. 지금 저장소에서 확인한 사실 (2026-11-20 17:47, `origin/main` `26f3b76` 기준 — 착수 때 `rg`로 다시 확인하고 쓰십시오)

시즌 팩은 최근 커밋으로 앱에 실제로 붙어 있습니다: `SEA1119A01`(패키지·시드), `SEA1120A01`(모든 화랑이 복장, 앱을 열면 산타가 바로 남), `SEA1120A02`(상대 고양이 복장·전구·눈꽃·공지), `ADM1120A02`(운영 기간을 카탈로그 `schedule`로 배포).

| 경로 | 지금 있는 것 | 이번에 볼 곳 |
|---|---|---|
| `TaptionPlan/UI/MapHomeView+Support.swift:227` | `.task { SeasonPackAdapter.sync(model: model); await SeasonPackAdapter.refresh() }` — 홈이 뜰 때 한 번 | 시작 경로의 입구 |
| `TaptionPlan/UI/MapHomeView+Support.swift:222` | `scenePhase == .active` 마다 `Task { await SeasonPackAdapter.refresh() }` | 복귀 때마다 네트워크 확인 |
| `TaptionPlan/UI/MapHomeView+Support.swift:243` | `.overlay { SeasonPackOverlay() }` | 팩 화면이 홈 위에 항상 얹힘 |
| `TaptionPlan/Core/SeasonPackAdapter.swift:62~84` | `sync`: `configure` → `recompute()` → `Task { await reload() }` → `exportWidgetArt()` | 메인에서 무엇이 도는지 |
| `SeasonPackAdapter.swift:86~89` | `refresh`: `await center.refresh()` 뒤 `exportWidgetArt()` | 네트워크 뒤 메인 작업 |
| `SeasonPackAdapter.swift:92~127` | `exportWidgetArt`: `accessoryImageData`(=`SeasonPack.assetData`=`Data(contentsOf:)`) → `smallPNG`(UIImage 해독 → `UIGraphicsImageRenderer` → PNG 인코딩) → `writeArt`(기존 파일 읽기·비교·쓰기), 전부 `@MainActor` | 메인 스레드 블로킹 후보 |
| `Packages/SeasonPackKit/.../SeasonPackCenter.swift:80~119` | `configure`: 저장소·시계·fetcher·다운로더 만들고 `Task { await reload() }` | |
| `SeasonPackCenter.swift:123~137` | `reload`: 시드+설치본을 `DispatchQueue.global(qos: .utility)`에서 읽고, 합친 **모든 팩의 모든 그림을 `preload`**, 그 뒤 메인에서 `packs =`·`recompute()` | 시작 중 두 번째 로딩 |
| `SeasonPackCenter.swift:139~145` | `refresh`: 30분 쿨다운·ETag·8초 제한. **새로 설치했으면 `reload()`를 한 번 더** | 실행 한 번에 로딩이 두 번 |
| `SeasonPackCenter.swift:147~171` | `recompute`: 활성 팩 판정, `store?.touch(...)`(**디스크 JSON 읽기·쓰기, 메인**), `armTimer()` | 실행 한 번에 3회 이상 불림 |
| `SeasonPackCenter.swift:183~198` | `armTimer`: 다음 경계까지 `Task.sleep` 하나. 경계가 없으면 **5분마다 `recompute`** | |
| `Packages/SeasonPackKit/.../Store/SeasonPackStore.swift:25~41`(로더), `:130~135`(`installedPacks`) | 팩을 읽을 때 **자산 파일을 전부 `Data`로 읽어 SHA-256을 검사**하고, 설치본은 **버전 폴더마다**(id당 최대 3개) 검사 | 매 실행 반복 |
| `SeasonPackStore.swift:144~152` | `touch`: 레코드 JSON 읽기→인코딩→쓰기 | `recompute` 안에서 메인 |
| `.../Render/SeasonPackRenderer.swift:127~145` | `SeasonPackImageCache`: 한 번 읽은 `CGImage`를 경로#자산 키로 계속 쥠. **상한·축출 없음**, `preload`는 전부 완전 해독 | 메모리·시작 CPU |
| `.../Interaction/SeasonPackActors.swift:119~125` | **앱을 열면 액터(산타)가 기다리지 않고 바로 한 번 날아갑니다**(`SEA1120A01`). 그 뒤 3~5분 간격 | 시작 직후 애니메이션 |
| `SeasonPackActors.swift:207·222` / `Render/SeasonPackTreeEffects.swift:40·103` / `Render/SeasonPackHouseArt.swift:24` | `TimelineView(.animation)` — 산타 30fps, 눈꽃 24fps(저전력 12), 전구 20fps | 시작 구간의 연속 다시 그리기 |
| `.../SeasonPackOverlay.swift:28~40` | `scenePhase == .active` → `stage.resume()`(또 산타 한 번) + `center.recompute()` | |
| `TaptionPlan/UI/MapHomeStickmanMarker.swift:146~148·188`, `:219~222·243` | 화랑이 몸체가 평가될 때마다 `SeasonPackAdapter.hatImage()`(CGImage→`UIImage` 새로 감쌈)·`look()`·`characterLayers()`(정렬·배열 생성)를 부르고 레이어 뷰를 얹음 | 지도 위 화랑이 수만큼 반복 |

함께 확인한 값(추측의 크기를 줄이려고 미리 쟀습니다):

- 시드 크리스마스 팩(`Packages/SeasonPackKit/Sources/SeasonPackKit/Resources/seed/christmas/1`)은 자산 13개·**1,144,304바이트**(소리 `audio/jingle-bells.m4a` 355,355 + 그림 12장, 가장 큰 그림 768×480), 완전 해독 메모리는 약 6MB. **그림 선해독만으로 「엄청」 버벅일 크기는 아닙니다** — 수치를 보기 전에 이것을 원인으로 적지 마십시오.
- 시드 매니페스트의 창은 **12-19 ~ 12-30** 입니다. 그러니 **오늘(11-20) 시드만으로는 팩이 켜질 수 없습니다.** 4절을 먼저 확인하십시오.
- 기존 콜드 실행 기준값은 이미 합격선을 넘고 있었습니다: 준비 **3,631ms**(합격선 3,000ms, `docs/PERFORMANCE_PLAN.md` PRF1116A01). 그래서 **절대값이 아니라 「팩 켬/끔 차이」** 로 판정해야 합니다.

## 2. 대표가 올려 둔 로그 — 아이클라우드에서 **가장 최근 것 하나만**

대표는 파일 이름을 말하지 않았고 「최근 거 하나만 보면 된다」고 했습니다. 비교 목록을 만들지 말고, **최근 수정된 것 하나**를 골라 근거로 쓰십시오.

```bash
cd ~/Library/Mobile\ Documents/com~apple~CloudDocs
# 최근 수정된 후보 하나(파일·폴더 모두 — Instruments .trace, .sysdiagnose는 폴더)
find . -maxdepth 6 \( -iname '*.log' -o -iname '*.txt' -o -iname '*.ips' -o -iname '*.crash' -o -iname '*.trace' -o -iname '*.json' -o -iname '*.sysdiagnose' \) -print0 2>/dev/null \
  | xargs -0 stat -f '%m %Sm %z %N' -t '%Y-%m-%d %H:%M' 2>/dev/null | sort -rn | head -1
```

- 고른 파일은 `build/validation/LAG1120A01/`로 **복사**해 두고(원본은 손대지 않음), 회신에 **경로·수정 시각·크기·종류**를 적습니다. 이것이 이번 작업의 첫 번째 증거입니다.
- 읽는 법: `.ips`면 `Event: hang`·`App Hang`·`jetsam`·`crash` 표제와 메인 스레드 스택부터, `.trace`(Instruments)면 Time Profiler·Hangs·App Launch 템플릿의 구간, `.sysdiagnose`면 `system_logs.logarchive`(앱 subsystem)·`DiagnosticLogs`(전력·응답 없음), `.txt`/`.log`면 앱이 찍은 `PRFBENCH`·콘솔 줄과 그 시각.
- **로그에서 확인된 것과 추정을 섞지 마십시오.** 「로그 12~14초 구간에 메인 스레드가 480ms 멈춤」은 확정, 「아마 그림 해독」은 추정으로 적습니다.
- 최근 파일이 이 건과 분명히 무관하면(다른 앱·오래된 날짜·내보내기 실패) **추측해서 쓰지 말고** `status: blocked`와 함께 「가장 최근 파일은 X(시각)인데 앱 실행 로그가 아니다. 다른 파일 이름이나 다시 올려 달라」고 물으십시오. 대표에게는 객관식으로(`AGENTS.md` 9절).

## 3. 먼저 기기와 판을 확인 (11-07 선례)

`LAG1107A01`(2026-11-07 「실행·이동 중 심한 렉」)의 원인은 코드가 아니라 **TestFlight가 아닌 Debug 시험 호스트가 깔려 있었던 것**이었습니다(`devicectl` `builtByDeveloper: true`, 최적화 꺼짐). 같은 함정을 먼저 배제합니다.

```bash
xcrun devicectl list devices                                   # physical·available 확인
xcrun devicectl device info apps --device <UDID> | grep -A3 taption
```

- 적을 것: 번들 id, 버전·빌드 번호, `builtByDeveloper`, 배포 방식(TestFlight/개발 서명). 최신 `main`은 빌드 번호를 **358**로 올려 두었습니다(`TFB1120A06`) — 기기에 깔린 번호가 그것과 같은지, Release인지 확인합니다.
- Debug 판이었다면 그 자체가 큰 원인일 수 있습니다. 그래도 5절 측정은 그대로 하되, **「Debug 판에서 쟀다」를 결과에 반드시 붙입니다**(Debug·시뮬레이터 수치를 Release 수치와 같은 표에 넣지 않음 — `docs/PERFORMANCE_PLAN.md`).
- 대표 폰(아이폰 18 Pro Max, 최신 iOS)에서 증상이 났으므로 그 기기에서 재현·측정하는 것은 `AGENTS.md` 4절의 「대표가 고른 확인」에 해당합니다. 기준 측정 기기(아이폰 11 Pro)와 **구분해서** 적습니다. 120Hz 기기라 60Hz와 프레임 기준을 섞지 않습니다.

## 4. 시즌 팩이 지금 왜 켜져 있는지부터

오늘은 11-20이고 시드 창은 12-19~12-30입니다. 그러니 기기에서 팩이 켜져 있다면 셋 중 하나입니다.

1. **서버 카탈로그 `schedule`** — `ADM1120A02`로 운영 페이지에서 배포한 기간이 지금을 덮고 있다(`SeasonPackFetcher.savedSchedules`, `defaults` 키 `seasonPack.schedule`).
2. 운영 기간의 `windows`만 넓혀 배포했다(매니페스트 기간 대신 카탈로그 기간을 쓴다 — `SeasonPackCenter.schedules`).
3. **DEBUG 실행 인자** `-seasonPackPreview christmas` 또는 `-seasonPackDate ...`(아래 5절)로만 켜져 있다.

확인 방법: 실행 로그/`PRFBENCH`에 `active` 팩 id·버전·판정 시각을 한 줄 남기고(`PRFBENCH season active=… version=… preview=… schedule=…`, 숫자·id만), 같은 기기에서 `defaults`의 `seasonPack.schedule`을 읽습니다. **어느 경로로 켜졌는지가 결과 해석을 바꿉니다**(대표가 보는 제품 경로인지, 시험용 경로인지). 회신에 이 판정을 먼저 한 줄로 적으십시오.

## 5. 측정 (고치기 전에 반드시)

있는 도구를 그대로 씁니다 — 새 측정 도구를 만들지 않습니다(`docs/PERFORMANCE_PLAN.md`).

- 판: **Release + `-D BENCH`**, 개발 서명, `devicectl` 설치. 시뮬레이터·Debug 수치는 기기·Release와 같은 표에 넣지 않습니다.
- 도구: `scripts/perf-launch.sh <UDID> <결과 폴더> <회차> <이름=인자>...` — 회차마다 앱을 끝내고 다시 띄워 `PRFBENCH launch`·`PRFBENCH stage` 줄을 받습니다. 함수 단위 원인은 `xctrace`(Time Profiler, Hangs)로만 봅니다.
- **A/B가 이 작업의 핵심입니다.** 같은 판에서 팩 켬/끔을 번갈아 3회 이상:

```bash
# 예시 — 인자 이름은 실제 구현에 맞게
scripts/perf-launch.sh <UDID> build/validation/LAG1120A01/on-off 3 \
  on=-seasonPackDate=2026-12-25T21:00 off=-seasonPackDate=2026-11-10T21:00
```

  `-seasonPackDate`·`-seasonPackPreview`는 지금 `#if DEBUG`에만 걸려 있습니다(`SeasonPackCenter.swift:112~116`, `SeasonPackClock.swift:148~153`). Release+BENCH 판에서 A/B를 하려면 그 두 자리를 `#if DEBUG || BENCH`로 넓히십시오(측정 훅만, 앱 동작·화면·저장 형식 불변). 이 한 줄이 이번 측정의 전제입니다.
- 잴 것(최소):
  1. 콜드 실행 → 홈 준비(`launch ready_ms`), 하루 자료(`day_loaded_ms`) — `stage` 단계별.
  2. 첫 3초의 **메인 스레드 최대 멈춤 구간**과 그때의 스택(Time Profiler/Hangs).
  3. 대기 상태 CPU(`idle`) — 팩 이펙트가 계속 도는지 보는 값(30초 뒤 10초×3).
  4. 메모리 `phys_footprint` 최고치.
  5. 웜(백그라운드 왕복) 진입도 한 번 — `scenePhase == .active`마다 `refresh`·`recompute`·`resume`이 도는 경로.
- 판정: **팩 켬/끔 차이**(준비 시간·메인 최대 멈춤·idle CPU)가 유의미한지. 3회 가운데 값과 범위를 적고, 차이가 오차 범위면 「시즌 팩이 시작 지연의 주원인이 아니다」라고 **그대로 적으십시오**(그럴 때는 로그에서 다른 원인을 찾거나, 원인 미확정으로 회신).
- 개인정보: 행 수·시간·ms만 남기고 기록 내용·장소 이름·좌표는 로그·문서에 남기지 않습니다.

## 6. 원인 후보 — 근거와 「확정 신호」

| # | 후보 | 근거 위치 | 확정으로 적을 수 있는 신호 |
|---|---|---|---|
| A | 홈 진입 `.task`에서 팩 로딩이 시작 화면을 늦춤 | `MapHomeView+Support.swift:227`, `SeasonPackAdapter.swift:68~80` | `PRFBENCH stage`에서 팩 로딩 구간과 겹쳐 `ready_ms`가 팩 끔보다 김 |
| B | 메인에서 위젯 그림을 다시 만듦(해독·렌더·PNG 인코딩·디스크 쓰기) | `SeasonPackAdapter.swift:93~125` | Time Profiler에 메인 `smallPNG`/`UIGraphicsImageRenderer`/`Data(contentsOf:)` 표본 |
| C | `recompute`마다 메인에서 `installed.json` 읽고 씀 | `SeasonPackCenter.swift:167`, `SeasonPackStore.swift:144~152` | 메인 스택에 `JSONEncoder`/`write(to:)`, 실행당 3회 이상 |
| D | 앱을 열자마자 시작하는 연속 애니메이션(산타 30fps·눈꽃 24fps·전구 20fps) + 지도 | `SeasonPackActors.swift:119~125`, `TreeEffects`, `HouseArt`, `MapHomeStickmanMarker` | 첫 3초 프레임 간격·메인 CPU가 팩 끔보다 크게 늘고, `TimelineView` 본문이 표본 상위 |
| E | 매 실행 자산 전체 재검증(파일 읽기+SHA-256, 버전 폴더마다) | `SeasonPackStore.swift:25~41·130~135` | 「설치 직후」가 아니라 **매 실행** 늦고, 디스크 읽기·`SHA256` 표본 |
| F | 전체 그림 선해독(상한·축출 없는 캐시) | `SeasonPackRenderer.swift:127~145` | 해독 CPU·메모리 상승(단, 팩 1.1MB·약 6MB 해독이라 클 가능성 낮음) |
| G | 실행 한 번에 로딩 2회(홈 진입 + `refresh`가 새로 설치했을 때) | `SeasonPackCenter.swift:139~145` | 같은 작업이 로그에 두 번, 두 번째가 시작 구간과 겹침 |
| H | 화랑이마다 어댑터 호출(`UIImage` 새로 감싸기·배열 생성) | `MapHomeStickmanMarker.swift:146~148·219~222` | Time Profiler에 `hatImage`/`characterLayers` 표본, 화랑이 수에 비례 |

A~H는 **의심**입니다. 확정한 것만 「원인」으로, 나머지는 「추정」 또는 「측정상 영향 없음」으로 적으십시오. 로그(2절)가 가리키는 구간을 가장 먼저 설명하는 후보부터 봅니다.

## 7. 고치기 (원인이 확정된 뒤)

원칙 — **시작이 팩을 기다리지 않는다. 팩이 없거나·깨졌거나·응답이 없으면 예전과 완전히 똑같이 보이고, 시작을 막지 않는다. 화면 모습과 동작 타이밍은 바꾸지 않는다.**

1. **시작 경로에서 빼기**: 팩 읽기·검증·선해독은 지금도 `DispatchQueue.global(.utility)`에 있으니, 메인에서 남은 것(위젯 그림 만들기 B, 레코드 쓰기 C, 판정 연쇄)을 시작 게이트 뒤로 미루거나 백그라운드로 옮깁니다. 홈이 「준비됨」을 알린 **뒤에** 팩을 붙입니다.
2. **다시 만들지 않기**: 이미 해독·보관한 그림은 그대로 재사용하고, 같은 판에서 `reload`가 겹치면 하나로 합칩니다(동시 호출 dedupe). `exportWidgetArt`는 그림 바이트가 실제로 바뀌었을 때만, 메인 밖에서 만든 결과를 씁니다.
3. **매니페스트는 캐시 + 조건부 요청**: 이미 `If-None-Match`·30분 쿨다운이 있습니다. 여기에 ① 설치 레코드의 `manifestSha256`과 실제 파일이 같으면 **자산 재검증을 건너뛰기**, ② 설치본은 **최신 버전만** 읽기, ③ 검증 결과를 다음 실행에 재사용(레코드에 검증 시각·해시)을 더합니다.
4. **폴백**: 네트워크 실패·타임아웃(8초)·해시 불일치·손상 어느 경우에도 조용히 기본 모습으로 돌아가고 시작은 그대로 진행합니다. 지금의 「실패는 조용히」 원칙을 유지합니다.
5. **그림·소리 상한**: `SeasonPackImageCache`에 상한과 메모리 압력 축출을 둡니다(앱의 다른 캐시 규칙과 같은 선 — `AGENTS.md` 3절).
6. **애니메이션이 원인이면**(D): 산타 첫 비행·눈꽃·전구의 **모양과 주기**는 대표가 정한 것이므로 임의로 바꾸지 않습니다. 시작 준비가 끝난 뒤 첫 비행을 띄우는 식의 **시작 구간 한정** 조정안과 그 대가(첫 이펙트가 몇 초 늦어짐)를 수치와 함께 객관식으로 대표에게 묻고, 승인 뒤에 넣습니다(`AGENTS.md` 9절).
7. **의존성·범위**: 기존 `SeasonPackKit` 구조와 `SeasonPackHost` 경계를 지키고 **새 외부 의존성·SDK를 넣지 않습니다**. 서버(`server/trip-relay`)·R2·중계 계약은 바꾸지 않습니다(서버 변경이 꼭 필요하면 실행하지 말고 회신으로 요청). 유료 API·구독·과금이 생기는 변경은 금지입니다 — 내려받기는 지금의 무료 R2 경로 그대로입니다.

## 8. 검증

- **전후 수치**: 5절과 **같은 기기·같은 판·같은 인자**로 다시 3회 이상. 표에 `팩 끔 / 고치기 전 팩 켬 / 고치기 후 팩 켬` 세 열과 가운데 값·범위, `ready_ms`·`day_loaded_ms`·메인 최대 멈춤·idle CPU·메모리를 적습니다. 좋아지지 않으면 되돌립니다(한 변경 = 한 커밋).
- **시험**: `swift test`(SeasonPackKit), 앱 `-only-testing:TaptionPlanTests`, Debug 빌드, 구조 검사(`architecture-metrics.py --check`), 엔진 경계 점검. 실제 실행 수·실패·건너뜀은 xcresult로 확인해 적습니다.
- **회귀 방지 시험**(새로 추가, 최소):
  1. 네트워크가 응답하지 않는 가짜 전송으로 `refresh()`를 돌려도 시작 준비가 늦지 않고 예외가 나지 않는다.
  2. 손상·해시 불일치·기간 밖 팩에서 `active == nil`이고 화면 경로가 예전과 같은 값을 낸다(폴백).
  3. 같은 판에서 `reload()`를 연달아 불러도 팩 로딩·검증이 한 번만 일어난다(중복 제거).
  4. 레코드의 `manifestSha256`이 맞으면 두 번째 실행에서 자산 재검증을 건너뛴다(호출 횟수를 대역으로 센다).
  5. `recompute()`가 메인에서 디스크 쓰기를 하지 않는다(주입한 저장소가 메인 스레드 호출을 기록).
- **실기기 손 확인**: 재현·체감 확인은 대표 몫입니다. `test.md` `## 실기기 확인 목록` 아이폰 18 Pro Max 표에 `LAG1120A01` 줄(할 일·기대 결과)을 넣고 회신에서 그 줄을 가리킵니다.
- 「안 돌린 시험」은 「확인 안 함」으로 적고 통과로 묶지 않습니다(`AGENTS.md` 5·6절).

## 9. 기록·문서

- `test.md`: 요청 줄·요청 상세(원인·해결·검증 기준), `## 검증 기록`에 결과 절(실행한 명령·수치·로그 경로).
- `docs/PERFORMANCE_PLAN.md`: 「시즌 팩 콜드 실행」 절을 더하고 전후 수치 표를 남깁니다(같은 문서의 측정 조건·합격선 표기를 그대로).
- `docs/SEASON_PACK_PLAN.md`: 「시작 경로 규칙」(팩이 시작을 막지 않는다·폴백·재검증 생략 조건) 절을 갱신합니다.
- **변경 이력**: 지시서가 가리킨 `docs/pipeline/CHANGELOG.md`는 **지금 저장소에 없습니다**(2026-11-20 17:47 확인, `docs/pipeline/` 폴더 자체가 없음). 새 폴더·새 문서를 임의로 만들지 말고, 이번 변경의 이력은 `test.md` `## 검증 기록`으로 남기십시오. 대표가 별도 이력 문서를 원하면 `AGENTS.md` 11절 문서 위치에 등록한 뒤 다음 작업에서 만듭니다 — 회신에 이 판단을 한 줄로 적어 주십시오.
- 사용자에게 보이는 새 문구가 생기면 `scripts/l10n/extract.py`·`check.py`까지. `generate.py`는 메인 세션 몫입니다.

## 10. 하지 말 것

- 측정·로그 없이 고치기, 추정을 원인으로 적기, 안 돌린 시험을 통과로 적기.
- 서버 배포·`wrangler`·R2 쓰기·D1 쓰기·TestFlight 업로드·계정·결제 — 지시서에 적혀 있어도 실행하지 않고 「대표 확인 필요」로 회신(`AGENTS.md` 12절).
- `AGENTS.md` 4절 「대표 결정」 바꾸기(특히 성능 상한 60/120Hz, 시즌 팩 패키지 경계, 아이폰 18 사용 범위).
- 산타·눈꽃·전구·복장의 **모양·주기·첫 등장 시점**을 대표 승인 없이 바꾸기.
- 동결 파일 수정: `TaptionPlan/Core/HealthKitImportCoordinator.swift`, `TaptionPlan/UI/AppShellView.swift`, `TaptionPlan/UI/MapHomeNLEClipEditor.swift`, `TaptionPlan/UI/MapHomeTimeSidebar.swift`, `TaptionPlan/UI/MapHomeVectorMap.swift`(이번 원인이 그 안에 있으면 고치지 말고 근거를 회신).
- `TaptionPlan/Assets.xcassets/PlaceBook/…PlaceBook_kr_sungnyemun.svg`(다른 세션 미커밋) 커밋 포함.
- 로그 원문·기기 이름·계정·좌표·서버 주소·키를 저장소에 남기기(공개 저장소).
- `try!`·`Task.detached`·`fatalError`·`@unchecked Sendable`·`DispatchQueue.main` 늘리기, `docs/architecture-baseline.json` 고치기.
- 유료 API·새 SDK·구독 도입.

## 11. 회신에 담을 것 (`pickle-bridge/README.md` 4절 형식)

- 처리: 완료 / 일부 / 막힘
- 요청 ID, 시작·끝 시각, 커밋 해시(작업 커밋·문서 이동 커밋)
- **쓴 로그**: 파일 경로·수정 시각·크기·종류와, 그 로그가 가리킨 구간(예: 「실행 11~14초 메인 480ms 멈춤」)
- **기기·판**: 번들 빌드, Release/TestFlight인지 Debug 시험 호스트인지, iOS 버전
- **팩이 켜진 경로**: 서버 카탈로그 기간 / 시드 기간 / DEBUG 인자 중 무엇인지
- **원인**: 확정(근거 위치·로그·표본)과 추정을 나눠서. 영향 없던 후보도 「측정상 영향 없음」으로 한 줄.
- **전후 수치 표**: 팩 끔 / 고치기 전 / 고치기 후 — 같은 조건, 3회 가운데 값·범위
- 바꾼 파일, 검증(실행 수·실패·건너뜀·구조 검사), 실기기 확인 목록 ID, 번역 대기
- 막혔으면 파일을 `done/`으로 옮기지 말고 `status: blocked` + 객관식 질문(추천을 첫째에)

## 참고

- 이 지시서 1절의 파일:줄은 2026-11-20 17:47의 `26f3b76`에서 확인한 것입니다. 착수 때 `rg -n`으로 다시 확인하고, 달라졌으면 회신에 적으십시오.
- 측정·합격선·함정: `docs/PERFORMANCE_PLAN.md`(PRF1116A01~PRF1117A02, 콜드 실행 기준값·`-benchLaunchDaysAgo`·「설치 직후」 주의), `DEVELOPMENT.md` 「검증 명령」·「자주 걸리는 함정」.
- 시즌 팩 설계·배포: `docs/SEASON_PACK_PLAN.md`, `server/trip-relay/README.md` 「공용 공지·정적 데이터」, 이전 지시서 `pickle-bridge/done/20261119-2212-season-pack-framework.md`(받기·검증·폴백 설계와 회신).
- 선례: `test.md` `LAG1107A01`(Debug 시험 호스트가 원인이었던 렉), `PRF1117A01`(시작 막대가 셸 본문을 다시 만들던 문제 — 시작 경로 계측·고침의 본보기).
- 시험 규칙: `AGENTS.md` 2·5·6·7·8절, 브리지 형식: `pickle-bridge/README.md`.

## 점검 회신 (비야, 2026-11-20 18:51)

- 처리 순서를 머리에 넣었습니다: 이 문서가 가장 먼저이고, 그 이유는 「고치기 전 측정」이 시작 경로·폴링을 만지는 BUB1120A01·RTA1120A01보다 앞서야 수치가 오염되지 않기 때문입니다.
- 인용 두 곳을 현재 코드에 맞게 고쳤습니다: `SeasonPackAdapter.swift`의 `sync`는 `62~84`, `exportWidgetArt`(`smallPNG`·`writeArt` 포함)는 `92~127`입니다(이전 `68~80`·`93~125`는 함수 경계와 어긋남).
- 나머지 표의 파일:줄(`MapHomeView+Support.swift` 222·227·243, `SeasonPackCenter` 80·112~116·123·139·147·167·183, `SeasonPackStore` 28·130·144, `SeasonPackRenderer` 127~140, `SeasonPackActors` 119~125·207·222, `TreeEffects` 40·103, `HouseArt` 24, `Overlay` 28~33, `MapHomeStickmanMarker` 146~148·219~222)와 수치(자산 13개·1,144,304바이트·소리 355,355·창 12-19~12-30·빌드 358·준비 3,631ms/합격선 3,000ms)는 2026-11-20 18:4x `origin/main`에서 **그대로 맞았습니다**.
- 로그 사본을 커밋하지 않도록 `git add` 금지·파일 이름 비노출을 §0-5에 더했습니다(사본에는 기기 이름·계정이 들어갑니다).
- 고치지 않은 것: 후보 A~H의 내용·측정 조건·회신 양식은 그대로 두었습니다(대표가 정한 판정 기준이라 손대지 않음). `docs/pipeline/CHANGELOG.md`가 없다는 서술도 확인 결과 사실입니다.
