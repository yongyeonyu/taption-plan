#!/usr/bin/env python3
"""국내 장소 도감 자료를 만든다(PLB1109A01).

places.tsv(시·도, id, 한글, 영어, 종류, 대략 위도·경도)의 이름을 Wikidata(CC0)에서 찾아
대략 좌표에서 가장 가까운 항목의 좌표를 쓴다. 대조에 실패한 곳은 빼고 보고한다.

사용: build.py [--check-only]   결과: TaptionPlan/UI/MapHomeKoreaPlaceBookData.swift
"""
import json
import math
import pathlib
import shutil
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
OUTPUT = HERE.parents[1] / "TaptionPlan/UI/MapHomeKoreaPlaceBookData.swift"
CACHE = HERE / "wikidata-cache.json"
ICONS = HERE.parents[1] / "TaptionPlan/Assets.xcassets/PlaceBook"
API = "https://www.wikidata.org/w/api.php"
OSM = "https://nominatim.openstreetmap.org/search"
MAX_DISTANCE_M = {"building": 1_500, "area": 3_000, "nature": 12_000, "city": 40_000, "largeIsland": 20_000, "airport": 4_000}
REGIONS = [
    ("seoul", "서울", "Seoul"), ("busan", "부산", "Busan"), ("daegu", "대구", "Daegu"),
    ("incheon", "인천", "Incheon"), ("gwangju", "광주", "Gwangju"), ("daejeon", "대전", "Daejeon"),
    ("ulsan", "울산", "Ulsan"), ("sejong", "세종", "Sejong"), ("gyeonggi", "경기", "Gyeonggi"),
    ("gangwon", "강원", "Gangwon"), ("chungbuk", "충북", "Chungbuk"), ("chungnam", "충남", "Chungnam"),
    ("jeonbuk", "전북", "Jeonbuk"), ("jeonnam", "전남", "Jeonnam"), ("gyeongbuk", "경북", "Gyeongbuk"),
    ("gyeongnam", "경남", "Gyeongnam"), ("jeju", "제주", "Jeju"),
]
THEMES = [
    ("landmark", "명소", "Landmarks"), ("mountain", "산", "Mountains"), ("temple", "사찰", "Temples"),
    ("island", "섬", "Islands"), ("sea", "바다", "Sea"), ("tree", "나무·숲", "Trees & forests"),
    ("drive", "드라이브", "Scenic drives"), ("airport", "공항", "Airports"),
]


def get(params):
    query = urllib.parse.urlencode({**params, "format": "json"})
    request = urllib.request.Request(f"{API}?{query}", headers={"User-Agent": "taption-place-book-build/1.0"})
    for attempt in range(6):
        try:
            time.sleep(1.2)  # 공개 API 부담을 줄인다.
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            if attempt == 5 or error.code not in (429, 500, 502, 503, 504):
                raise
            time.sleep(float(error.headers.get("Retry-After") or 30 * (attempt + 1)))
        except urllib.error.URLError:
            if attempt == 5:
                raise
            time.sleep(10 * (attempt + 1))


def distance(a, b):
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dp, dl = p2 - p1, math.radians(b[1] - a[1])
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * 6_371_000 * math.asin(math.sqrt(h))


def candidates(name, cache):
    if name in cache:
        return cache[name]
    ids = [hit["id"] for hit in get({
        "action": "wbsearchentities", "search": name, "language": "ko", "uselang": "ko", "type": "item", "limit": 20,
    }).get("search", [])]
    found = []
    if ids:
        entities = get({"action": "wbgetentities", "ids": "|".join(ids), "props": "claims"}).get("entities", {})
        for qid in ids:
            for claim in entities.get(qid, {}).get("claims", {}).get("P625", []):
                value = claim["mainsnak"].get("datavalue", {}).get("value")
                if value:
                    found.append([qid, value["latitude"], value["longitude"]])
                    break
    cache[name] = found
    CACHE.write_text(json.dumps(cache, ensure_ascii=False, indent=0), encoding="utf-8")
    return found


