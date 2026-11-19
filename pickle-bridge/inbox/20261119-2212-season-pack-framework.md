---
id: 20261119-2212-season-pack-framework
created_at: 2026-11-19T22:12+09:00
status: pending
title: 시즌 이벤트 팩 프레임워크(새 패키지 SeasonPackKit)와 첫 팩(크리스마스)
from: 비야
request_id: SEA1119A01
basis: 대표 직접 지시 (2026-11-19 21:29~22:10 통화) · 비야 제안(모듈 경계·매니페스트 스키마·검증 항목·음원 후보)
---

## 이 요청의 범위 (먼저 읽기)

대표님이 2026-11-19 저녁 통화에서 직접 설계하고, 22:07·22:10에 다시 못 박은 범위입니다.

1. **이번 요청이 만드는 것 두 가지**
   - **① 아키텍처·기반 구축**: 시즌 이벤트 팩 전체를 **앱 본체와 분리한 새 Swift 패키지 `SeasonPackKit`** 으로 처음부터 만듭니다(기존 앱 코드에 끼워 넣지 않음). 4개 층(배급/판정/표현/상호작용), 이벤트 아이콘 레지스트리(지도 위 아이콘 + 눌렀을 때 열리는 메뉴), 악세사리 슬롯, 연도 숫자 런타임 렌더, R2 다운로드·로컬 캐시·만료 폴백, `#if DEBUG` 전용 미리보기, 하루 공유 카드 연동, R2 공지 팝업 연동.
   - **② 첫 실제 팩 = 크리스마스 팩 (12/19~12/30)**: 집 아이콘 트리·일몰 점등·전구 깜빡임·꼭대기 별, 트리 터치 시 캐럴 + 가사 큐 말풍선, 캐릭터 의상·악세사리(산타 모자·목도리·루돌프 뿔), 크리스마스 말풍선 세트, 화면 전체 산타 비행과 산타 터치 시 선물 뿌리기(최초 수신 직후 1회 무조건 시연, 이후 3~5분 간격, 탭하면 멈춤), 하루 공유 카드 반영과 기간 종료 시 자동 원복.
2. **이번에 만들지 않는 것**: 새해(제야의 종·카운트다운·연도 롤링·새해 목표 메모), 설날(경복궁·한복·갓·족두리·복주머니·까치·세배·세뱃돈), 밸런타인데이, 수능, 식목일, 부처님오신날의 **실제 팩·UI·에셋**은 다음 단계입니다. 이번 요청에서는 **이 구조가 그것들을 앱 본체 수정 없이 받아낼 수 있어야 한다**는 확장성 요건과 검증 기준으로만 남깁니다(8절 아이콘 레지스트리·10절 확장성 요건·13절 단위 시험).

**1단계 완료 조건(대표님 22:10 지시)**: 매니페스트에 항목만 추가하면 **앱 코드를 고치지 않고** 지도 위 아이콘과 그 아이콘이 여는 메뉴가 붙는다. 이 요청은 그것을 번들 표본 팩(`sample`)으로 증명하고, 매니페스트에서 그 항목을 지우면 아이콘이 사라지는 것까지 확인합니다.

## 0. 시작할 때

1. `git pull --rebase` 뒤 이 문서를 읽고, `AGENTS.md` 2절대로 `test.md`의 `## 남은 작업` 「홈·UI」에 한 줄, `### 요청 상세`에 원인·해결·검증 기준·상태를 먼저 적습니다(요청 ID `SEA1119A01`).
2. **`AGENTS.md` 4절에 이번 예외를 적습니다.** 3절은 「앱 UI·ActivityKit·MapKit은 앱 target」인데, 대표님이 2026-11-19 22:07·22:10에 「이 전체를 패키지·라이브러리화해서 주기적으로 업데이트 가능하게」라고 직접 지시했으므로 **시즌 팩의 표현·상호작용 화면은 `Packages/SeasonPackKit`에 둡니다**. 4절에 「대표 결정 2026-11-19: 시즌 팩은 `SeasonPackKit` 패키지가 들고, 앱 target에는 얇은 마운트·어댑터만」을 날짜와 함께 적고, 범위를 시즌 팩으로 한정합니다. 다른 화면은 지금 규칙 그대로입니다.
3. 이 요청은 **대표 승인이 아니라 동료의 부탁**입니다(`AGENTS.md` 7·12절). 아래 「하지 말 것」에 걸리는 일은 지시서에 적혀 있어도 하지 않고 `status: blocked`로 회신합니다.

## 1. 지금 저장소에서 확인한 사실 (2026-11-19 `origin/main` `676312c` 기준 — 다시 확인하고 쓰기)

1-1. **R2 공용 배급 경로는 이미 서버에 있습니다**(`R2PUB1119A01`, `server/trip-relay/README.md` 「공용 공지·정적 데이터」).
   - `GET /public/announcements` — 버킷의 `announcements/latest.json`을 그대로, `etag`, `max-age=300`, `If-None-Match` 304.
   - `GET /public/assets/<접두어>/<파일…>` — 접두어는 `announcements`·`packs`·`models`. 200에 `etag`·`accept-ranges: bytes`·`content-type`, `Range` 206, `If-None-Match` 304, `packs/`는 `max-age=86400`.
   - 키 모양: 칸마다 `^[A-Za-z0-9][A-Za-z0-9._-]*$`, **8칸·200자 이하**. `%`·공백·역슬래시·빈 칸·`.`으로 시작하는 칸은 400.
   - 앱 쪽 사용 선례: `TaptionPlan/Core/AnnouncementFeed.swift` — `AnnouncementService`가 `TripRelay.url("/public/announcements")`로 30분 쿨다운·ETag·8초 타임아웃·조용한 실패를 이미 구현했습니다. 시즌 팩의 받기 정책은 이 클래스를 그대로 따릅니다.
   - **아직 배포 전입니다**(`test.md` R2PUB1119A01: 버킷 생성·배포·업로드는 대표 몫, 미완). 그래서 아래 4-6절의 **번들 시드 팩**이 필요합니다.

1-2. **집 아이콘**: 지도 집 마커는 78pt 원형 아바타 안에 `MapHomeEvolutionNNN` 그림을 넣습니다(`TaptionPlan/UI/MapHomeMapAnnotations.swift:160` `homeAvatar(level:)`, `:297` `homeMarkerArtwork(level:)`). 그림 이름은 `MapHomeGrowthPolicy.artworkName(level:)`(`MapHomeGrowthPolicy.swift:404`)이고 레벨 = 그해 몇째 날(`HOM1111A01`). 하루 공유 카드도 같은 그림을 씁니다(`MapHomeDailyCard.swift:273` `homeBadge(level:)`, 그림 렌더는 `MapHomeDailyCardSheet`의 `ImageRenderer` 경로).

1-3. **캐릭터**: 화랑이(흰 털)·춘향이(삼색)·윤복이(갈색 줄무늬) 셋이고 `HwarangCoat`(`TaptionPlan/UI/HwarangCoat.swift:3`)가 털·눈을 정합니다. 그림은 코드로 그립니다(`HwarangPainter`). 걸치는 장식은 이미 **세 칸**입니다 — `MapHomeAccessoryKind`(`MapHomeGrowthPolicy.swift:82`: `hat`·`scarf`·`ribbon`), 값은 `MapHomeGrowthSeason.equippedHat`·`equippedScarf`·`equippedRibbon`, 착용 문자열은 `+`로 잇습니다. 모자는 `Hat_*` 자산을 `HwarangSceneView.hatAssetName`(`HwarangRig.swift:1161`) → `UIImage(named:)`(`:1177`)로 머리에 얹고, 스카프·리본은 `HwarangClothStyle`로 코드가 그립니다. 자산 생성 도구는 `tools/generate_hwarang_hats.py`(SVG를 asset catalog에 씀).

