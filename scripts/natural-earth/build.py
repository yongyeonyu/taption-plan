#!/usr/bin/env python3
"""도시 여행 지도 영상의 바탕 지도와 도시 목록을 Natural Earth에서 만든다(TRV1108A01).

출처: Natural Earth (https://www.naturalearthdata.com), 공개 도메인(public domain).
      "All versions of Natural Earth raster + vector map data found on this website are in the public domain."
      받는 곳은 Natural Earth 공식 저장소의 GeoJSON 묶음을 태그(v5.1.2)로 고정한 주소다:
      https://raw.githubusercontent.com/nvkelso/natural-earth-vector/v5.1.2/geojson/<이름>.geojson

1. 세계(1:110m) 육지·호수·국경선과 동아시아(1:10m, 경도 100~150 · 위도 18~52로 자른 것) 육지·호수·국경선을 받는다.
   받은 원본은 `--cache` 폴더에 두고 다시 받지 않는다. 원본은 커밋하지 않는다.
2. 동아시아는 경계 상자로 자르고(Sutherland–Hodgman), 모두 Douglas–Peucker로 줄이며, 작은 섬·호수는 버린다.
3. 좌표를 1e-4도 정수로 바꿔 앞 점과의 차이를 zigzag varint로 적는다 → `TaptionPlan/MapData/ne-basemap.bin`.
4. 도시 목록(ne_10m_populated_places)에서 영어·한국어 이름·좌표·인구를 뽑는다 → `TaptionPlan/MapData/ne-cities.tsv`.

같은 입력이면 같은 바이트가 나온다. 받은 파일의 SHA-256을 출력해 기록할 수 있게 한다.
사용: python3 -I scripts/natural-earth/build.py --cache build/natural-earth-cache
"""
import argparse
import hashlib
import json
import os
import struct
import sys
import urllib.request

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT_DIR = os.path.join(ROOT, "TaptionPlan", "MapData")
BASE_URL = "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/v5.1.2/geojson/"

# 앱 `TravelMapBaseMap.Region`과 같은 값이어야 한다.
REGION = (100.0, 18.0, 150.0, 52.0)  # 서·남·동·북
QUANTUM = 1e-4

LAYER_LAND, LAYER_LAKE, LAYER_BORDER = 0, 1, 2
SCOPE_WORLD, SCOPE_REGION = 0, 1

# (이름, 층, 범위, 줄이는 오차(도), 버리는 면적(제곱도))
SOURCES = [
    ("ne_110m_land", LAYER_LAND, SCOPE_WORLD, 0.05, 0.5),
    ("ne_110m_lakes", LAYER_LAKE, SCOPE_WORLD, 0.05, 1.0),
    ("ne_110m_admin_0_boundary_lines_land", LAYER_BORDER, SCOPE_WORLD, 0.05, 0),
    ("ne_10m_land", LAYER_LAND, SCOPE_REGION, 0.003, 0.0008),
    ("ne_10m_lakes", LAYER_LAKE, SCOPE_REGION, 0.003, 0.005),
    ("ne_10m_admin_0_boundary_lines_land", LAYER_BORDER, SCOPE_REGION, 0.003, 0),
]
CITIES = "ne_10m_populated_places"
# 한국어 이름 끝의 행정 단위는 영상 글자를 길게 만든다. 남·북한 도시만 뗀다.
KOREAN_SUFFIXES = ("특별자치시", "특별자치도", "특별시", "광역시", "시")


def fetch(name, cache):
    path = os.path.join(cache, name + ".geojson")
    if not os.path.exists(path):
        os.makedirs(cache, exist_ok=True)
        with urllib.request.urlopen(BASE_URL + name + ".geojson", timeout=300) as response:
            data = response.read()
        with open(path, "wb") as handle:
            handle.write(data)
    with open(path, "rb") as handle:
        data = handle.read()
    print(f"{name}.geojson sha256={hashlib.sha256(data).hexdigest()} bytes={len(data)}")
    return json.loads(data)


def rings_of(geometry):
    kind, coords = geometry["type"], geometry["coordinates"]
    if kind == "Polygon":
        return list(coords)
    if kind == "MultiPolygon":
        return [ring for polygon in coords for ring in polygon]
    return []


def lines_of(geometry):
    kind, coords = geometry["type"], geometry["coordinates"]
    if kind == "LineString":
        return [coords]
    if kind == "MultiLineString":
        return list(coords)
    return []


def area(ring):
    total = 0.0
    for (x1, y1), (x2, y2) in zip(ring, ring[1:] + ring[:1]):
        total += x1 * y2 - x2 * y1
    return abs(total) / 2


def clip_ring(ring, box):
    """사각형으로 다각형 고리를 자른다. 잘린 변은 상자 테두리를 따른다."""
    west, south, east, north = box
    edges = [
        (lambda p: p[0] >= west, lambda a, b: cross_x(a, b, west)),
        (lambda p: p[0] <= east, lambda a, b: cross_x(a, b, east)),
        (lambda p: p[1] >= south, lambda a, b: cross_y(a, b, south)),
        (lambda p: p[1] <= north, lambda a, b: cross_y(a, b, north)),
    ]
    points = [tuple(p[:2]) for p in ring]
    for inside, cross in edges:
        if not points:
            break
        result = []
        previous = points[-1]
        for current in points:
            if inside(current):
                if not inside(previous):
                    result.append(cross(previous, current))
                result.append(current)
            elif inside(previous):
                result.append(cross(previous, current))
            previous = current
        points = result
    return points


def cross_x(a, b, x):
    t = (x - a[0]) / (b[0] - a[0])
    return (x, a[1] + t * (b[1] - a[1]))


