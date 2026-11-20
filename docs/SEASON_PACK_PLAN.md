# 시즌 이벤트 팩 계획 (SEA1119A01)

기간 한정 이벤트(성탄·새해·설날 등)를 **앱 본체를 고치지 않고** 매니페스트와 그림·소리로 붙이는 구조입니다. 2026-11-19 대표 지시로 `Packages/SeasonPackKit`이 표현·상호작용 화면까지 들고, 앱 target에는 얇은 마운트와 어댑터만 둡니다(`AGENTS.md` 4절). 이 문서는 지시서(`pickle-bridge/done/20261119-2212-season-pack-framework.md`)의 3~10절을 구현에 맞게 옮긴 것입니다.

## 1. 구조: 4개 층

| 층 | 하는 일 | 파일(`Packages/SeasonPackKit/Sources/SeasonPackKit/`) |
| --- | --- | --- |
| L1 배급 | 인덱스·매니페스트·파일을 받고 검증·보관, 번들 시드와 합침, 폴백 | `Store/` `Manifest/` |
| L2 판정 | 시계(서버 `Date`+단조 시간), 기간(월·일 창·연말 넘김·규칙 날짜), 일몰·일출 트리거, 다음 경계 타이머 | `Scheduler/` |
| L3 표현 | 집 그림(낮·점등·별빛·단계), 악세사리 세 칸, 글자 칸(연도 롤링), 말풍선 대사 | `Render/` |
| L4 상호작용 | 터치 시나리오, 가사 큐, 산타 비행·선물, 소리, 메모, 아이콘 레지스트리·메뉴 | `Interaction/` `Icons/` `Memo/` |

상태 허브는 `SeasonPackCenter`(앱당 하나, `.shared`)입니다. 앱이 구현하는 것은 `SeasonPackHost` 하나(`languageCode`·`characterID`·`homeCoordinate`·`buildNumber`·`now()`·`sunEvents(on:)`·`presentAnnouncement(id:)`·`reportDemoState`)이고, 앱 타입을 아는 곳은 `TaptionPlan/Core/SeasonPackAdapter.swift` 하나입니다. 패키지는 `TaptionPlanEngine`·`TaptionPlanCore`를 import하지 않습니다.

**앱 쪽 연결(전부)**
- `MapHomeView+Support.swift`: `.overlay { SeasonPackOverlay() }`(터치는 기본 통과, 아이콘·산타만 히트), 앱 진입·`scenePhase == .active`의 `SeasonPackAdapter.refresh()`, 산타가 날 때만 켜지는 탭 제스처(그 회차 멈춤).
- `MapHomeMapAnnotations.swift`: 집 아바타 그림 자리에 `SeasonPackHouseView`(이벤트가 없으면 기존 그림 그대로), 집 고양이에 시즌 모자·의상(`usesSeasonPack`).
- `HwarangRig.swift`: `HwarangSceneView.hatImage`(기본 nil) — 팩 모자를 파일에서 씌움.
- `MapHomeDailyCard.swift`: `MapHomeDailyCardView.seasonArt` 인자 하나(없으면 지금과 같은 그림).
- `MapHomeDefaultBubblePool.swift`: 이벤트 대사를 기본 풀 앞에 둠(기본 풀은 그대로).
- `AnnouncementFeed.swift`·`AnnouncementBanner.swift`: 팩이 켜질 때 기존 공지 시트를 여는 요청 하나.
- `AppModel+Backup.swift`: 「모든 데이터 삭제」에 `SeasonPackAdapter.deleteAll()`.
- `MapHomeSettingsSheets.swift`·`SeasonPackCreditsRow.swift`: 설정 › 내 데이터 아래 「시즌 팩 음원 출처」 한 줄(화면은 패키지의 `SeasonPackCreditsScreen`).

## 2. 매니페스트 v1

