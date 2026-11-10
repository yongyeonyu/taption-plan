#!/usr/bin/env python3
"""큰 섬 윤곽(VIS1110A02)을 Swift로 만든다.

islands.json은 OpenStreetMap(ODbL) 섬 관계를 Nominatim으로 받아 약 130m 오차로 줄인 것이다.
남해도는 섬 관계가 없어 남해군 경계를 쓴다. 사용: python3 scripts/place-book/islands.py
"""
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE.parents[1] / "TaptionPlan/UI/MapHomeIslandOutlines.swift"

data = json.loads((HERE / "islands.json").read_text(encoding="utf-8"))
lines = [
    "// 생성 파일: scripts/place-book/islands.py. 직접 고치지 않는다.",
    "// 섬 윤곽 © OpenStreetMap 기여자(ODbL).",
    "",
    "/// 큰 섬은 반경 원 대신 실제 윤곽으로 판정한다(원이 육지의 집·회사까지 덮었다, VIS1110A02).",
    "enum MapHomeIslandOutlines {",
    "    static let rings: [String: [Double]] = [",
]
for place_id, item in sorted(data.items()):
    flat = ", ".join(f"{lat}, {lon}" for lat, lon in item["ring"])
    lines.append(f'        // {item["name"]}: {item["source"]}')
    lines.append(f'        "{place_id}": [{flat}],')
lines += ["    ]", "}", ""]
OUT.write_text("\n".join(lines), encoding="utf-8")
print(OUT, sum(len(v["ring"]) for v in data.values()), "points")
