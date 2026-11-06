#!/usr/bin/env python3
"""지하철 역과 다음 역 사이의 실제 선로 모양을 OpenStreetMap에서 만든다(SUB1106A02).

1. `TaptionPlan/Core/SubwayCatalog.swift`의 역 목록에서 같은 노선의 이웃 역 쌍을 고른다.
2. Overpass API로 그 둘레의 철도 선로(railway=subway·light_rail·rail·monorail·narrow_gauge)를 받는다.
   받은 원본은 `--cache` 폴더에 두고 다시 받지 않는다.
3. 선로를 그래프로 이어 역 쌍마다 가장 짧은 선로 길을 찾고, 6m 오차로 줄여
   `TaptionPlan/Core/SubwayTrackData.swift`를 쓴다. 길이 직선의 2.2배+500m를 넘으면 버린다(앱은 직선으로 그린다).

선로 모양은 © OpenStreetMap contributors, ODbL 1.0이다. 생성 파일도 같은 조건으로 공개한다.
사용: python3 -I scripts/subway-tracks/build.py --cache build/validation/SUB1106A02/osm
"""
import argparse
import base64
import hashlib
import heapq
import json
import math
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CATALOG = os.path.join(ROOT, "TaptionPlan/Core/SubwayCatalog.swift")
OUTPUT = os.path.join(ROOT, "TaptionPlan/Core/SubwayTrackData.swift")
OVERPASS = "https://overpass-api.de/api/interpreter"
AGENT = "BOKKI-Plan-subway-track-build/1.0"
MAX_PAIR_METERS = 8_000
SNAP_METERS = 500
SIMPLIFY_METERS = 6
PENALTY = {"yard": 4.0, "siding": 3.0, "spur": 2.5}


def meters(a, b):
    lat = math.radians((a[0] + b[0]) / 2)
    dy = (a[0] - b[0]) * 111_320
    dx = (a[1] - b[1]) * 111_320 * math.cos(lat)
    return math.hypot(dx, dy)


def stations():
    text = open(CATALOG, encoding="utf-8").read()
    packed = re.search(r'packedRoutes[^"]*"""?\s*([A-Za-z0-9+/=\s]+?)\s*"""?', text) or re.search(r'packedRoutes[^"]*"([A-Za-z0-9+/=]+)"', text)
    rows = base64.b64decode(re.sub(r"\s", "", packed.group(1))).decode("utf-8").split("\n")
    result = []
    for row in rows:
        fields = row.split("\t")
        if len(fields) == 5 and fields[3] and fields[4]:
            result.append((fields[0], int(fields[1]), fields[2], float(fields[3]), float(fields[4])))
    return result


def pairs(rows):
    by_line = {}
    for row in rows:
        by_line.setdefault(row[0], []).append(row)
    result = set()
    for line_rows in by_line.values():
        # '1호선'·'2호선'처럼 여러 도시가 같은 노선 이름과 순서 번호를 쓴다. 도시별로 먼저 나눈다.
        for city in cities(line_rows):
            city.sort(key=lambda r: r[1])
            for a, b in zip(city, city[1:]):
                pa, pb = (a[3], a[4]), (b[3], b[4])
                if 0 < meters(pa, pb) <= MAX_PAIR_METERS:
                    result.add((pa, pb) if pa <= pb else (pb, pa))
    return sorted(result)


def cities(rows, link_meters=20_000):
    """역끼리 20km 안으로 이어진 무리. 수도권 1호선처럼 길게 뻗어도 역 간격이 짧아 한 무리다."""
    parent = list(range(len(rows)))
    def root(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i
    for i in range(len(rows)):
        for j in range(i + 1, len(rows)):
            if meters((rows[i][3], rows[i][4]), (rows[j][3], rows[j][4])) <= link_meters:
                parent[root(i)] = root(j)
    groups = {}
    for i, row in enumerate(rows):
        groups.setdefault(root(i), []).append(row)
    return list(groups.values())


def cells(pair_list, size=0.1):
    touched = set()
    for a, b in pair_list:
        for lat in (min(a[0], b[0]) - 0.01, max(a[0], b[0]) + 0.01):
            for lon in (min(a[1], b[1]) - 0.01, max(a[1], b[1]) + 0.01):
                touched.add((math.floor(lat / size), math.floor(lon / size)))
        lo = (math.floor(min(a[0], b[0]) / size), math.floor(min(a[1], b[1]) / size))
        hi = (math.floor(max(a[0], b[0]) / size), math.floor(max(a[1], b[1]) / size))
        for i in range(lo[0], hi[0] + 1):
            for j in range(lo[1], hi[1] + 1):
                touched.add((i, j))
    return sorted((i * size, j * size, (i + 1) * size, (j + 1) * size) for i, j in touched)


def fetch(boxes, cache):
    os.makedirs(cache, exist_ok=True)
    elements = []
    for start in range(0, len(boxes), 25):
        parts = "".join(
            f'way["railway"~"^(subway|light_rail|rail|monorail|narrow_gauge)$"]({s:.3f},{w:.3f},{n:.3f},{e:.3f});'
            for s, w, n, e in boxes[start:start + 25]
        )
        query = f"[out:json][timeout:180];({parts});out body;>;out skel qt;"
        # 같은 요청이면 받은 원본을 다시 쓴다. 상자가 바뀌면 새로 받는다.
        path = os.path.join(cache, f"rail-{hashlib.sha256(query.encode()).hexdigest()[:16]}.json")
        if not os.path.exists(path):
            data = urllib.parse.urlencode({"data": query}).encode()
            request = urllib.request.Request(OVERPASS, data=data, headers={"User-Agent": AGENT})
            for attempt in range(5):
                try:
                    with urllib.request.urlopen(request, timeout=240) as response:
                        body = response.read()
                    break
                except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError):
                    if attempt == 4:
                        raise
                    time.sleep(30 * (attempt + 1))
            json.loads(body)
            open(path, "wb").write(body)
            time.sleep(5)
        elements += json.load(open(path, encoding="utf-8"))["elements"]
    return elements