R2 키(8칸·영숫자·`.`·`_`·`-`, 서버 `GET /public/assets/<접두어>/…`):
```
packs/season/index.json
packs/season/<packId>/<version>/manifest.json
packs/season/<packId>/<version>/<파일…>
```
`index.json`: `{ "format": "bokki-season-packs", "schema": 1, "packs": [ { "id", "version", "manifest", "requiresAppBuild", "updatedAt" } ] }`.

`manifest.json`의 최상위 열쇠: `format`(`bokki-season-pack`)·`schema`(1)·`id`·`version`·`requiresAppBuild`·`priority`·`event`·`assets`·`slots`·`textSlots`·`menuIcons`·`audio`·`lyrics`·`actors`·`interactions`·`credits`. **모르는 열쇠·모르는 `kind`는 무시**하고 그 항목만 감춥니다. 필수 열쇠(`format`·`schema`·`id`·`version`·`event`·`assets`)가 없으면 그 팩만 버립니다. 실제 예는 번들 시드 `Resources/seed/christmas/1/manifest.json`.

- `event.windows[]`: `from`/`to`(`month`·`day`), `year`(그해만), `fromTime`/`toTime`(`HH:mm`·`sunset`·`sunrise`), `rule`(`nthWeekday`: `month`·`weekday`(1=일)·`nth`(1…5, -1=마지막)). **월·일 기준이라 해가 바뀌어도 그대로 씁니다.** `from` > `to`는 연말을 넘는 창. 시간 조건은 기간 전체에 걸친 구간입니다(첫날 `fromTime`부터 마지막 날 `toTime`까지). 좌표가 없어 일몰을 못 풀면 시간 조건은 꺼지고 창만 씁니다.
- `assets[]`: `id`·`path`(소문자·영숫자·`.`·`-`·`_`, 폴더 최대 3칸)·`sha256`·`bytes`·`kind`(`image`·`audio`).
- `slots.house`: `base`(낮)·`lit`(점등)·`glow`(별빛)·`lights`(`on`/`off`: `sunset`·`sunrise`·`HH:mm`, `blink.periodMs`·`fastPeriodMs`)·`stages[]`(`from` `HH:mm` → `image`, 식목일 같은 시간대별 단계).
- `slots.outfit`(캐릭터별 레이어 배열)·`slots.accessory`(`hat`·`scarf`·`ribbon`, 문자열 하나 또는 `{asset, anchor, scale, offset, z}`)·`slots.bubbles`(`pool`, `memoItem`)·`slots.shareCard`(`house`, `outfit`).
- `textSlots[]`: `rect`(그림 기준 0~1)·`content`(`year`·`memo`·정적 글)·`transition`(`roll`)·`font`·`color`. **연도 숫자는 그림에 굽지 않고** 앱이 그 해 숫자를 그립니다.
- `menuIcons[]`: 8절. `audio[]`(`license` 필수: `title`·`creator`·`license`·`source`)·`lyrics[]`(`atMs` 오름차순 큐, 언어별 글)·`actors[]`(`flight`·`intervalSeconds`·`tap.burst`·`when.characterID`)·`interactions[]`(`target`·`on`·`when`·`actions[]`: `blink`·`playAudio`·`lyrics`).
- 검증: 팩 8MB·그림 400KB·소리 2MB·파일 40개 이하, `sha256`·`bytes` 정확, 창이 겹치지 않음, 자산 참조가 실제로 있음, `requiresAppBuild`가 지금 빌드보다 크면 받지 않고 「나중에」, 예약 id(`memos`) 금지. 하나라도 어긋나면 그 팩만 버리고 기본 모습으로 갑니다.

## 3. 배급·보관

**현재 방식(2026-11-20~): 팩 하나 = 파일 하나(`.bpack`)를 이어 받기.** 아래 「예전 방식」은 카탈로그 항목에 `archive`가 없을 때만 쓰는 호환 경로입니다.