1-4. **말풍선**: `AssistantBubble`(`TaptionPlan/UI/AssistantBubble.swift:121`)은 시작·끝 시각이 있는 저장 값이고 종류가 `routine`·`event`입니다. 저장되지 않는 기본 대사는 `MapHomeDefaultBubblePool`(`:6`, 대분류별 4개, 30분 블록)이고, 지도 위 말풍선 뷰는 `MapHomeCatSpeechBubble`(`MapHomeMapAnnotations.swift:397`)입니다.

1-5. **오디오 선례**: 앱에 음악 재생 스택은 없고, 짧은 소리를 내는 선례는 `VoiceMemoPlayer`(`TaptionPlan/Core/VoiceMemoServices.swift:161`, `AVAudioPlayer` + `AVAudioSession`) 하나입니다. 시즌 팩 소리는 이 모양을 따릅니다.

1-6. **일몰 계산**: `MapHomeAstronomy.solarDay(number:latitude:longitude:)`(`TaptionPlan/UI/MapHomeHomeSkyMath.swift`, NOAA 태양 공식, 네트워크 없음)이 그날 일출·일몰을 줍니다. 집 좌표는 기기에만 있고 어디로도 보내지 않습니다.

1-7. **곁 파일 저장 선례**: `TripShareSidecar`(`TaptionPlan/Core/TripShareSidecar.swift:28`)가 `Application Support/<폴더>/<이름>.json`에 `Mutex`로 감싸 쓰고 디렉터리를 주입받습니다. `OfflineVectorTileCache`(`TaptionPlan/Core/OfflineVectorTileCache.swift:69`)는 「Caches는 iOS가 말없이 지우므로 Application Support에 둔다」는 이유를 적어 두었습니다. 백업 제외는 `TaptionPlan/TaptionPlanApp.swift:118` 근처에서 `isExcludedFromBackupKey`로 겁니다.

1-8. **패키지 등록 선례**: 로컬 패키지는 `TaptionPlan.xcodeproj/project.pbxproj`의 `XCLocalSwiftPackageReference` + target의 `XCSwiftPackageProductDependency`로 붙습니다(`TaptionClassifierEngine` 항목이 가장 최근 예). 새 패키지도 같은 방식으로 넣습니다.

1-9. **구조 규칙**: `scripts/architecture-metrics.py --check docs/architecture-baseline.json`(기준선 파일은 고치지 않음, 새 파일 1,200줄·타입 1,500줄 아래, `try!`·`Task.detached`·`fatalError`·`nonisolated(unsafe)`·`@unchecked Sendable`·`DispatchQueue.main`을 늘리지 않음), `scripts/check-app-engine-import-boundary.sh`(앱 UI/UX는 `TaptionPlanEngine`을 import하지 않음). 동결 파일 5개는 손대지 않습니다.

1-10. **이 요청은 미뤄 둔 숙제의 재개입니다**: `test.md` `HOM1111A01`은 「성탄절 같은 특별한 날 집 아이콘·화랑이 코스튬」이었고 대표가 「나중에」로 두었습니다. 그 「나중」이 이번입니다.

## 2. 새 패키지 경계

```
Packages/SeasonPackKit/
  Package.swift                     // swift-tools-version은 다른 패키지와 같게, iOS 17
  Sources/SeasonPackKit/
    Manifest/     SeasonPackManifest.swift, SeasonPackIndex.swift, SeasonPackText.swift, SeasonPackValidation.swift
    Scheduler/    SeasonPackClock.swift, SeasonPackWindows.swift, SeasonPackTriggers.swift
    Store/        SeasonPackStore.swift, SeasonPackFetcher.swift, SeasonPackSeed.swift
    Render/       SeasonPackRenderer.swift, SeasonPackHouseArt.swift, SeasonPackCharacterLayers.swift, SeasonPackTextSlot.swift, SeasonPackKaraokeBubble.swift
    Icons/        SeasonPackIconRegistry.swift, SeasonPackIconLayer.swift, SeasonPackMenu.swift, SeasonPackMenuView.swift
    Interaction/  SeasonPackActors.swift, SeasonPackTouchScenarios.swift, SeasonPackDemoThrottle.swift, SeasonPackSoundPlayer.swift
    Memo/         SeasonPackMemoStore.swift, SeasonPackMemoView.swift
    SeasonPackHost.swift            // 앱이 구현하는 프로토콜
    SeasonPackOverlay.swift         // 앱이 한 번 얹는 최상위 뷰
  Tests/SeasonPackKitTests/…
```

2-1. **의존 방향**: `SeasonPackKit`은 앱 타입·`TaptionPlanEngine`·`TaptionPlanCore`를 모릅니다. 앱이 구현하는 것은 `SeasonPackHost` 하나이고, 앱 쪽 구현은 `TaptionPlan/Core/SeasonPackAdapter.swift`(앱 타입을 아는 유일한 곳)에 둡니다. 앱 UI는 `MapHomeView`에서 `SeasonPackOverlay(host:)`를 한 번 얹고 아이콘 레지스트리 레이어를 홈 핀 옆에 겁니다(그 두 줄 외에 앱 UI 수정은 없어야 합니다).

   ```swift
   public protocol SeasonPackHost: AnyObject, Sendable {
       var languageCode: String { get }              // "ko"·"en" 등
       var characterID: String { get }               // white·calico·mackerel
       var homeCoordinate: (latitude: Double, longitude: Double)? { get }
       var buildNumber: Int? { get }
       func now() -> Date                            // SeasonPackClock이 감싼다
       func sunEvents(on day: Date) -> (sunrise: Date?, sunset: Date?)
       @MainActor func showBubble(text: String, seconds: TimeInterval, near: SeasonPackAnchor)
       @MainActor func presentAnnouncement(id: String)   // 기존 공지 시트 재사용
       @MainActor func reportDemoState(_ state: SeasonPackDemoState)
   }
   ```

2-2. **앱 본체 마운트 지점(이 두 곳만 바꿉니다)**
   - `MapHomeView` 계열에 `.overlay { SeasonPackOverlay(host: adapter) }` 한 줄. 기존 `AnnouncementBanner` 아래, 지도 위 레이어 순서를 지킵니다. 팩 오버레이는 `allowsHitTesting`을 기본 false로 두고 아이콘·산타처럼 누르는 것만 44pt 이상 히트 영역을 엽니다.
   - 홈 핀 옆 아이콘 자리를 `SeasonPackIconRegistry`가 그리는 뷰로 바꿉니다(핀 뷰 안에 넣지 말고 형제 레이어로 두어 기존 핀 제스처를 건드리지 않습니다).
   - 하루 공유 카드(`MapHomeDailyCard`)는 `SeasonPackHost`가 주는 「그날의 집 그림·캐릭터 레이어」를 쓰도록 인자 하나를 더합니다. 이벤트가 없으면 지금과 완전히 같은 그림이어야 합니다.

2-3. **패키지 등록**: `project.pbxproj`에 `XCLocalSwiftPackageReference`(`relativePath = Packages/SeasonPackKit`)와 앱 target의 `packageProductDependencies`를 `TaptionClassifierEngine` 자리를 보고 그대로 따릅니다. 시험은 `swift test --package-path Packages/SeasonPackKit`로도 돌 수 있게 하고, Xcode 시험 타깃 등록은 기존 패키지 시험 방식(`TaptionPlanTests` 안이 아니라 패키지 자체 시험)을 따릅니다.

