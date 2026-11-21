# 도시 팩 (ARCH1120A01 2단계)

설계 정본은 `pickle-bridge/done`(또는 inbox)의 `20261120-1855-trip-assembly-architecture.md`. 이 문서는 **지금 코드에 들어간 것과 다음 단계**만 적는다.

## 들어간 것 (2026-11-21)
- **카드 모델(1단계)**: `TravelTripItem`에 옵셔널 `source`(`alert|pack|ai|manual`)·`packRef`(`TravelPackRef{city,packID,itemID}`)·`externalLink`(https만)·`externalProvider`. 비어 있으면 키를 쓰지 않아 예전 저장본 바이트가 그대로다(마이그레이션 없음, `FlightFareTests`가 고정).
- **시드 형식과 생성기**: `seed/trip/<city>/seed.json` → `python3 scripts/trip-pack/build_trip_pack.py seed/trip/<city> --out build/trip-packs` → `packs/trip/<city>/<version>/{index.json,items.json}`. 검증: 필수 칸(`checkedAt`·`checkedBy`), `checkedBy`는 비식별 표기만(메일·전화 형태 거절), `source`는 `seed`만(API 응답은 시드에 두지 않음), 모르는 칸 거절, 카테고리는 팩이 선언, 좌표 범위, https 링크, 빈 도시는 팩을 만들지 않음. 같은 입력이면 같은 출력(생성 시각은 가장 늦은 확인일). 시험 `scripts/trip-pack/test_build_trip_pack.py`(6건), 가짜 시드 `seed/trip/_fixture/`(시험용, 실제 도시·장소 아님).
- **앱 모델**: `TripPackModels.swift` — `TripPackReader.decode`(모양·스키마·크기 검사, 모르는 카테고리·범위 밖 좌표·겹친 id는 제외), 병원·약국 `isStale`(확인일 90일 초과), 카테고리·문구 거르기, `TripPackPlacement`(팩 항목 → 일정 칸 종류·이름·좌표·`packRef`). 시험 `TripPackTests` 6건.

## 시즌 팩 다운로더 재사용
`SeasonPackDownloader`는 엔진을 주입받고 카탈로그 항목(`SeasonPackIndex.Entry`: id·version·`archive{key,bytes,sha256}`)만 본다. 도시 팩 `index.json`의 `archive`가 같은 모양이라 **항목을 `SeasonPackIndex.Entry`로 옮겨 그대로 부를 수 있다**(이어받기·해시 검증·임시 후 교체 재사용). 해석기만 도시 팩 전용이다. 남은 확인: `SeasonPackLimits.packBytes` 상한이 도시 팩 크기에 맞는지, 저장 폴더를 시즌 팩과 나눌지.

## 다음 단계 (대표 몫이 섞임)
1. 서버: 운영 콘솔(`tools/admin-console`)에 도시 팩 올리기(R2 `packs/trip/…` + 카탈로그 `packs/trip/index.json`)와 시험. **실제 올리기는 대표 몫.**
2. 앱: 팩 카탈로그 받기(`SeasonPackDownloader` 재사용), 도시 팩 목록·후보 화면, 「일정에 넣기」(`TripPackPlacement` → `addTripItem` + `source=pack`·`packRef`).
3. 시드 내용: **사람이 직접 조사한 항목만**(대표 수기 조사). 이 저장소에는 가짜 시드만 있다. API(라쿠텐·핫페퍼)는 키와 표기 조건 원문을 약관에서 읽어 `docs/`에 옮긴 뒤 서버 단계에서만 보강한다.
4. 조립기(설계 5절): 고정점(항공·숙박·예약 이동) 사이 빈 시간에 팩 후보를 결정적으로 배치하는 순수 함수와 시험.