def cross_y(a, b, y):
    t = (y - a[1]) / (b[1] - a[1])
    return (a[0] + t * (b[0] - a[0]), y)


def clip_line(line, box):
    """상자 밖으로 나가는 곳에서 선을 끊는다. 국경선은 상자 가장자리까지 정확할 필요가 없다."""
    west, south, east, north = box
    pieces, current = [], []
    for point in line:
        if west <= point[0] <= east and south <= point[1] <= north:
            current.append(tuple(point[:2]))
        elif current:
            pieces.append(current)
            current = []
    if current:
        pieces.append(current)
    return [piece for piece in pieces if len(piece) >= 2]


def simplify(points, tolerance):
    if len(points) < 3:
        return points
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        first, last = stack.pop()
        ax, ay = points[first]
        bx, by = points[last]
        dx, dy = bx - ax, by - ay
        length = (dx * dx + dy * dy) ** 0.5
        best, index = -1.0, -1
        for i in range(first + 1, last):
            px, py = points[i]
            if length == 0:
                distance = ((px - ax) ** 2 + (py - ay) ** 2) ** 0.5
            else:
                distance = abs(dy * px - dx * py + bx * ay - by * ax) / length
            if distance > best:
                best, index = distance, i
        if best > tolerance and index > 0:
            keep[index] = True
            stack.append((first, index))
            stack.append((index, last))
    return [p for p, kept in zip(points, keep) if kept]


def zigzag(value):
    return (value << 1) ^ (value >> 63)


def varint(value):
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def encode_part(points):
    quantized = []
    for x, y in points:
        q = (int(round(x / QUANTUM)), int(round(y / QUANTUM)))
        if not quantized or quantized[-1] != q:
            quantized.append(q)
    if len(quantized) < 2:
        return None, 0
    out = bytearray(varint(len(quantized)))
    previous = (0, 0)
    for q in quantized:
        out += varint(zigzag(q[0] - previous[0]))
        out += varint(zigzag(q[1] - previous[1]))
        previous = q
    return bytes(out), len(quantized)


def build_layer(collection, layer, scope, tolerance, minimum_area):
    parts = []
    for feature in collection["features"]:
        geometry = feature.get("geometry")
        if not geometry:
            continue
        if layer == LAYER_BORDER:
            lines = lines_of(geometry)
            if scope == SCOPE_REGION:
                lines = [piece for line in lines for piece in clip_line(line, REGION)]
            for line in lines:
                parts.append(simplify([tuple(p[:2]) for p in line], tolerance))
        else:
            for ring in rings_of(geometry):
                ring = [tuple(p[:2]) for p in ring]
                if scope == SCOPE_REGION:
                    ring = clip_ring(ring, REGION)
                if len(ring) < 3 or area(ring) < minimum_area:
                    continue
                simplified = simplify(ring + [ring[0]], tolerance)
                if len(simplified) >= 4:
                    parts.append(simplified[:-1])
    encoded, points = [], 0
    for part in parts:
        data, count = encode_part(part)
        if data:
            encoded.append(data)
            points += count
    body = struct.pack("<BBI", layer, scope, len(encoded)) + b"".join(encoded)
    return body, len(encoded), points


def korean_name(props):
    name = (props.get("NAME_KO") or "").strip()
    if not name:
        return ""
    if props.get("ADM0_A3") in ("KOR", "PRK"):
        for suffix in KOREAN_SUFFIXES:
            if name.endswith(suffix) and len(name) - len(suffix) >= 2:
                return name[: -len(suffix)]
    return name


def build_cities(collection):
    rows = []
    for feature in collection["features"]:
        props = feature["properties"]
        english = (props.get("NAME_EN") or props.get("NAME") or "").strip()
        if not english:
            continue
        clean = lambda text: text.replace("\t", " ").replace("\n", " ")
        rows.append((
            -int(props.get("POP_MAX") or 0),
            clean(english),
            clean(korean_name(props) or english),
            round(float(props["LATITUDE"]), 4),
            round(float(props["LONGITUDE"]), 4),
            props.get("ISO_A2") or "",
        ))
    rows.sort()
    lines = ["# Natural Earth v5.1.2 ne_10m_populated_places, public domain. en\tko\tlat\tlon\tpop\tiso_a2"]
    for pop, english, korean, lat, lon, iso in rows:
        lines.append(f"{english}\t{korean}\t{lat}\t{lon}\t{-pop}\t{iso}")
    return ("\n".join(lines) + "\n").encode("utf-8"), len(rows)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache", default=os.path.join(ROOT, "build", "natural-earth-cache"))
    parser.add_argument("--out", default=OUT_DIR)
    args = parser.parse_args()

    layers = []
    for name, layer, scope, tolerance, minimum_area in SOURCES:
        body, parts, points = build_layer(fetch(name, args.cache), layer, scope, tolerance, minimum_area)
        print(f"  layer={layer} scope={scope} parts={parts} points={points} bytes={len(body)}")
        layers.append(body)
    region = struct.pack("<4i", *(int(round(v / QUANTUM)) for v in REGION))
    payload = region + struct.pack("<B", len(layers)) + b"".join(layers)
    data = b"TPNE" + struct.pack("<BI", 1, len(payload)) + payload
    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, "ne-basemap.bin"), "wb") as handle:
        handle.write(data)
    cities, count = build_cities(fetch(CITIES, args.cache))
    with open(os.path.join(args.out, "ne-cities.tsv"), "wb") as handle:
        handle.write(cities)
    print(f"ne-basemap.bin bytes={len(data)}")
    print(f"ne-cities.tsv rows={count} bytes={len(cities)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