## 3. 매니페스트 v1 (이 계약이 전부입니다)

3-1. **파일 배치 (R2 키, 8칸·영숫자·`.`·`_`·`-`만)**
```
packs/season/index.json                     ← 배급 목록(작음)
packs/season/<packId>/<version>/manifest.json
packs/season/<packId>/<version>/<파일…>      ← 그림·소리·라이선스 원문
```
`index.json`은 앱이 먼저 읽고, 지금과 가까운(±45일) 팩의 manifest만 받습니다.

```
{ "format": "bokki-season-packs", "schema": 1, "packs": [
  { "id": "christmas", "version": 1, "manifest": "packs/season/christmas/1/manifest.json",
    "requiresAppBuild": 1, "updatedAt": "2026-11-19T21:00:00+09:00" }
] }
```

3-2. **manifest.json** — 아래가 v1의 전부입니다. **모르는 열쇠·모르는 `kind` 값은 버리지 말고 무시**합니다(옛 앱이 새 팩을 받아도 앱이 죽지 않아야 함).

```
{
  "format": "bokki-season-pack", "schema": 1,
  "id": "christmas", "version": 1,
  "requiresAppBuild": 1,
  "event": { "id": "christmas", "kind": "holiday", "announcementId": "christmas-2026",
             "title": { "ko": "크리스마스", "en": "Christmas" },
             "windows": [ { "from": { "month": 12, "day": 19 }, "to": { "month": 12, "day": 30 },
                            "fromTime": "00:00", "toTime": "23:59" } ] },
  "assets": [ { "id": "house.tree", "path": "house-tree.png", "sha256": "…", "bytes": 12345, "kind": "image" },
              { "id": "carol.jingle", "path": "jingle-bells.m4a", "sha256": "…", "bytes": 543210, "kind": "audio" } ],
  "slots": {
    "house": { "base": "house.tree", "lit": "house.tree.lit", "glow": "house.tree.star",
               "lights": { "on": "sunset", "off": "sunrise", "blink": { "periodMs": 1400, "fastPeriodMs": 220 } } },
    "outfit": { "white": [], "calico": [], "mackerel": [] },
    "accessory": { "hat": "accessory.santaHat", "scarf": "accessory.scarf", "ribbon": "accessory.antlers" },
    "bubbles": { "pool": [ { "ko": "메리 크리스마스! 🎄", "en": "Merry Christmas! 🎄" } ] },
    "shareCard": { "house": "house.tree", "outfit": true }
  },
  "textSlots": [ { "id": "year", "rect": [0.30, 0.62, 0.40, 0.16], "align": "center",
                   "font": { "size": 17, "weight": "bold", "design": "rounded" },
                   "color": "#FFFFFF", "content": "year", "transition": "roll" } ],
  "menuIcons": [ { "id": "christmas.info", "icon": "icon.bell", "anchor": { "dx": 46, "dy": -30 },
                   "visibleFrom": "2026-12-19T00:00", "visibleTo": "2026-12-30T23:59",
                   "menu": { "title": { "ko": "크리스마스", "en": "Christmas" },
                             "sections": [ { "title": { "ko": "음원 출처", "en": "Music credits" },
                                             "items": [ { "id": "credits", "kind": "credits" } ] } ] } } ],
  "audio": [ { "id": "carol", "asset": "carol.jingle", "durationMs": 47612, "loop": false,
               "license": { "title": "Jingle Bells on a Music Box", "creator": "MJvGent",
                            "license": "CC0-1.0", "source": "https://freesound.org/s/546207/" } } ],
  "lyrics": [ { "audio": "carol", "cues": [ { "atMs": 900, "ko": "징글벨, 징글벨", "en": "Jingle bells, jingle bells" } ] } ],
  "actors": [ { "id": "santa", "image": "actor.santa", "flight": { "seconds": 9, "start": [-0.15, 0.25], "end": [1.15, 0.35] },
                "intervalSeconds": [180, 300], "tap": { "burst": { "images": ["gift.a", "gift.b", "gift.c"], "count": 18 } } } ],
  "interactions": [ { "id": "tree.tap", "target": "house", "on": "tap",
                      "actions": [ { "kind": "blink", "seconds": 6 }, { "kind": "playAudio", "audio": "carol" },
                                   { "kind": "lyrics", "audio": "carol" } ] } ],
  "credits": [ { "ko": "음원: Jingle Bells on a Music Box (MJvGent) · CC0 1.0",
                 "en": "Music: Jingle Bells on a Music Box (MJvGent) · CC0 1.0" } ]
}
```

3-3. **지켜야 할 계약**
   - `windows`는 **월·일 기준**이라 해가 바뀌어도 그대로 씁니다. `year`를 넣으면 그해만. `from` > `to`인 창(12/31~1/1)은 **연말을 넘는 창**으로 읽습니다(지금은 쓰지 않지만 시험으로 고정).
   - `fromTime`/`toTime`은 `HH:mm`·`sunset`·`sunrise` 중 하나. 창과 시간 조건이 모두 맞아야 활성입니다.
   - `textSlots[].content`는 `year`·`memo`·정적 문자열만. **연도 숫자를 그림에 굽지 않는 이유가 이것입니다** — 해가 바뀌면 앱이 그 해 숫자를 그립니다.
   - `assets[].path`는 팩 폴더 기준 상대 경로, 소문자·영숫자·`.`·`-`·`_`만.
   - `audio[].license`는 필수입니다(5절 라이선스 규칙).

3-4. **검증(manifest validation)**: 파일 크기 상한(팩 전체 8MB, 그림 400KB, 소리 2MB), `sha256` 정확, 필수 열쇠 존재, 창이 겹치지 않음, `requiresAppBuild`가 지금 빌드보다 크면 **받지 않고** 「나중에」로 표시. 하나라도 어긋나면 그 팩만 버리고 기본 팩으로 갑니다(앱은 절대 죽지 않음).

## 4. L1 배급 — 받기·보관·폴백

4-1. **받는 시점**: 앱 진입과 `scenePhase == .active`에서, 기존 공지 새로고침이 걸린 두 자리(`MapHomeView+Support.swift:220`·`:223`) 옆에서 `SeasonPackCenter.shared.refresh()`를 부릅니다. 인덱스 주소는 `{중계 서버}/public/assets/packs/season/index.json`, 팩 파일은 `{중계 서버}/public/assets/packs/season/…` 하나(서버 주소는 코드에 이미 있는 `TripRelay`가 정하고, 지시서·문서에 실제 도메인을 적지 않음). **쿨다운 30분**(`AnnouncementService.cooldown`과 같은 값), ETag, 8초 타임아웃, 1회 시도, 실패는 조용히(`AnnouncementService.refresh()`와 같은 정책).

4-2. **저장**: `Application Support/SeasonPacks/<packId>/<version>/`. `TripShareSidecar`처럼 디렉터리를 주입받아 시험이 임시 폴더로 돌립니다. 쓰기는 임시 파일 → 해시 확인 → `rename`(중간에 끊겨도 반쯤 쓴 팩이 남지 않게). 팩 폴더에 `installed.json`(버전·해시·받은 시각·서버 Date)을 둡니다.
   - **지우지 않습니다**(대표 지시: 다음 해 같은 기간에 재사용). 해시가 같으면 다시 받지 않습니다.
   - 상한: **최근 3개 버전·32MB**. 넘으면 가장 오래 안 쓴 팩 폴더부터 지웁니다(지금 기간에 쓰는 팩은 절대 지우지 않음).
   - `isExcludedFromBackupKey`로 iCloud 백업에서 뺍니다. 스냅숏·백업·동기화 어디에도 넣지 않습니다.
   - 「모든 데이터 삭제」(`AppModel.deleteAllUserData`)에 `SeasonPacks` 폴더와 메모 저장소 삭제를 함께 넣습니다.

