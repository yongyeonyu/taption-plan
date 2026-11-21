#!/usr/bin/env python3
"""도시 팩 생성(ARCH1120A01 2단계). 사람이 조사한 시드(`seed/trip/<city>/seed.json`)를 검증해 공용 팩으로 만든다.

  python3 scripts/trip-pack/build_trip_pack.py seed/trip/<city> --out build/trip-packs

규칙(설계 4-5): 시드 원본이 팩의 본체이고, `checkedAt`·`checkedBy`는 필수이며 `checkedBy`는 비식별 표기만(메일·전화번호 형태 거절),
라쿠텐·핫페퍼 같은 API 응답은 시드에 두지 않는다(`source`는 `seed`만). 항목이 없는 도시는 팩을 만들지 않는다(빈 팩 배포 금지).
같은 입력이면 같은 출력이 나온다(생성 시각은 시드의 가장 늦은 확인일).
"""
import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

FORMAT_SEED = "bokki-trip-seed"
FORMAT_PACK = "bokki-trip-pack"
SCHEMA = 1
CITY = re.compile(r"^[a-z0-9][a-z0-9-]{1,39}$")
ITEM_ID = re.compile(r"^[a-z0-9][a-z0-9._-]{0,39}$")
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
EMAIL = re.compile(r"[^\s@]+@[^\s@]+")
PHONE_LIKE = re.compile(r"\d{2,4}[-\s]?\d{3,4}[-\s]?\d{4}")
CATEGORY = re.compile(r"^[a-z][a-z_]{1,24}$")
ALLOWED = {
    "id", "category", "name", "nameKo", "area", "address", "lat", "lng", "phone", "hours", "priceHint",
    "tags", "note", "source", "sourceURL", "checkedAt", "checkedBy", "photo",
}
REQUIRED = {"id", "category", "name", "nameKo", "area", "lat", "lng", "note", "source", "checkedAt", "checkedBy"}


class SeedError(Exception):
    pass


def check_item(item, categories, index):
    where = f"items[{index}]"
    if not isinstance(item, dict):
        raise SeedError(f"{where}: 객체가 아닙니다")
    unknown = set(item) - ALLOWED
    if unknown:
        raise SeedError(f"{where}: 허용하지 않는 칸 {sorted(unknown)} (API 응답·스크랩을 그대로 두지 않습니다)")
    missing = REQUIRED - set(item)
    if missing:
        raise SeedError(f"{where}: 필수 칸이 없습니다 {sorted(missing)}")
    if not ITEM_ID.match(str(item["id"])):
        raise SeedError(f"{where}: id 모양이 아닙니다")
    if item["category"] not in categories:
        raise SeedError(f"{where}: 선언하지 않은 카테고리 {item['category']!r}")
    if item["source"] != "seed":
        raise SeedError(f"{where}: source는 seed만 허용합니다(API 보강은 서버 단계에서만)")
    lat, lng = item["lat"], item["lng"]
    if not (isinstance(lat, (int, float)) and isinstance(lng, (int, float)) and -90 <= lat <= 90 and -180 <= lng <= 180):
        raise SeedError(f"{where}: 좌표 범위가 아닙니다")
    if not DATE.match(str(item["checkedAt"])):
        raise SeedError(f"{where}: checkedAt은 YYYY-MM-DD")
    by = str(item["checkedBy"]).strip()
    if not by or EMAIL.search(by) or PHONE_LIKE.search(by):
        raise SeedError(f"{where}: checkedBy는 비식별 표기만(역할·애칭). 메일·전화번호 형태는 안 됩니다")
    for key in ("name", "nameKo", "area", "note"):
        if not str(item[key]).strip():
            raise SeedError(f"{where}: {key}가 비었습니다")
    if len(str(item["note"])) > 120:
        raise SeedError(f"{where}: note는 한 줄(120자 이하)")
    if "tags" in item and not (isinstance(item["tags"], list) and all(isinstance(t, str) and t for t in item["tags"])):
        raise SeedError(f"{where}: tags는 문자열 목록")
    for key in ("sourceURL", "photo"):
        if key in item and not str(item[key]).startswith("https://"):
            raise SeedError(f"{where}: {key}는 https 주소만")
    if "phone" in item and not re.match(r"^[0-9+\-\s()]{5,20}$", str(item["phone"])):
        raise SeedError(f"{where}: phone 모양이 아닙니다(업소·기관 대표번호만)")


def load_seed(path):
    seed = json.loads(Path(path).read_text(encoding="utf-8"))
    if seed.get("format") != FORMAT_SEED or seed.get("schema") != SCHEMA:
        raise SeedError("형식(format·schema)이 맞지 않습니다")
    if not CITY.match(str(seed.get("city", ""))):
        raise SeedError("city 모양이 아닙니다(소문자·숫자·-)")
    if not isinstance(seed.get("version"), int) or seed["version"] < 1:
        raise SeedError("version은 1 이상의 정수")
    categories = seed.get("categories")
    if not (isinstance(categories, list) and categories and all(isinstance(c, str) and CATEGORY.match(c) for c in categories)):
        raise SeedError("categories를 선언해야 합니다(팩이 카테고리를 선언합니다)")
    items = seed.get("items")
    if not isinstance(items, list) or not items:
        raise SeedError("항목이 없는 도시는 팩을 만들지 않습니다(빈 팩 금지)")
    ids = set()
    for index, item in enumerate(items):
        check_item(item, set(categories), index)
        if item["id"] in ids:
            raise SeedError(f"items[{index}]: id가 겹칩니다 {item['id']}")
        ids.add(item["id"])
    return seed


def canonical(obj):
    return json.dumps(obj, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def build(seed_dir, out_root):
    seed = load_seed(Path(seed_dir) / "seed.json")
    items = sorted(seed["items"], key=lambda item: item["id"])
    body = canonical({"format": FORMAT_PACK, "schema": SCHEMA, "city": seed["city"], "version": seed["version"], "items": items})
    index = {
        "format": FORMAT_PACK, "schema": SCHEMA, "city": seed["city"], "version": seed["version"],
        "nameKo": seed.get("nameKo", seed["city"]), "country": seed.get("country"),
        "categories": {c: sum(1 for item in items if item["category"] == c) for c in seed["categories"]},
        "count": len(items), "bytes": len(body), "sha256": hashlib.sha256(body).hexdigest(),
        "generatedAt": max(item["checkedAt"] for item in items),
        "sources": sorted({item["source"] for item in items}),
        "archive": {"key": f"packs/trip/{seed['city']}/{seed['version']}/items.json", "bytes": len(body), "sha256": hashlib.sha256(body).hexdigest()},
    }
    index = {k: v for k, v in index.items() if v is not None}
    target = Path(out_root) / "packs" / "trip" / seed["city"] / str(seed["version"])
    target.mkdir(parents=True, exist_ok=True)
    (target / "items.json").write_bytes(body)
    (target / "index.json").write_bytes(canonical(index) + b"\n")
    return index, target


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("seed_dir")
    parser.add_argument("--out", default="build/trip-packs")
    args = parser.parse_args(argv)
    try:
        index, target = build(args.seed_dir, args.out)
    except SeedError as error:
        print(f"시드 오류: {error}", file=sys.stderr)
        return 2
    print(f"{index['city']} v{index['version']}: 항목 {index['count']}개 · {index['bytes']}바이트 · {target}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
