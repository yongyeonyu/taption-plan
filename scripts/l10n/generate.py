#!/usr/bin/env python3
"""scripts/l10n/translations/*.json으로 4개 제품의 카탈로그를 만든다. 메인 세션만 실행해 충돌을 피한다."""
from __future__ import annotations
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
L10N = ROOT / "scripts/l10n"
TARGETS = ["TaptionPlan", "TaptionPlanWidget", "TaptionPlanWatch", "TaptionPlanWatchWidget"]
LANGUAGES = ["ja", "zh-Hans", "zh-Hant", "de", "fr", "it", "es", "pt-BR", "vi", "id", "th", "hi"]


def unit(value: str) -> dict:
    return {"stringUnit": {"state": "translated", "value": value}}


def dump(path: Path, data: dict) -> None:
    # Xcode가 쓰는 모양과 맞춰 기존 카탈로그의 순서와 공백을 건드리지 않는다.
    text = json.dumps(data, ensure_ascii=False, indent=2, separators=(",", " : "))
    path.write_text(text + "\n", encoding="utf8")


def main() -> None:
    source = json.loads((L10N / "source.json").read_text(encoding="utf8"))
    packs = {}
    for language in LANGUAGES:
        path = L10N / "translations" / f"{language}.json"
        if path.exists():
            packs[language] = json.loads(path.read_text(encoding="utf8"))

    for target in TARGETS:
        strings: dict[str, dict] = {}
        for entry in source["ui"]:
            if target not in entry["targets"]:
                continue
            localizations = {
                language: unit(pack["ui"][entry["key"]])
                for language, pack in packs.items()
                if entry["key"] in pack.get("ui", {})
            }
            if localizations:
                strings[entry["key"]] = {"extractionState": "manual", "localizations": localizations}
        dump(ROOT / target / "UIText.xcstrings", {"sourceLanguage": "ko", "strings": strings, "version": "1.0"})

        for table in ("Localizable", "InfoPlist"):
            path = ROOT / target / f"{table}.xcstrings"
            catalog = json.loads(path.read_text(encoding="utf8"))
            for entry in source["catalog"]:
                if entry["table"] != table or target not in entry["targets"]:
                    continue
                item = catalog["strings"].get(entry["key"])
                if item is None:
                    continue
                for language, pack in packs.items():
                    value = pack.get("catalog", {}).get(f"{table}:{entry['key']}")
                    if value is not None:
                        item.setdefault("localizations", {})[language] = unit(value)
            dump(path, catalog)


if __name__ == "__main__":
    main()