4-3. **폴백**: 활성 팩이 없거나·손상·미수신이면 **기본(base) 표현 그대로**(지금의 집 그림·캐릭터·말풍선). 팩이 없을 때 앱 모양이 달라지면 그 자체가 결함입니다.

4-4. **네트워크 예절**: 요청은 인증·식별자·쿼리 없는 `GET` 하나. 좌표·기기 id·계정을 싣지 않습니다. 저데이터 모드·셀룰러에서는 2MB 넘는 팩을 받지 않고 다음 Wi-Fi에서 받습니다(`OfflineVectorNetworkPath.allowsCaching` 선례). 받는 동안 지도·재생이 느려지면 안 됩니다(다운로드는 백그라운드 URLSession이 아니라 짧은 `URLSession.data` 하나, 팩당 파일 수 ≤ 40).

4-5. **공지 팝업 연동**: 팩이 처음 활성화된 순간, 그 팩의 `announcementId`가 있으면 기존 `AnnouncementService` 목록에서 그 항목을 찾아 **기존 공지 시트로 한 번** 보여 줍니다(`SeasonPackHost.presentAnnouncement(id:)`). 새 팝업 UI를 만들지 않습니다. 공지 본문·기간은 R2 공지(`announcements/latest.json`)가 정본이고, 대표가 업로드합니다.

4-6. **번들 시드 팩 (중요)**: R2가 아직 배포되지 않았으므로, **크리스마스 팩과 표본 팩을 앱 번들 리소스로도 넣습니다**(`SeasonPacks/seed/…`, 패키지 리소스). 규칙:
   - 서버 인덱스가 있으면 **버전이 더 높은 쪽**을 씁니다(같으면 번들).
   - 시드가 있으므로 12/19에 서버가 없어도 크리스마스가 뜹니다.
   - 시드 팩도 같은 매니페스트·같은 해시 규칙을 씁니다(예외 경로를 만들지 않음).

## 5. L2 판정 — 시계·기간·트리거

5-1. **시계(`SeasonPackClock`)**: 이벤트 활성 판정에만 쓰는 시각입니다. 일반 앱 기능은 지금처럼 기기 시각을 씁니다.
   - 신뢰 시각 = ① 최근 성공한 중계 서버 응답(공지·팩·계획 어느 것이든)의 `Date` 헤더 + 그 뒤 흐른 단조 시간(`ProcessInfo.systemUptime`) ② 서버 응답이 24시간 넘게 없으면 기기 시각을 쓰되 **마지막 신뢰 시각 + 48시간** 안일 때만.
   - 기기 시각이 마지막 신뢰 시각보다 **12시간 넘게 앞서거나 10분 넘게 뒤로** 가면 의심으로 표시하고, 서버 `Date`가 확인해 줄 때까지 이벤트를 **켜지 않습니다**(fail-closed). 이벤트는 장식이라 안 뜨는 쪽이 낫습니다.
   - 서버가 없거나 오프라인이어도, 평소처럼 앱을 쓰던 사용자는 위 ②로 정상 동작합니다.
   - `#if DEBUG`에서만 `-seasonPackDate 2026-12-25T21:00` 같은 기준 시각 훅을 엽니다. **Release 빌드에는 이 코드가 컴파일되지 않아야** 하고, `#if DEBUG` 밖으로 새어 나간 날짜 조작 경로가 없는지 확인합니다(일반 사용자에게 날짜 조작 경로를 절대 노출하지 않는다).

5-2. **기간 판정**: `windows` + 기기 시간대로 「지금 활성 팩」을 고릅니다. 창이 겹치면 `priority`가 높은 하나만 활성(없으면 `version` 큰 것). 창 밖이면 **렌더 자체를 하지 않습니다**(지난 이벤트는 다시 보이지 않음).

5-3. **시간대 트리거**: `SeasonPackTriggers`가 `SeasonPackHost.sunEvents(on:)`(앱은 `MapHomeAstronomy.solarDay` 사용)로 그날 일몰·일출을 받아 `sunset`/`sunrise`를 실제 시각으로 풉니다. 좌표가 없으면(집 미등록) 트리거는 꺼지고 창 조건만 씁니다. **좌표는 어디로도 나가지 않습니다.**

5-4. **자정·정각**: `needsExactMinute`가 있는 트리거는 다음 정각까지 타이머 하나만 겁니다(1초 폴링 금지). 화면이 꺼져 있거나 앱이 뒤로 가면 타이머를 놓아두고, 앞으로 오면 그 시각 기준으로 다시 판정합니다.

## 6. L3 표현 — 슬롯과 렌더

6-1. **슬롯(팩이 들고 오는 것)**: `character.outfit`(의상)·`character.accessory`(악세사리, 의상과 **별도 슬롯**)·`house`(집 아이콘)·`bubbles`(대사 세트)·`audio`·`lyrics`·`shareCard`. 접근성으로 글자 크기를 키워도 배율은 기존 `TaptionType` 규칙을 따릅니다.

6-2. **집 아이콘**: 78pt 원 안에 지금의 `HomeEvolution` 대신 팩 그림을 넣습니다. `base`(낮)와 `lit`(점등) 두 장을 겹쳐 두고 `lights.on`·`lights.off`로 크로스페이드, `glow`는 꼭대기 별·반짝임 레이어입니다. 점멸은 `periodMs`(느림)·`fastPeriodMs`(터치 직후)로만 만들고, **동작 줄이기·저전력·저휘도에서는 점멸을 멈추고 `lit` 정지 그림**을 씁니다(`MapHomeHomeArtClock`의 기존 정책과 같게). 집 아이콘의 기존 탭(하루 요약 열기)은 유지하고, 팩의 트리 탭은 **핀 위 트리 영역에서만** 받습니다(겹치면 하루 요약이 우선, 트리는 점등 상태에서만 히트).

6-3. **캐릭터 레이어**: `outfit`·`accessory`는 **PNG 레이어**입니다. 앱의 리그는 코드로 그리므로, 팩 레이어는 `anchor`(`head`·`body`·`tail`·`feet`)·`scale`·`offset`·`z`를 매니페스트에 적고 `HwarangSceneView` 위에 얹습니다. `HwarangSceneView`에 **`hatImage: UIImage?`를 추가**해(기본 nil, `hatAssetName`은 그대로) 팩 모자를 파일에서 얹을 수 있게 합니다. 악세사리는 세 칸(`hat`·`scarf`·`ribbon`)에 하나씩이며, 이벤트 기간에는 기존 착용 장식을 **덮어쓰되 지우지 않습니다**(기간이 끝나면 원래 장식으로 그대로 복귀). 기존 `MapHomeGrowthSeason`·`AppFeatureSettings` 스키마는 바꾸지 않습니다(이벤트 착용 상태는 팩 쪽 `UserDefaults`/곁 파일에만).

6-4. **연도·숫자 텍스트 슬롯**: `textSlots[]`의 `rect`(그림 기준 0~1)에 앱이 글자를 그립니다. `content: "year"`면 **그 해 숫자**를 그리고, 해가 바뀌는 순간 `transition: "roll"`이면 위에서 아래로 굴러 내려오는(플립) 전환을 합니다. 마스크로 자리를 제한하고, 숫자는 `monospacedDigit`으로 흔들리지 않게 합니다. `content: "memo"`면 그 기간의 메모 첫 줄(길면 말줄임).