- 파일 `<id>-<version>.bpack`(압축 없는 단순 컨테이너, `SeasonPackArchive`): `"BSPK" | 형식 버전 1 | 매니페스트 길이(u32 BE) | 매니페스트 JSON | assets 순서대로 파일 바이트`. 압축이 없어 풀면서 부풀 수 없고(선언한 크기 = 실제 크기, 팩 8MB·파일 40개·매니페스트 256KB 상한을 읽기 전에 확인), 경로는 매니페스트 `assets`의 상대 경로만이라 경로 탈출(`..`·절대 경로·중복)은 거절합니다. 개별 파일은 매니페스트의 SHA-256, 파일 전체는 카탈로그의 SHA-256이 지킵니다.
- 카탈로그 `packs/season/index.json`: `{format, schema, packs:[{id, version, archive:{key, bytes, sha256}, requiresAppBuild?, windows?, updatedAt?}]}`. `windows`는 매니페스트 `event.windows`의 사본이라 받기 전에 「지금 ±45일 안인가」를 가려 먼 팩의 큰 파일은 받지 않습니다. `key`는 `packs/season/<id>/<version>/<id>-<version>.bpack`.
- **운영 기간(`schedule`, ADM1120A02)**: 카탈로그 항목에 `schedule: [{from, to}]`(오프셋이 있는 ISO 8601 절대 시각, `[from, to)`)이 있으면 그 팩은 매니페스트 `event.windows` 대신 이 기간에만 켜집니다. 칸을 여러 개 두어 같은 팩을 여러 번 열 수 있고(예: 이번 주말, 다음 주 수~일), 빈 목록이면 꺼 둡니다. 칸이 없거나 카탈로그에서 팩을 빼면 매니페스트 기간(번들 시드 포함)으로 돌아갑니다. 앱은 받은 카탈로그의 기간을 `seasonPack.schedule`에 저장해 오프라인에서도 따르고, 기간 시작·끝에 타이머로 다시 판정합니다. 받기는 기간 중 하나가 지금 ±45일 안일 때만 합니다. 기기에 같은 버전이 있으면(번들 시드든 지난번 받은 것이든) 다시 받지 않고, 새 버전을 설치하면 같은 id의 옛 버전은 지웁니다. 빌드 355 이하 앱은 `schedule`을 모르고 매니페스트 기간을 씁니다. 운영 페이지(`tools/admin-console`)의 「기간 배포」가 카탈로그만 고쳐 올립니다.
- 서버: 기존 Cloudflare Worker 읽기 경로 `GET /public/assets/<key>`가 이미 `Range`(206)·`ETag`·`If-None-Match`(304)·`Accept-Ranges`를 지원합니다(`server/trip-relay/src/public.js`, R2 `range`·`onlyIf`). 서버 코드는 바꾸지 않습니다. 파일은 불변(버전이 키에 있음)이라 `immutable` 캐시, 카탈로그만 짧은 캐시.
- 앱 실행 시 확인: 앱 진입·`scenePhase == .active`에서 카탈로그를 `If-None-Match`로 가볍게 묻고(30분 간격), 새 팩이 있으면 받습니다. **받다 만 팩이 있으면 30분 간격과 상관없이** 저장해 둔 카탈로그로 바로 이어 받습니다.
- 받기(`SeasonPackDownloader` + `SeasonPackBackgroundEngine`): 백그라운드 `URLSession`(앱이 멈춰도 시스템이 이어 받고 앱 델리게이트 `handleEventsForBackgroundURLSession`로 끝을 알림). 끊기면 `resumeData`를 `Application Support/SeasonPacks/.downloads/<id>-<버전>.resume`에, 무엇을 받는 중인지는 `.meta`에, 끝난 파일은 `.bpack`에 둡니다(앱이 죽었다 떠도 이어짐, 백그라운드에서 끝난 파일도 다음 실행이 곧바로 검증). 이어 받기는 `URLSession`이 `Range`·`If-Range`(ETag)로 서버와 맞추고, 서버가 Range를 못 하거나 ETag가 바뀌어 이어 받기가 거절되면 처음부터 한 번 더 받습니다. 카탈로그의 `sha256`·`bytes`가 바뀌면 옛 부분 파일은 버립니다. 셀룰러·저데이터에서는 2MB 넘는 팩을 Wi-Fi로 미루고(작은 팩은 셀룰러 허용), 받기 전에 디스크 여유(팩 크기 3배 + 4MB)를 확인합니다. 진행률·상태(`SeasonPackCenter.downloadStatus`)는 설정 › 내 데이터의 「시즌 팩 업데이트」 줄에 ko/en으로 보입니다.
- 확인·설치: 받은 파일의 크기·SHA-256 확인 → 임시 폴더에서 풀어 팩 검증(자산 해시·한도·창) → 폴더째 원자적 이름 바꾸기. 해시가 틀리면 파일을 버리고 처음부터 한 번 더, 그래도 틀리면 포기. 어느 단계든 실패하면 이전 팩이 그대로 남고 같은 실행에서 되풀이하지 않습니다. 롤백: `SeasonPackStore.discard(id:version:)`로 말썽인 버전을 지우면 이전 버전이 다시 쓰입니다(한 id당 최근 3개 보관).
- 적용: 센터는 설치본과 번들 시드 중 `version`이 높은 쪽을 쓰고(같으면 번들), 받은 팩이 없거나 못 쓰면 번들, 번들도 없으면 이벤트 없음(끔)입니다.