def osm_candidates(name, cache):
    """Wikidata에 없는 곳의 2차 대조. Nominatim 사용 기준(초당 1건 이하)을 지킨다."""
    key = f"osm:{name}"
    if key in cache:
        return cache[key]
    query = urllib.parse.urlencode({"q": name, "format": "jsonv2", "countrycodes": "kr", "limit": 10})
    request = urllib.request.Request(f"{OSM}?{query}", headers={"User-Agent": "taption-place-book-build/1.0"})
    time.sleep(1.5)
    with urllib.request.urlopen(request, timeout=30) as response:
        found = [[f"osm:{hit['osm_type']}/{hit['osm_id']}", float(hit["lat"]), float(hit["lon"])] for hit in json.load(response)]
    cache[key] = found
    CACHE.write_text(json.dumps(cache, ensure_ascii=False, indent=0), encoding="utf-8")
    return found


def main():
    rows = [line.split("\t") for line in (HERE / "places.tsv").read_text(encoding="utf-8").splitlines() if line.strip()]
    if len({row[1] for row in rows}) != len(rows):
        raise SystemExit("id 중복")
    cache = json.loads(CACHE.read_text(encoding="utf-8")) if CACHE.exists() else {}
    kept, missed = [], []
    for row in rows:
        region, place_id, korean, english, kind, lat, lon = row[:7]
        approx = (float(lat), float(lon))
        search = [korean, korean.replace(" ", "")] + (row[7].split(",") if len(row) > 7 else [])
        hits = []
        for name in dict.fromkeys(search):
            hits += candidates(name, cache)
        ranked = sorted(((distance(approx, (h[1], h[2])), h) for h in hits), key=lambda item: item[0])
        if not ranked or ranked[0][0] > MAX_DISTANCE_M[kind]:
            for name in dict.fromkeys(search):
                hits += osm_candidates(name, cache)
            ranked = sorted(((distance(approx, (h[1], h[2])), h) for h in hits), key=lambda item: item[0])
        # 이름이 일치한 항목이 20km 안이면 대략 좌표의 오차로 본다(국내만).
        limit = max(MAX_DISTANCE_M[kind], 20_000) if place_id.startswith("kr.") else MAX_DISTANCE_M[kind]
        if ranked and ranked[0][0] <= limit:
            meters, hit = ranked[0]
            kept.append((region, place_id, korean, english, kind, hit[1], hit[2], hit[0], meters))
        else:
            missed.append((region, place_id, korean, int(ranked[0][0]) if ranked else None))
    CACHE.write_text(json.dumps(cache, ensure_ascii=False, indent=0), encoding="utf-8")
    print(f"대조 성공 {len(kept)} / 실패 {len(missed)}")
    for item in missed:
        print("MISS", *item)
    for item in sorted(kept, key=lambda k: -k[8])[:25]:
        print(f"FAR {int(item[8])}m {item[1]} {item[2]} {item[7]}")
    if "--check-only" in sys.argv:
        return
    themes = json.loads((HERE / "themes.json").read_text(encoding="utf-8"))
    airports = dict(line.split() for line in (HERE / "airports.tsv").read_text(encoding="utf-8").splitlines() if line.strip())
    lines = [
        "// scripts/place-book/build.py가 만든 파일입니다. 손으로 고치지 않습니다.",
        "// 좌표 출처: Wikidata(CC0), 일부 OpenStreetMap(ODbL).",
        "",
        "enum MapHomeKoreaPlaceBookData {",
        "    static let regions: [MapHomeKoreaRegion] = [",
    ]
    lines += [f'        .init(id: "{i}", name: "{k}", englishName: "{e}"),' for i, k, e in REGIONS]
    lines += ["    ]", "", "    static let themes: [MapHomeKoreaRegion] = ["]
    lines += [f'        .init(id: "{i}", name: "{k}", englishName: "{e}"),' for i, k, e in THEMES]
    lines += ["    ]", "", "    static let places: [MapHomeKoreaPlace] = ["]
    for region, place_id, korean, english, kind, lat, lon, _, _ in kept:
        safe = english.replace('"', '\\"')
        theme = theme_of(place_id, korean, kind, themes)
        theme_text = f'"{theme}"' if theme else "nil"
        airport_text = ""
        if place_id.startswith("intl."):
            items = []
            for spec in airports[place_id[5:]].split(","):
                iata, name, name_en = (spec.split(":") + ["", ""])[:3]
                found = airport_position(iata, (lat, lon), cache)
                if found:
                    items.append(f'.init(name: "{name}", englishName: "{name_en}", latitude: {found[0]:.5f}, longitude: {found[1]:.5f})')
                else:
                    print("NO AIRPORT", place_id, iata)
            airport_text = f", airports: [{', '.join(items)}]"
        lines.append(
            f'        .init(id: "{place_id}", region: "{region}", name: "{korean}", englishName: "{safe}", '
            f"theme: {theme_text}, kind: .{kind}, latitude: {lat:.5f}, longitude: {lon:.5f}{airport_text}),"
        )
    lines += ["    ]", "}", ""]
    OUTPUT.write_text("\n".join(lines), encoding="utf-8")
    print("wrote", OUTPUT.name)
    write_icons([item[1] for item in kept])
    (HERE / "qids.json").write_text(json.dumps({item[1]: item[7] for item in kept}, ensure_ascii=False, indent=0), encoding="utf-8")