6-5. **말풍선**: 이벤트 기간에는 팩 `bubbles.pool`을 `MapHomeDefaultBubblePool` **앞에** 둡니다(기존 풀은 지우지 않고 순서만). 저장되는 말풍선(`AssistantBubble`)과 섞지 않습니다 — **캐럴 가사·시연 대사는 저장하지 않는 일회성**이고, 스냅숏·백업·AI 기록에 남지 않습니다. 저장 말풍선이 있는 시각에는 그것이 우선입니다.

6-6. **소리**: `AVAudioPlayer` 하나(`SeasonPackSoundPlayer`, `VoiceMemoPlayer` 모양). 세션은 `.ambient` + `mixWithOthers`(사용자가 듣던 음악을 끊지 않음), 무음 스위치는 존중. 화면을 벗어나거나 앱이 뒤로 가면 멈춥니다. 소리는 한 번에 하나(캐럴 재생 중 다른 터치는 무시).

6-7. **하루 공유 카드**: 이벤트 기간에 카드가 같은 집 그림·캐릭터 레이어를 씁니다. `ImageRenderer` 경로에서 파일 이미지를 쓰므로 `Image(uiImage:)`로 넣고, 렌더 전에 그림을 미리 읽어 둡니다(카드 만드는 동안 디스크를 다시 읽지 않음). 기간이 끝나면 원래 그림으로 자동 복귀. 카드 안에 팩 이름·라이선스는 넣지 않습니다(크레딧은 7-6절 화면).

## 7. L4 상호작용 — 터치·시연·가사

7-1. **트리 터치**(`interactions: house.tap`): ① 전구 빠른 점멸 6초 ② 캐럴 재생 ③ 가사 큐 말풍선을 순서대로. 캐럴 재생 중 다시 누르면 처음부터(또는 계속) — **정책은 「멈춤」**: 재생 중 터치는 정지가 아니라 「가사·점멸 다시 시작」, 소리는 끝까지. 사용자가 화면을 벗어나면 정지.

7-2. **가사 큐**: `atMs` 오름차순, 말풍선 하나씩(다음 큐가 오면 바뀜), 마지막 큐 뒤 2초에 사라짐. 큐 시각은 **실제 음원 기준**으로 재고(±150ms), 미리보기에서 눈으로 확인합니다. 말풍선은 캐릭터 머리 위(지도 핀 기준)에 뜨고, 지도 이동과 무관하게 화면 기준으로 붙입니다.

7-3. **산타 비행·선물**: `actors[]`가 화면 위를 지나갑니다. ① **팩을 처음 받은 직후(다운로드·해시 확인이 끝난 뒤에만) 무조건 1회** 시연 ② 이후 3~5분 간격(무작위는 기기에서 결정적으로 — 같은 시간대에 늘 같은 간격이 되도록 시드) ③ 산타를 탭하면 비행이 **멈추고** 선물이 뿌려집니다(`burst`: 팩 그림 18개, 위로 튀었다 내려오는 1.2초). ④ 아무 데나 탭하면 그 회차는 멈춥니다. ⑤ 동작 줄이기·저전력에서는 비행하지 않고 시연 1회도 생략합니다. ⑥ 지도 제스처를 막지 않습니다(산타 44pt 외 히트 없음).

7-4. **시연 상태 저장**: 「이미 1회 시연함」은 팩 id+version별로 `UserDefaults`에 남깁니다. 다시 받아도 다시 시연하지 않음(버전이 오르면 새로 1회).

7-5. **이벤트 아이콘 레지스트리(일반 구조, 8절)의 터치**는 `menuIcons[].menu`가 엽니다. 팩이 정의한 제목·항목·입력 방식대로 그리고, 앱은 어떤 이벤트인지 모릅니다.

7-6. **크레딧**: 설정 › 내 데이터 아래(또는 패키지 메뉴의 `credits` 항목)에 「시즌 팩 음원 출처」 화면 하나. 설치된 팩의 `audio[].license`(제목·만든이·라이선스·출처 링크)와 라이선스 원문 파일을 보여 줍니다. **앱에 크레딧 화면이 아직 없으므로 이번에 만듭니다**(설정 시트에 한 줄 추가 + 패키지 뷰).

## 8. 이벤트 아이콘 레지스트리(이 요청의 핵심 구조)

8-1. **요구**: 이벤트 기간에만 지도·홈에 아이콘이 생기고, 그 아이콘을 누르면 **그 팩이 정의한 메뉴**가 열립니다. **앱 코드 수정 없이 매니페스트 `menuIcons[]`에 항목만 추가하면** 아이콘과 메뉴가 붙어야 합니다. 새해 메모는 이 구조의 한 사례일 뿐이고, 이번에는 **새해 메모 팩을 만들지 않습니다**(11절).

8-2. **항목 계약**
```
{ "id": "unique.id", "icon": "asset.id", "label": { "ko": "새해 메모", "en": "New year memo" },
  "anchor": { "dx": 46, "dy": -30 }, "priority": 10,
  "visibleFrom": "2026-12-30T00:00", "visibleTo": "2027-01-01T23:59",
  "menu": { "title": {…}, "sections": [ { "title": {…},
            "items": [ { "id": "goal", "kind": "memo", "label": {…}, "maxLength": 200,
                         "readOnlyAfter": "2027-01-01T23:59" } ] } ] },
  "onOpen": "menu" }
```
   - `kind`: `text`(읽기 전용 글)·`memo`(쓰기 가능한 메모)·`credits`·`link`(https만)·`toggle`. 새 `kind`는 모르면 그 항목만 감춥니다.
   - 위치는 **집 아이콘 기준 상대 좌표**(`dx`·`dy`, pt)이고, 여러 이벤트가 겹치면 `priority` 순으로 `dy`를 44pt씩 밀어 배치합니다. 화면 밖으로 나가면 위/아래로 접습니다.
   - `visibleFrom`/`visibleTo` 밖이면 **뷰를 만들지 않습니다**(투명도 0이 아니라 아예 없음). 창은 팩 기간과 별개로 더 좁을 수 있습니다(새해 메모 = 12/30~1/1 사례).
   - `memo` 항목은 기간이 지나면 **읽기 전용**(입력·저장·지우기 막힘, `readOnlyAfter` 이후). 메모는 `Application Support/SeasonPacks/memos/<packId>/<itemId>.json`에 두고 백업·스냅숏에 넣지 않습니다.
   - 메모 내용을 팩 말풍선에 계속 노출하는 요구는 **`bubbles`의 `content: "memo"` 자리**로 구조에만 열어 둡니다(다음 단계에서 새해 팩이 씀).

8-3. **메뉴 화면**: 패키지의 `SeasonPackMenuView` 하나가 모든 이벤트 메뉴를 그립니다(시트, 기존 시트 모양·여백 규칙). 제목·항목·입력 방식은 전부 매니페스트에서 옵니다. 앱은 「무슨 이벤트인지」 알지 못합니다.

8-4. **증명(1단계 완료 조건)**: 번들 표본 팩 `sample`(기간 1970-01-01, Release에서 절대 활성되지 않음)에 `menuIcons[]` 항목 1개를 넣고, `#if DEBUG` 미리보기(`-seasonPackPreview sample`)로 ① 아이콘이 뜬다 ② 누르면 메뉴가 열린다 ③ 매니페스트에서 그 항목을 지우면 아이콘·메뉴가 사라진다 ④ **앱 코드는 한 줄도 바꾸지 않는다**를 확인합니다. 이 네 가지를 회신에 적습니다.