**예전 방식(호환)**: 앱 진입과 `scenePhase == .active`. 인덱스 → 지금과 ±45일 안의 팩 매니페스트 → 파일 → 검증 → 설치. 30분 쿨다운·ETag·8초·한 번 시도·실패는 조용히(공지 `AnnouncementService`와 같은 정책). 요청은 인증·식별자·쿼리·쿠키 없는 `GET` 하나이고 좌표·기기 id·계정을 싣지 않습니다. 저데이터·셀룰러에서는 2MB 넘는 팩을 받지 않습니다(`OfflineVectorNetworkStatus`).
- 저장: `Application Support/SeasonPacks/<packId>/<version>/`(+ `installed.json`), 임시 폴더 → 검증 → 이름 바꾸기. 지우지 않고(다음 해 재사용) 한 id당 최근 3개 버전·전체 32MB를 넘을 때만 오래 안 쓴 것부터 지우되 지금 쓰는 팩은 지우지 않습니다. iCloud 백업 제외. 메모는 `SeasonPacks/memos/<packId>/<itemId>.json`.
- 번들 시드: `Resources/seed/<id>/<version>/`(크리스마스)와 DEBUG 전용 `seed-debug/`(표본 `sample`, 기간 1970-01-01). 같은 매니페스트·같은 해시 규칙이며, 서버 인덱스가 있으면 버전이 높은 쪽, 같으면 번들을 씁니다. R2 배포 전에도 12/19에 크리스마스가 뜹니다.
- 「모든 데이터 삭제」: 팩·메모·시계·시연 기록(`seasonPack.*` 키) 삭제.

## 4. 시계와 날짜 조작 차단

신뢰 시각 = 최근 중계 서버 응답 `Date` + 그 뒤 흐른 단조 시간(재부팅·잠자기에도 흐르는 `CLOCK_MONOTONIC`). 서버 응답이 24시간 넘게 없으면 기기 시각을 쓰되 마지막 신뢰 시각 + 48시간 안일 때만. 기기 시각이 신뢰 시각보다 12시간 넘게 앞서거나 10분 넘게 뒤로 가면 의심으로 보고 서버가 확인할 때까지 이벤트를 **켜지 않습니다**(fail-closed). `-seasonPackDate`·`-seasonPackPreview`는 `#if DEBUG`에서만 컴파일됩니다(Release 오브젝트에 문자열이 없음을 확인).

## 5. 표현·상호작용