def airport_position(iata, city, cache):
    """IATA 코드(Wikidata P238)로 공항 좌표를 찾아 도시 120km 안일 때만 쓴다."""
    key = f"iata:{iata}"
    if key not in cache:
        hits = get({"action": "query", "list": "search", "srsearch": f"haswbstatement:P238={iata}", "srlimit": 5})
        found = []
        ids = [hit["title"] for hit in hits.get("query", {}).get("search", [])]
        if ids:
            entities = get({"action": "wbgetentities", "ids": "|".join(ids), "props": "claims"}).get("entities", {})
            for qid in ids:
                for claim in entities.get(qid, {}).get("claims", {}).get("P625", []):
                    value = claim["mainsnak"].get("datavalue", {}).get("value")
                    if value:
                        found.append([value["latitude"], value["longitude"]])
                        break
        cache[key] = found
        CACHE.write_text(json.dumps(cache, ensure_ascii=False, indent=0), encoding="utf-8")
    near = [h for h in cache[key] if distance(city, (h[0], h[1])) <= 120_000]
    return near[0] if near else None


def theme_of(place_id, korean, kind, themes):
    for theme, ids in themes.items():
        if place_id in ids:
            return theme
    if not place_id.startswith("kr."):
        return None
    if kind == "nature" and korean.endswith("산"):
        return "mountain"
    if any(word in korean for word in ("해수욕장", "해변", "해안", "곶", "포구")):
        return "sea"
    if any(word in korean for word in ("나무", "숲", "관방제림", "비자림", "죽녹원", "정이품송")):
        return "tree"
    return "landmark"


def write_icons(ids):
    """icons/*.json의 조각을 공통 틀로 감싸 앱 그림 자산으로 쓴다."""
    bodies = {}
    for path in sorted((HERE / "icons").glob("*.json")):
        bodies.update(json.loads(path.read_text(encoding="utf-8")))
    missing = [place_id for place_id in ids if place_id not in bodies]
    if missing:
        raise SystemExit(f"아이콘 없음: {missing}")
    root = ICONS
    if root.exists():
        shutil.rmtree(root)
    root.mkdir(parents=True)
    (root / "Contents.json").write_text('{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n')
    for place_id in ids:
        name = "PlaceBook_" + place_id.replace(".", "_")
        folder = root / f"{name}.imageset"
        folder.mkdir()
        (folder / f"{name}.svg").write_text(svg(bodies[place_id]), encoding="utf-8")
        (folder / "Contents.json").write_text(json.dumps({
            "images": [{"filename": f"{name}.svg", "idiom": "universal"}],
            "info": {"author": "xcode", "version": 1},
            "properties": {"preserves-vector-representation": True},
        }, indent=2) + "\n", encoding="utf-8")
    print("icons", len(ids))


def svg(body):
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="96" height="96" viewBox="0 0 96 96">'
            '<g stroke-linecap="round" stroke-linejoin="round">'
            f'<ellipse cx="48" cy="82" rx="35" ry="6" fill="#A8B483"/>{body}</g></svg>')


if __name__ == "__main__":
    main()