## 9. 크리스마스 팩 (첫 실제 팩)

9-1. **기간**: 매년 12/19 00:00 ~ 12/30 23:59(기기 시간대). 2026년은 12/19(토)~12/30(수).

9-2. **집 아이콘**: 크리스마스트리. `base`(낮 그림)·`lit`(불 켜진 그림)·`glow`(꼭대기 별). **일몰부터 점등**(`lights.on: "sunset"`, `lights.off: "sunrise"`), 전구는 `periodMs 1400`으로 천천히 깜빡이고, 꼭대기 별은 고정. 동작 줄이기·저전력에서는 정지한 `lit` 그림.

9-3. **트리 터치**: ① 빠른 점멸(`fastPeriodMs 220`, 6초) ② 캐럴 ③ 가사 말풍선 순서대로. 캐럴이 끝나면 점멸도 멈추고 `periodMs` 점등으로 돌아옵니다.

9-4. **음원(확정 후보, 2026-11-19 조사)**: 1순위 **「Jingle Bells on a Music Box」 by MJvGent, 47.612초, CC0 1.0** (`https://freesound.org/people/MJvGent/sounds/546207/`). 멜로디는 James Pierpont 1857(퍼블릭 도메인), 녹음은 CC0. 오르골 음색이라 앱의 작은 캐릭터 톤과 맞고 47초라 팩 크기도 작습니다.
   - 대안(같은 CC0, 조사 완료): 「Music Box – Joy To The World」 by mhtaylor67 51.413초(`/sounds/260557/`), 「Deck The Halls – Christmas jingle played with bells」 by Ihaksi 7.594초(`/sounds/411420/` — 짧아서 「트리 터치 효과음」에 적합), 「symphonion O Christmas Tree」 by thulitt 34.150초(`/sounds/150026/`), 「Musical Snow Globe – We Wish You A Merry Christmas」 by mhtaylor67 83.033초(`/sounds/260556/` — 태엽 소리 섞임).
   - **퍼블릭 도메인이지만 CC0가 아닌 것**(미국 정부 저작물 등)은 이번에 쓰지 않습니다: 미국 공군악대 연주들(예: Deck the Halls 2:31, Silent Night 3:17). 필요하면 대표 결정 뒤에.
   - 원본 WAV는 R2에 `packs/season/christmas/1/audio/jingle-bells-music-box.wav`(원본 보관), 앱이 받는 파일은 **AAC 96kbps 모노 m4a**(≤1.5MB)로 바꿔 `…/audio/jingle-bells.m4a`. 변환은 `ffmpeg`(있으면) 아니면 `afconvert`.
   - 라이선스 원문 CC0 1.0 텍스트와 출처 URL을 `credits`와 크레딧 화면에 넣습니다.

9-5. **가사 큐**: 「Jingle Bells」 1절·후렴을 **퍼블릭 도메인 원문**으로 쓰고, 한국어는 앱이 새로 쓴 1~2줄 요약(외부 번역문 금지). 큐는 음원 기준 `atMs`(±150ms)로 넣고, 말풍선은 한 번에 하나. 예: 0.9s 「징글벨, 징글벨 / Jingle bells, jingle bells」 …

9-6. **의상·악세사리**: 세 캐릭터 공통 — `accessory.hat` 산타 모자, `accessory.scarf` 목도리, `accessory.ribbon`(리본 자리) 루돌프 뿔. `outfit`은 산타 코트(몸통 레이어) 1장. 악세사리 슬롯은 **의상과 별도**이고, 기간 중 기존 착용 장식을 덮었다가 기간이 끝나면 원래대로 복귀. 악세사리 PNG는 캐릭터별 털색에 물들지 않게 반투명 여백을 포함해 3배율로.

9-7. **말풍선 세트**: 크리스마스 대사 12~16줄(ko/en). 기간 중 `MapHomeDefaultBubblePool`보다 먼저 고릅니다. 예: 「트리 불 켜 볼까요? 🎄」·「산타가 지나갔어요!」·「오늘 하루도 수고했어요」.

9-8. **산타 비행**: `actors[]` 항목 하나 — 산타+루돌프 PNG(가로 256×160 안팎), 왼쪽 아래→오른쪽 위 또는 그 반대, 9초, 3~5분 간격. **팩 최초 수신 직후 1회 무조건 시연**. 산타 탭 → 비행 정지 + 선물 18개 뿌리기(팩 그림 3종, 위로 튀었다 중력으로 내려와 1.2초 뒤 사라짐). 아무 데나 탭 → 그 회차 정지.

9-9. **하루 공유 카드**: 12/19~12/30에 만든 카드는 트리 집 그림 + 산타 의상/악세사리로 그리고, 12/31부터는 원래 그림. 카드 렌더가 디스크를 기다리지 않게 그림을 미리 읽습니다.

9-10. **아이콘**: 집 핀 옆에 「크리스마스 안내」 아이콘 하나(8절 레지스트리, `priority` 10). 메뉴에는 ① 이벤트 소개 1~2줄 ② 음원 출처(크레딧 항목). **새해 메모처럼 기간이 좁은 사례는 다음 단계**이며, 이번 크리스마스 아이콘은 12/19~12/30 전체에 보입니다. (이 아이콘은 비야 제안입니다 — 대표가 빼라고 하면 매니페스트에서 지우면 끝이고 앱 코드는 그대로입니다. 그 사실 자체가 이 구조의 증명입니다.)

9-11. **그림 제작**: 팩 그림은 **PNG**로 만듭니다(SVG는 다운로드 자산으로 쓸 수 없음 — asset catalog 전용). `tools/generate_hwarang_hats.py`처럼 생성 스크립트를 저장소에 남깁니다(`tools/season-pack/`): SVG 문자열을 만들고 `qlmanage -t` 또는 `rsvg-convert`/Pillow로 PNG 변환, 실패하면 CoreGraphics Swift 스크립트로 직접 그립니다. 크기: 집 그림 512×512(투명 여백 포함), 악세사리·레이어는 표시 크기의 3배, 아이콘 96×96, 산타 768×480. 각 ≤400KB. 만든 뒤 미리보기로 눈으로 확인하고, 그림이 없거나 깨져도 기본 그림으로 폴백하는지 시험합니다.

9-12. **R2 업로드(대표 몫, 지시서에 명령을 적어 둘 것)**: `npx wrangler r2 object put … --content-type … --cache-control "public, max-age=86400" --remote`로 `packs/season/…` 아래에 올리고, `index.json`을 마지막에 올립니다(반쯤 올라간 팩을 앱이 받지 않게). 이 명령은 실행하지 않고 회신의 「대표 몫」에 적습니다.

## 10. 확장성 요건 (다른 이벤트는 이번에 만들지 않음 — 구조가 받아낼 수 있어야 함)

아래는 **구현 요구가 아니라 설계·시험 요건**입니다. 매니페스트만으로 표현되거나, 안 되면 그 이유를 회신에 적습니다.

