#!/usr/bin/env python3
"""여행 모드 지구본의 나라 경계와 국내 시·도 경계를 Natural Earth에서 만든다(TVB1112A01).

출처: Natural Earth (https://www.naturalearthdata.com), 공개 도메인. 받는 곳과 판(v5.1.2)은 `build.py`와 같다.
  - ne_50m_admin_0_countries: 나라 242곳(코드는 ISO 3166-1 두 글자, 없으면 Natural Earth 세 글자)
  - ne_10m_admin_1_states_provinces: 그 가운데 대한민국 17개 시·도(코드는 ISO 3166-2, 예: KR-27)
원본은 `--cache` 폴더에 두고 커밋하지 않는다. 같은 입력이면 같은 바이트가 나온다.

형식 `ne-regions.bin`: "TPRG" · 판 u8 · 곳 수 u32 · 곳마다
  (종류 u8(0 나라, 1 시·도) · 코드 · 한국어 이름 · 영어 이름 · 상자 4×i32 · 고리 수 u16 · 고리들).
글자는 길이 u8 + UTF-8, 좌표는 `build.py`와 같은 1e-4도 zigzag varint 차이다.
사용: python3 -I scripts/natural-earth/build_regions.py --cache build/natural-earth-cache
"""
import argparse
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build  # noqa: E402

OUT = os.path.join(build.OUT_DIR, "ne-regions.bin")
KIND_COUNTRY, KIND_PROVINCE = 0, 1
# (줄이는 오차(도), 버리는 면적(제곱도))
COUNTRY_RULE = (0.04, 0.02)
PROVINCE_RULE = (0.0012, 0.0002)


def text(value):
    data = (value or "").encode("utf-8")[:255]
    return bytes([len(data)]) + data


def region(kind, code, ko, en, geometry, rule):
    tolerance, minimum_area = rule
    rings = [[tuple(p[:2]) for p in ring] for ring in build.rings_of(geometry)]
    rings.sort(key=build.area, reverse=True)
    # 가장 큰 고리는 늘 남긴다(작은 섬나라가 사라지지 않게).
    kept = [ring for index, ring in enumerate(rings) if index == 0 or build.area(ring) >= minimum_area]
    parts = []
    for ring in kept:
        encoded, count = build.encode_part(build.simplify(ring, tolerance))
        if encoded and count >= 3:
            parts.append(encoded)
    if not parts:
        return None
    xs = [p[0] for ring in kept for p in ring]
    ys = [p[1] for ring in kept for p in ring]
    box = [int(round(v / build.QUANTUM)) for v in (min(xs), min(ys), max(xs), max(ys))]
    return bytes([kind]) + text(code) + text(ko) + text(en) + struct.pack("<4i", *box) + struct.pack("<H", len(parts)) + b"".join(parts)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache", required=True)
    args = parser.parse_args()
    out = []
    countries = build.fetch("ne_50m_admin_0_countries", args.cache)["features"]
    seen = set()
    for feature in sorted(countries, key=lambda f: f["properties"]["ADM0_A3"]):
        props = feature["properties"]
        code = props.get("ISO_A2_EH") or "-99"
        if code == "-99" or code in seen:
            code = props["ADM0_A3"]
        seen.add(code)
        item = region(KIND_COUNTRY, code, props.get("NAME_KO"), props.get("NAME_EN") or props.get("ADMIN"), feature["geometry"], COUNTRY_RULE)
        if item:
            out.append(item)
    provinces = build.fetch("ne_10m_admin_1_states_provinces", args.cache)["features"]
    korea = [f for f in provinces if f["properties"].get("iso_a2") == "KR"]
    for feature in sorted(korea, key=lambda f: f["properties"]["iso_3166_2"]):
        props = feature["properties"]
        item = region(KIND_PROVINCE, props["iso_3166_2"], props.get("name_ko"), props.get("name"), feature["geometry"], PROVINCE_RULE)
        if item:
            out.append(item)
    data = b"TPRG" + bytes([1]) + struct.pack("<I", len(out)) + b"".join(out)
    with open(OUT, "wb") as handle:
        handle.write(data)
    print(f"{OUT} regions={len(out)} bytes={len(data)}")


if __name__ == "__main__":
    main()
