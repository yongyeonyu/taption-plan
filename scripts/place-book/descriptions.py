#!/usr/bin/env python3
"""장소 설명(PBD1111A01) descriptions.json → MapHomePlaceBookDescriptions.swift.

descriptions.json은 {"장소 id": {"ko": "...", "en": "..."}}. 모든 도감 장소에 설명이 있어야 하고,
없으면 종료 코드 1이다. 사용: descriptions.py
"""
import json
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
DATA = ROOT / "TaptionPlan/UI/MapHomeKoreaPlaceBookData.swift"
OUTPUT = ROOT / "TaptionPlan/UI/MapHomePlaceBookDescriptions.swift"


def literal(text):
    return text.replace("\\", "\\\\").replace('"', '\\"')


def main():
    descriptions = json.loads((HERE / "descriptions.json").read_text(encoding="utf-8"))
    ids = re.findall(r'\.init\(id: "([^"]+)", region:', DATA.read_text(encoding="utf-8"))
    missing = [i for i in ids if i not in descriptions]
    extra = [i for i in descriptions if i not in set(ids)]
    if missing or extra:
        print("누락", missing[:10], len(missing), "여분", extra[:10], len(extra))
        sys.exit(1)
    lines = [
        "// scripts/place-book/descriptions.py가 descriptions.json으로 만든 파일입니다. 손으로 고치지 않습니다.",
        "",
        "enum MapHomePlaceBookDescriptions {",
        "    struct Item {",
        "        let id: String",
        "        let ko: String",
        "        let english: String",
        "    }",
        "",
        "    static let items: [Item] = [",
    ]
    for place_id in ids:
        d = descriptions[place_id]
        lines.append(f'        .init(id: "{place_id}", ko: "{literal(d["ko"])}", english: "{literal(d["en"])}"),')
    lines += [
        "    ]",
        "",
        "    private static let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })",
        "",
        "    /// 앱 언어의 설명. 장소에 설명이 없으면 빈 글이라 화면에 아무것도 그리지 않는다.",
        "    static func text(for id: String, language: MapHomeLanguage) -> String {",
        "        byID[id].map { language.runtimeText($0.ko, $0.english) } ?? \"\"",
        "    }",
        "}",
        "",
    ]
    OUTPUT.write_text("\n".join(lines), encoding="utf-8")
    print("wrote", OUTPUT.name, len(ids))


if __name__ == "__main__":
    main()