def graph(elements):
    nodes = {e["id"]: (e["lat"], e["lon"]) for e in elements if e["type"] == "node"}
    edges = {}
    for way in (e for e in elements if e["type"] == "way"):
        penalty = PENALTY.get(way.get("tags", {}).get("service"), 1.0)
        ids = [n for n in way["nodes"] if n in nodes]
        for u, v in zip(ids, ids[1:]):
            cost = meters(nodes[u], nodes[v]) * penalty
            edges.setdefault(u, []).append((v, cost))
            edges.setdefault(v, []).append((u, cost))
    grid = {}
    for node in edges:
        lat, lon = nodes[node]
        grid.setdefault((int(lat / 0.004), int(lon / 0.004)), []).append(node)
    return nodes, edges, grid


def near(point, nodes, grid, limit=60):
    cx, cy = int(point[0] / 0.004), int(point[1] / 0.004)
    found = []
    for i in range(cx - 1, cx + 2):
        for j in range(cy - 1, cy + 2):
            for node in grid.get((i, j), []):
                d = meters(point, nodes[node])
                if d <= SNAP_METERS:
                    found.append((d, node))
    return sorted(found)[:limit]


def shortest(a, b, nodes, edges, grid):
    starts, ends = near(a, nodes, grid), dict((n, d) for d, n in near(b, nodes, grid))
    if not starts or not ends:
        return None
    straight = meters(a, b)
    cutoff = straight * 3 + 1_000
    best = {n: d for d, n in starts}
    parent = {}
    heap = [(d, n) for d, n in starts]
    heapq.heapify(heap)
    goal, goal_cost = None, math.inf
    while heap:
        cost, node = heapq.heappop(heap)
        if cost > best.get(node, math.inf) or cost > cutoff or cost >= goal_cost:
            continue
        if node in ends and cost + ends[node] < goal_cost:
            goal, goal_cost = node, cost + ends[node]
        for nxt, step in edges.get(node, []):
            value = cost + step
            if value < best.get(nxt, math.inf):
                best[nxt] = value
                parent[nxt] = node
                heapq.heappush(heap, (value, nxt))
    if goal is None:
        return None
    chain = [goal]
    while chain[-1] in parent:
        chain.append(parent[chain[-1]])
    points = [a] + [nodes[n] for n in reversed(chain)] + [b]
    length = sum(meters(p, q) for p, q in zip(points, points[1:]))
    return points if length <= straight * 2.2 + 500 else None


def simplify(points, tolerance=SIMPLIFY_METERS):
    if len(points) < 3:
        return points
    def offset(p, a, b):
        ax, ay = 0.0, 0.0
        bx, by = (b[1] - a[1]) * 111_320 * math.cos(math.radians(a[0])), (b[0] - a[0]) * 111_320
        px, py = (p[1] - a[1]) * 111_320 * math.cos(math.radians(a[0])), (p[0] - a[0]) * 111_320
        length = math.hypot(bx, by)
        if length == 0:
            return math.hypot(px, py)
        return abs(bx * py - by * px) / length
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        i, j = stack.pop()
        far, index = 0.0, None
        for k in range(i + 1, j):
            d = offset(points[k], points[i], points[j])
            if d > far:
                far, index = d, k
        if index is not None and far > tolerance:
            keep[index] = True
            stack += [(i, index), (index, j)]
    return [p for p, k in zip(points, keep) if k]


def quantize(value):
    return int(math.floor(value * 100_000 + 0.5))


def encode(points):
    out, last = [], (0, 0)
    for lat, lon in points:
        q = (quantize(lat), quantize(lon))
        for delta in (q[0] - last[0], q[1] - last[1]):
            value = ~(delta << 1) if delta < 0 else delta << 1
            while value >= 0x20:
                out.append(chr((0x20 | (value & 0x1F)) + 63))
                value >>= 5
            out.append(chr(value + 63))
        last = q
    return "".join(out)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache", required=True)
    args = parser.parse_args()
    rows = stations()
    pair_list = pairs(rows)
    nodes, edges, grid = graph(fetch(cells(pair_list), args.cache))
    lines, missing = [], 0
    for a, b in pair_list:
        path = shortest(a, b, nodes, edges, grid)
        if path is None:
            missing += 1
            continue
        key = f"{quantize(a[0])},{quantize(a[1])},{quantize(b[0])},{quantize(b[1])}"
        lines.append(f"{key}\t{encode(simplify(path))}")
    body = "\n".join(lines)
    header = (
        "// 생성 파일: scripts/subway-tracks/build.py. 손으로 고치지 않는다.\n"
        "// 지하철 선로 모양 © OpenStreetMap contributors, ODbL 1.0 (https://www.openstreetmap.org/copyright).\n"
        "// 한 줄은 '앞 역 위도,경도,뒤 역 위도,경도(1e-5 정수)<TAB>Google polyline(1e-5)'이다.\n"
    )
    swift = header + "enum SubwayTrackData {\n    static let packed = #\"\"\"\n" + body + "\n\"\"\"#\n}\n"
    open(OUTPUT, "w", encoding="utf-8").write(swift)
    print(f"역 쌍 {len(pair_list)}, 선로 {len(lines)}, 못 찾음 {missing}, 크기 {len(swift.encode()) // 1024}KB", file=sys.stderr)


if __name__ == "__main__":
    main()