- 집 그림: `base`와 `lit` 크로스페이드(일몰~일출), `glow`는 점등 중 고정, 점멸은 `lit` 층 밝기만. 동작 줄이기·저전력에서는 점멸 없이 정지한 `lit` 그림. 트리 터치는 점등 중 그림 위쪽 가운데에서만 받고 나머지 원은 기존 탭(하루 요약)이 받습니다.
- 트리 터치: 빠른 점멸(6초) → 캐럴 → 가사 큐. 재생 중 다시 누르면 점멸·가사만 다시 시작하고 소리는 끝까지. 소리는 한 번에 하나, ambient + mixWithOthers, 화면을 벗어나거나 앱이 뒤로 가면 멈춤. 가사는 저장하지 않는 일회성(스냅숏·백업·AI 기록에 남지 않음).
- 산타: 팩이 처음 켜진 직후 1회 시연(id+version별 `UserDefaults`), 이후 3~5분 간격(FNV 시드로 결정적), 줄이기·저전력에서는 시연도 생략, 산타를 누르면 멈추고 선물 18개가 1.2초간 튀었다 내려옴.
- 악세사리는 의상과 별도 세 칸이며 기간 중 기존 장식을 덮기만 하고(`overridden(by:)`), 팩이 없으면 원래 값이 그대로입니다. 모자는 화랑이 리그가 직접 씌우고(`hatImage`), 의상·목도리·뿔은 PNG 레이어를 앵커(`head`·`body`·`tail`·`feet`)로 얹습니다.

## 6. 이벤트 아이콘 레지스트리(1단계 완료 조건)

`menuIcons[]` 한 항목: `id`·`icon`(자산 id)·`label`·`anchor{dx,dy}`·`priority`·`visibleFrom`/`visibleTo`(`yyyy-MM-ddTHH:mm`)·`menu{title, sections[{title, items[]}]}`. 항목 `kind`: `text`·`memo`(`maxLength`, `readOnlyAfter` 뒤 읽기 전용)·`credits`·`link`(https만)·`toggle`. 위치는 집 아이콘 기준 상대 좌표이고 겹치면 priority 순으로 44pt씩 밀며 화면 밖이면 반대쪽으로 접습니다. 구간 밖이면 뷰를 만들지 않습니다. **앱 코드는 어떤 이벤트인지 모릅니다.** 표본 팩 `sample`(DEBUG 전용)의 항목을 지우면 아이콘이 사라지고 항목을 더하면 붙는 것을 단위 시험(`IconRegistryTests`)이 고정합니다. 현재 아이콘은 집 핀의 화면 좌표를 얻을 수 없어(지도 엔진 셋) 화면 오른쪽 가운데를 기준으로 놓습니다 — `SeasonPackOverlay(homeOrigin:)`가 열려 있어 핀 좌표를 주면 따라갑니다.

## 7. 이벤트 캘린더와 구조가 받아내는 것

| 이벤트 | 받아내는 것 | 시험 |
| --- | --- | --- |
| 크리스마스 12/19~12/30 | 이번에 만든 첫 팩 | 번들 시드·`CenterTests` |
| 새해 12/31~1/1 | 연말 넘김, `sunset`, 분 단위 트리거, 연도 롤링 | `windowCrossingNewYearIsRead`·`SeasonPackYearRoll` |
| 새해 목표 메모 | `menuIcons[]`+`memo`(기간 후 읽기 전용)+말풍선 메모 자리(`bubbles.memoItem`) | `memoIsSavedAndDeletedAndLocksAfterTheDeadline` |
| 설날 2027-02-06~09 | 의상+악세사리 슬롯, 액터 여러 개, 대사 큐, 원본+변조본 소리 두 파일 | `everyFutureEventShapeParsesFromTheManifestAlone` |
| 밸런타인데이 | `interactions[].when.characterID` 분기 | `characterConditionBranchesLikeValentine` |
| 수능 2027-11-18 | `windows[].rule: nthWeekday` | `nthWeekdayRuleParsesToTheRightDay` |
| 식목일 04-05 | `slots.house.stages[]` | `plantingDayStagesPickPictureByTimeOfDay` |
| 부처님오신날 | 음력은 매니페스트에 그해 양력 날짜로 적음(앱은 음력을 계산하지 않음) | — |

## 8. 크리스마스 팩(첫 팩)