| 이벤트 | 구조가 받아내야 하는 것 | 이번 확인 방법 |
|---|---|---|
| 새해 12/31~1/1 | 연말을 넘는 창, `sunset` 트리거, 23:50 카운트다운, 00:00 다른 종소리, 연도 롤링 | 창 넘김·롤링 전환 단위 시험 |
| 새해 목표 메모 | `menuIcons[]` + `memo`(기간 후 읽기 전용) + 말풍선에 메모 노출 | 표본 팩으로 배선 확인, 메모 잠금 시험 |
| 설날 2027-02-06~02-09 | 한복·갓·족두리·복주머니를 **의상+악세사리 슬롯**으로, 집=경복궁, 까치 액터, 세배(모든 캐릭터 등장·랜덤 순서·대사), 세뱃돈 말풍선 | 슬롯 3칸·액터 여러 개·대사 큐 시험 |
| 밸런타인데이 | **선택 캐릭터에 따라 분기**(받는 캐릭터가 다름) | `interactions[].when: {characterID}` 조건 시험 |
| 수능(2027-11-18) | 11월 셋째 목요일 같은 규칙 날짜 | `windows[].rule: "nthWeekday"` 파싱 시험(올해는 지났으므로 다음 해) |
| 식목일 04-05 | 하루 동안 **시간대별 단계**(나무 성장) | `house.stages[]`(시각→그림) 시험 |
| 부처님오신날 | 음력 4/8, 석가모니상·승복·연등 | 음력 날짜는 **매니페스트에 그해 날짜로 적는 방식**으로 두고 앱은 양력만 읽는다(음력 계산은 앱에 넣지 않음) |

설날 세배 대사의 **고양이 울음소리 톤(피치·포먼트 변조)** 요구는 이번 범위가 아니지만, 소리 자산이 「원본 + 변조본」 두 파일로 올 수 있게 `audio[]`만 열어 둡니다(변조는 팩 제작 단계에서).

## 11. 이번에 하지 않는 것(범위 고정)

- 새해·설날·밸런타인·수능·식목일·부처님오신날의 **팩·에셋·UI 구현**. 위 10절의 요건·시험만.
- 새해 목표 메모 팩·아이콘. (레지스트리·메모 저장·잠금 **구조**는 만들고 표본 팩으로 증명만.)
- 서버(`server/trip-relay`) 수정·배포·R2 쓰기·`wrangler` 실행. R2 버킷 생성·업로드는 대표 몫.
- 앱 릴리스·TestFlight 업로드·App Store 제출.

## 12. 확인 기준

- 새 패키지 `SeasonPackKit`이 앱과 분리되어 있고, 앱 본체 수정은 「마운트 두 줄 + 어댑터 + 카드 인자 하나 + 설정 한 줄」을 넘지 않는다.
- **매니페스트 `menuIcons[]`에 항목만 넣으면 앱 코드 수정 없이 아이콘과 메뉴가 뜨고, 지우면 사라진다**(표본 팩으로 4가지 확인, 회신에 적음).
- 크리스마스 팩이 번들 시드로도 R2로도 동작하고, 12/19 이전·12/31 이후에는 **렌더 자체가 없다**(기간 밖 스크린샷·시험).
- 트리 터치에 점멸·캐럴·가사 말풍선이 음원에 맞춰 순서대로 나오고, 말풍선은 저장되지 않는다(스냅숏·백업에 안 들어감).
- 산타가 최초 수신 직후 1회 시연되고, 이후 3~5분 간격이며, 탭하면 멈추고 선물이 뿌려진다. 동작 줄이기·저전력에서는 비행하지 않는다.
- 연도·숫자는 그림이 아니라 런타임 텍스트로 그려지고, 해가 바뀌면 새 숫자로 바뀐다(롤링 전환 시험).
- 악세사리는 의상과 별도 슬롯이고, 기간이 끝나면 **기존 착용 장식으로 원복**한다(원래 장식이 지워지지 않음).
- 하루 공유 카드가 이벤트 그림으로 나오고 기간이 끝나면 원복한다.
- 기기 시각을 앞으로 돌려도 이벤트가 열리지 않고(fail-closed), Release 빌드에 날짜 조작 경로가 없다.
- 팩 없음·손상·미수신·서버 없음에서 앱이 지금과 똑같이 보이고 죽지 않는다.
- 좌표·기기 식별자·계정이 팩 요청에 실리지 않는다. 팩 파일은 백업에 들어가지 않고 「모든 데이터 삭제」에서 지워진다.
- 음원은 CC0 1.0만 쓰고, 출처·라이선스를 크레딧 화면과 `credits`에 남긴다. 『설날』(윤극영, 2058년까지 보호)은 쓰지 않는다.
- `swift test --package-path Packages/SeasonPackKit` 통과 수치, 앱 Debug 빌드, `-only-testing:TaptionPlanTests` 전체 통과 수치가 회신에 있고, 기존 실패 항목과 구분돼 있다.
- `architecture-metrics.py --check`·`check-app-engine-import-boundary.sh` 통과, 동결 파일 5개·`server/trip-relay`·미커밋 `PlaceBook_kr_sungnyemun.svg` 무변경, 새 파일 각 1,200줄 미만.
- 새 앱 UI 문구는 `language.text` 리터럴(패키지 안 문구는 `SeasonPackText`), 12개 언어 누락은 「번역 대기」로만 보고.

## 13. 단위 시험 (최소 목록)

1. **매니페스트**: 정상 파싱, 모르는 열쇠·모르는 `kind` 무시, 필수 열쇠 누락은 그 팩만 버림, 큰 파일·해시 불일치 거부.
2. **창 판정**: 12/19~12/30 매년 반복, 연말을 넘는 창, `sunset`/`sunrise` 트리거, 창 밖은 비활성, 겹칠 때 `priority`/`version`.
3. **시계**: 서버 Date + 단조 시간, 앞으로 12시간 점프 → 비활성(fail-closed), 뒤로 10분 → 고수위 유지, 오프라인 48시간 안은 기기 시각 허용, 48시간 밖은 비활성, DEBUG 훅은 기본 비활성.
4. **저장**: 원자적 쓰기, 해시 확인, 같은 해시 재다운로드 생략, 3개 버전·32MB 상한, 손상된 팩 폴백, 시드↔서버 버전 선택.
5. **렌더**: 연도 텍스트 슬롯(그 해 숫자), 롤링 전환 상태, 악세사리 3칸 덮어쓰기·원복, 집 그림 base/lit 크로스페이드, 동작 줄이기에서 정지 그림.
6. **아이콘 레지스트리**: 기간 밖은 뷰 없음, anchor 충돌 밀기, 모르는 `kind` 감춤, 메뉴 항목 파싱, `memo` 잠금(기간 후 읽기 전용), 메모 저장·삭제.
7. **가사 큐**: `atMs` 순서, 다음 큐에서 교체, 끝나면 사라짐, 음원 없으면 말풍선도 없음.
8. **시연 스로틀**: 최초 1회, 이후 180~300초, 탭 정지, 팩 버전이 오르면 새로 1회, 동작 줄이기에서 생략.
9. **소리**: 재생 중 다른 터치 무시, 화면 이탈 시 정지(플레이어 대역으로 시험).
10. **확장성**: 캐릭터 분기 조건, 여러 액터, `house.stages`, `nthWeekday` — 매니페스트 파싱·선택만.
11. **개인정보**: 팩 요청 URL에 좌표·식별자가 없고, 팩 저장 파일이 백업 제외 표시를 갖는다.

## 14. 검증 절차