12/19 00:00~12/30 23:59, 집=트리(`base`·`lit`·`glow`, 일몰 점등, 전구 1400ms 점멸, 터치 직후 220ms), 연도 글자 칸, 산타 비행·선물 3종, 의상(산타 코트)·악세사리(모자·목도리·루돌프 뿔), 대사 14줄(ko/en), 「크리스마스 안내」 아이콘(priority 10, 소개·음원 출처). 그림과 소리는 `tools/season-pack/generate_season_packs.py`(`season_art.py`·`season_images.py`)가 만듭니다 — Pillow로 4배 그려 줄여 그라데이션·그림자·질감·빛 번짐을 넣은 PNG.

**음원(대표 확인 필요)**: 지시서 후보(Freesound CC0 녹음)는 내려받을 수 없어(외부 내려받기·로그인) 쓰지 않았습니다. 대신 「Jingle Bells」(James Pierpont 1857, 퍼블릭 도메인 멜로디)를 오르골 음색으로 코드 합성해 AAC 96kbps 모노 m4a(약 350KB, 34초)로 넣었고 가사 큐 시각은 합성한 음표에서 계산합니다. 라이선스 표기는 「Public-domain melody; original synthesis」입니다. Freesound CC0 녹음으로 바꾸려면 파일을 `audio/`에 넣고 `assets`·`audio`·`lyrics` 시각만 바꾸면 되며 앱 코드는 그대로입니다(실제 음원 기준 큐 시각 ±150ms 눈 확인 필요).

## 9. 배포 순서 (대표 몫 — 이 요청에서 실행하지 않음)

1. R2 버킷이 있어야 합니다(`R2PUB1119A01`: 버킷 생성·배포·업로드는 대표 몫).
2. 팩 파일을 만듭니다(서버에 올리지 않고 `build/season-pack/`에 만들고 `index.json` 항목을 갱신).
```
python3 scripts/season-pack/build_bpack.py Packages/SeasonPackKit/Sources/SeasonPackKit/Resources/seed/christmas/1 --out build/season-pack
```
3. **팩 파일을 먼저, `index.json`을 마지막에** 올립니다(반쯤 올라간 팩을 앱이 가리키지 않게). `<bucket>`은 R2 버킷 이름입니다(스크립트가 같은 명령을 출력합니다).
```
npx wrangler r2 object put <bucket>/packs/season/christmas/1/christmas-1.bpack --file build/season-pack/christmas-1.bpack --content-type application/octet-stream --cache-control "public, max-age=31536000, immutable" --remote
npx wrangler r2 object put <bucket>/packs/season/index.json --file build/season-pack/index.json --content-type application/json --cache-control "public, max-age=300" --remote
```
4. 크리스마스 공지(`christmas-2026`)를 R2 공지(`announcements/latest.json`)에 올립니다(팩이 켜질 때 기존 공지 시트가 한 번 열림).
5. 번들 시드가 있어 서버가 없어도 12/19에 뜹니다. 서버 팩의 `version`이 시드보다 높을 때만 서버 팩을 씁니다. 같은 팩을 고쳐 올릴 때는 `manifest.json`의 `version`을 올려 새 키로 올립니다(옛 파일은 지우지 않아도 됩니다).
6. 올린 뒤 확인(대표): Range가 되는지 `curl -s -o /dev/null -D - -H "Range: bytes=0-99" https://<서버>/public/assets/packs/season/christmas/1/christmas-1.bpack` 가 `206`과 `Content-Range`를 돌려주는지.

## 10. 다음 단계

새해(종·카운트다운·롤링·메모 팩), 설날(경복궁 집·한복·까치·세배), 밸런타인(캐릭터 분기), 수능, 식목일, 부처님오신날 팩과 에셋. 집 핀 화면 좌표를 세 지도 엔진에서 얻어 아이콘을 핀 옆에 붙이는 일. 장면(자세)별로 의상·목도리·뿔 앵커를 맞추는 일(지금은 모자만 리그가 직접 씌움). 실제 음원(CC0 녹음) 교체와 큐 시각 확인. 팩 문구의 12개 언어 번역(지금은 ko/en).