1. `AGENTS.md` 5절 빌드 잠금(`/tmp/taptionplan-xcodebuild.lock`, `owner`에 「SEA1119A01 pid」) 안에서: `swift test --package-path Packages/SeasonPackKit` → 앱 Debug 빌드(시뮬레이터 `99AC6F35-6B50-4741-A11D-1A46E1F7F4BD`) → `-only-testing:TaptionPlanTests`(`-parallel-testing-enabled NO`). 실행·통과·실패·건너뜀은 xcresult로 읽어 회신에 적습니다.
2. 이미 실패 중인 항목(`TravelModeView` actor 격리, `DayStoreV3Tests` 간헐 실패)은 이번 변경과 섞지 말고 따로 적습니다. 새로 깨진 시험이 있으면 그것부터 고칩니다.
3. `python3 scripts/architecture-metrics.py --check docs/architecture-baseline.json`, `bash scripts/check-app-engine-import-boundary.sh`, `python3 scripts/l10n/extract.py` → `check.py`. `generate.py`는 메인 세션 몫이라 돌리지 않습니다.
4. 한글·영문 문구 확인: 새 문구가 `language.text`(앱) / `SeasonPackText`(패키지)인지, 12개 언어 누락 목록.
5. `test.md` `## 실기기 확인 목록` 「아이폰 11 Pro」 줄: 「① 12/19 이전에 집 아이콘이 평소와 같음 ② DEBUG 미리보기(`-seasonPackPreview christmas`)로 트리·점등·가사·산타·선물 확인 ③ 기간을 지나면 원복 ④ 매니페스트에서 아이콘 항목을 지우면 아이콘·메뉴가 사라짐 ⑤ 시계를 미래로 돌려도 이벤트가 안 뜸」. 시뮬레이터 결과와 기기 결과를 구분해 적습니다.

## 15. 문서

- 새 문서 `docs/SEASON_PACK_PLAN.md`: 이 아키텍처(4개 층, 모듈 경계, 매니페스트 v1 전체, 이벤트 캘린더, 아이콘 레지스트리, 라이선스 규칙, 배포 순서, 다음 단계 목록). 이 지시서의 3·4·5·6·7·8·10절을 그대로 옮겨 쓰는 문서입니다.
- `DEVELOPMENT.md` 「프로젝트 경계」 표에 `Packages/SeasonPackKit` 한 줄, `docs/NEXT_PLAN.md`는 손대지 않음.
- `PRIVACY.md` 「저장과 외부 전송」에 한 줄: 「시즌 이벤트 팩은 기간·그림·소리를 중계 서버에서 받아 오며, 이 요청에 좌표·계정·기기 식별자를 넣지 않습니다. 받은 팩은 기기에만 보관하고 iCloud 백업에 넣지 않습니다.」
- `pickle-bridge/inbox` → `done` 이동과 회신은 브리지 README 3·4절대로.

## 16. 하지 말 것

- **`server/trip-relay` 수정·서버 배포·D1/R2 쓰기·`wrangler` 실행** — 대표 몫입니다. 앱은 이미 있는 `/public/assets/packs/…` 읽기만 씁니다.
- R2 버킷 생성·파일 업로드·`--remote` 실행. 명령만 회신에 적습니다.
- 동결 파일 수정: `TaptionPlan/Core/HealthKitImportCoordinator.swift`, `TaptionPlan/UI/AppShellView.swift`, `TaptionPlan/UI/MapHomeNLEClipEditor.swift`, `TaptionPlan/UI/MapHomeTimeSidebar.swift`, `TaptionPlan/UI/MapHomeVectorMap.swift`.
- `MapHomeView.swift` 본 파일에 `@State`·저장 속성 더하기(새 상태는 패키지나 새 파일). 기존 핀 제스처·하루 요약 열기 동작 바꾸기.
- `MapHomeGrowthSeason`·`AppFeatureSettings` 스키마·Codable 변경, 저장소(SQLite)·백업 형식·iCloud 동기화에 팩 상태 넣기.
- `TaptionPlan/Assets.xcassets/PlaceBook/…PlaceBook_kr_sungnyemun.svg`(다른 세션 미커밋 변경) 커밋에 넣기. 경로를 지정해 이번에 만진 파일만 커밋.
- 저장소·자산에 실제 좌표·집 주소·계정·메일·서버 도메인·키를 쓰기(저장소는 공개 — `AGENTS.md` 8절).
- 라이선스가 CC0가 아닌 녹음(CC BY·CC BY-NC·미국 정부 저작물 PD 포함)을 이번 팩에 넣기. 『설날』(까치까치 설날은) 사용 금지.
- 일반 사용자가 누를 수 있는 날짜 조작·미리보기 경로 만들기. `#if DEBUG` 밖으로 훅 내보내기.
- 새 이벤트 팩(새해·설날·밸런타인 등) 제작.
- `try!`·`Task.detached`·`fatalError`·`nonisolated(unsafe)`·`@unchecked Sendable`·`DispatchQueue.main` 늘리기, `docs/architecture-baseline.json` 고치기.
- `UIText.xcstrings`·`Localizable`·`translations/*.json` 손으로 고치기, `generate.py` 돌리기.
- 시험·문서·팩에 사용자 지정 이름·일정 제목·메모·장소를 넣기(가짜 값만).

## 참고

- 아키텍처 원본: 이 지시서 2~10절(대표님 2026-11-19 통화 설계를 문서로 옮긴 것). 저장소 문서로는 15절의 `docs/SEASON_PACK_PLAN.md`.
- 서버 배급 규격: `server/trip-relay/README.md` 「공용 공지·정적 데이터」, `docs/ACTIVITY_RELAY_API.md`(경로·인증 표 형식).
- 앱 쪽 선례: `TaptionPlan/Core/AnnouncementFeed.swift`(쿨다운·ETag·조용한 실패), `TaptionPlan/Core/TripShareSidecar.swift`(곁 파일·`Mutex`·주입 디렉터리), `TaptionPlan/Core/OfflineVectorTileCache.swift`(Application Support를 쓰는 이유·연결 종류 판정), `TaptionPlan/Core/VoiceMemoServices.swift:161`(`AVAudioPlayer`), `TaptionPlan/UI/MapHomeHomeSkyMath.swift`(`MapHomeAstronomy.solarDay`), `TaptionPlan/UI/MapHomeMapAnnotations.swift:160·:297·:397`, `TaptionPlan/UI/MapHomeGrowthPolicy.swift:82·:199·:404`, `TaptionPlan/UI/HwarangCoat.swift:3`, `TaptionPlan/UI/HwarangRig.swift`(`HwarangSceneView`)·`:1161`(`hatAssetName`)·`:1177`(`UIImage(named:)`), `TaptionPlan/UI/MapHomeDailyCard.swift:189`(모자)·`:273`(집 그림), `TaptionPlan/UI/MapHomeDefaultBubblePool.swift:6`, `TaptionPlan/UI/AssistantBubble.swift:121`, `TaptionPlan/UI/AnnouncementBanner.swift`(공지 배너·시트), `TaptionPlan/UI/MapHomeView+Support.swift:215~223`(새로고침 걸린 자리).
- 패키지 등록: `TaptionPlan.xcodeproj/project.pbxproj`의 `XCLocalSwiftPackageReference`(`TaptionClassifierEngine` 자리), `scripts/check-app-engine-import-boundary.sh`.
- 자산 생성 선례: `tools/generate_hwarang_hats.py`, `scripts/generate_home_evolution_artwork.py`.
- 미뤄 둔 숙제: `test.md` `HOM1111A01`(2026-11-11 「나중에」) — 이번이 그 재개입니다.
- 음원 후보 조사(2026-11-19, 라이선스·길이 확인): MJvGent 「Jingle Bells on a Music Box」 47.612s CC0 1.0; mhtaylor67 「Music Box – Joy To The World」 51.413s CC0; Ihaksi 「Deck The Halls – bells」 7.594s CC0; thulitt 「symphonion O Christmas Tree」 34.150s CC0; mhtaylor67 「Musical Snow Globe – We Wish You A Merry Christmas」 83.033s CC0; 까치(설날용) naturenotesuk 「Eurasian Magpie Calling」 43.970s CC0. 모두 Freesound 페이지에서 라이선스 CC0 1.0을 확인했습니다.
