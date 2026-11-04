#!/usr/bin/env python3
"""Swift 소스와 기존 카탈로그에서 번역 대상을 모아 scripts/l10n/source.json을 만든다."""
from __future__ import annotations
import json, re, subprocess, sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from swift_scan import Literal, calls_in, line_of, read_literal, skip_trivia

ROOT = Path(__file__).resolve().parents[2]
HANGUL = re.compile(r"[가-힣]")
TARGETS = {
    "TaptionPlan": "TaptionPlan",
    "TaptionPlanWidget": "TaptionPlanWidget",
    "TaptionPlanWatch": "TaptionPlanWatch",
    "TaptionPlanWatchWidget": "TaptionPlanWatchWidget",
}
# 영어만 코드에 있고 화면에서 번역 조회를 거치는 표: 파일 이름, 정의 이름.
EN_TABLES = [
    ("TaptionPlan/UI/MapHomeTimeSidebar.swift", "localizedTitle"),
    ("TaptionPlan/UI/MapHomeTimeSidebar.swift", "english"),
    ("TaptionPlan/UI/MapHomeGrowthSheet.swift", "countryName"),
    ("TaptionPlan/UI/MapHomeGrowthSheet.swift", "categoryName"),
    ("TaptionPlan/UI/MapHomeFogLayer.swift", "englishLabel"),
    ("TaptionPlan/UI/MapHomeSupportViews.swift", "englishTitle"),
    ("TaptionPlan/UI/MapHomeSupportViews.swift", "summaryEnglishTitle"),
    ("TaptionPlan/UI/MapHomeLocationPresentation.swift", "englishName"),
    ("TaptionPlan/UI/MapHomeLanguage.swift", "englishTitle"),
    ("TaptionPlan/Core/MovementModels.swift", "englishTitle"),
    ("TaptionPlan/Core/PlaceModels.swift", "englishTitle"),
    ("TaptionPlan/Core/WidgetShared.swift", "englishTitle"),
    ("TaptionPlan/Core/FloorModels.swift", "english"),
]
# 표로 쓴 "한글", "English" 짝을 그대로 읽는 파일.
PAIR_TABLE_FILES = ["TaptionPlan/UI/FirstRunTutorialGuides.swift", "TaptionPlan/UI/StickerArtBasics.swift", "TaptionPlan/Core/PlaceModels.swift"]
CALL_NAMES = {"text", "t", "runtimeText"}
LABEL_PAIR = re.compile(r"(?:korean\w*|ko|koreanName|koreanTitle|name|title)\s*:\s*\"")
ENGLISH_LABEL = re.compile(r"\s*,\s*(?:english\w*|en)\s*:\s*\"")


def tracked_swift() -> list[str]:
    out = subprocess.check_output(["git", "ls-files", "*.swift"], cwd=ROOT).decode().splitlines()
    skip = ("TaptionPlanTests", "TaptionPlanUITests", "tools/", "scripts/", "server/", "design/", "artifacts/")
    return [f for f in out if "/Tests/" not in f and not f.startswith(skip)]


def target_files(names: list[str]) -> dict[str, set[str]]:
    """프로젝트의 Sources 단계를 읽어 target마다 컴파일되는 파일 이름을 돌려준다."""
    pbx = (ROOT / "TaptionPlan.xcodeproj/project.pbxproj").read_text(encoding="utf8")
    phases = dict(re.findall(r"(\w+) /\* Sources \*/ = \{\s*isa = PBXSourcesBuildPhase;.*?files = \((.*?)\);", pbx, re.S))
    result = {}
    for name in names:
        m = re.search(r"/\* %s \*/ = \{\s*isa = PBXNativeTarget;.*?buildPhases = \((.*?)\);" % re.escape(name), pbx, re.S)
        files: set[str] = set()
        for phase_id in re.findall(r"(\w+) /\* Sources \*/", m.group(1)):
            files |= set(re.findall(r"/\* ([^*]+\.swift) in Sources \*/", phases[phase_id]))
        result[name] = files
    return result


def table_literals(src: str, definition: str) -> list[str]:
    """`var/func/let 이름`의 본문에서 한글 없는 리터럴을 모은다."""
    found = []
    for m in re.finditer(r"\b(?:var|func|let)\s+%s\b" % re.escape(definition), src):
        i = m.end()
        opener = re.compile(r"[{\[]").search(src, i)
        if not opener:
            continue
        depth, j = 0, opener.start()
        while j < len(src):
            j2 = skip_trivia(src, j)
            if j2 != j:
                j = j2
                continue
            c = src[j]
            if c == '"':
                lit = read_literal(src, j)
                is_key_value = src[lit.end:lit.end + 1] != ":"
                pattern_case = src[max(0, j - 5):j].strip().endswith("case")
                if is_key_value and not pattern_case and not HANGUL.search(lit.template) and lit.template.strip():
                    found.append(lit.template)
                j = lit.end
                continue
            depth += c in "{["
            depth -= c in "}]"
            j += 1
            if depth == 0:
                break
    return found


def ternary_literals(raw: str) -> list[Literal]:
    out, i = [], 0
    while i < len(raw):
        j = skip_trivia(raw, i)
        if j != i:
            i = j
            continue
        if raw[i] == '"':
            lit = read_literal(raw, i)
            out.append(lit)
            i = lit.end
            continue
        i += 1
    return out


def collect() -> tuple[dict, list]:
    entries: dict[str, dict] = {}
    unread = []
    uses: dict[str, set[str]] = defaultdict(set)

    def add(key, ko, en, f, line, exprs=None):
        e = entries.setdefault(key, {"key": key, "ko": ko, "en": en, "files": [], "args": exprs or []})
        where = f"{Path(f).name}:{line}"
        if len(e["files"]) < 3:
            e["files"].append(where)
        uses[key].add(f)

    for f in tracked_swift():
        src = (ROOT / f).read_text(encoding="utf8")
        for c in calls_in(src, CALL_NAMES):
            if c.name not in CALL_NAMES:
                continue
            line = line_of(src, c.offset)
            if c.ko and c.en:
                if HANGUL.search(c.ko.template) or HANGUL.search(c.en.template) or c.ko.template != c.en.template:
                    add(f"{c.ko.template}|{c.en.template}", c.ko.template, c.en.template, f, line, c.en.expressions)
                continue
            ko, en = ternary_literals(c.raw[0]), ternary_literals(c.raw[1])
            if ko and len(ko) == len(en) and "+" not in c.raw[0]:
                for a, b in zip(ko, en):
                    add(f"{a.template}|{b.template}", a.template, b.template, f, line, b.expressions)
            else:
                unread.append({"file": f, "line": line, "ko": c.raw[0][:90], "en": c.raw[1][:90]})
        for m in LABEL_PAIR.finditer(src):
            a = read_literal(src, m.end() - 1)
            n = ENGLISH_LABEL.match(src, a.end)
            if not n or not HANGUL.search(a.template):
                continue
            b = read_literal(src, n.end() - 1)
            add(f"|{b.template}", a.template, b.template, f, line_of(src, m.start()), b.expressions)
    for f in PAIR_TABLE_FILES:
        src = (ROOT / f).read_text(encoding="utf8")
        previous, i = None, 0
        while i < len(src):
            j = skip_trivia(src, i)
            if j != i:
                i = j
                continue
            if src[i] == '"':
                lit = read_literal(src, i)
                if (previous and HANGUL.search(previous.template) and not HANGUL.search(lit.template)
                        and src[previous.end:i].strip() == "," and re.search("[A-Za-z]{2}", lit.template)):
                    add(f"{previous.template}|{lit.template}", previous.template, lit.template, f, line_of(src, i))
                previous, i = lit, lit.end
                continue
            if src[i] not in ", \n\t":
                previous = None
            i += 1
    for f, definition in EN_TABLES:
        src = (ROOT / f).read_text(encoding="utf8")
        for text in table_literals(src, definition):
            add(f"|{text}", "", text, f, 0)
    src = (ROOT / "Packages/TaptionWatchSync/Sources/TaptionWatchSync").glob("*.swift")
    for path in src:
        rel = str(path.relative_to(ROOT))
        text = path.read_text(encoding="utf8")
        for m in re.finditer(r'UITextPack\.translate\(english: "', text):
            lit = read_literal(text, m.end() - 1)
            add(f"|{lit.template}", "", lit.template, rel, line_of(text, m.start()))
    names = (ROOT / "TaptionPlan/UI/MapHomeHomeNames.swift").read_text(encoding="utf8")
    for ko, en in re.findall(r'\("((?:[^"\\]|\\.)*)",\s*"((?:[^"\\]|\\.)*)"\)', names):
        add(f"|{en}", ko, en, "TaptionPlan/UI/MapHomeHomeNames.swift", 0)
    return entries, unread, uses


def catalogs() -> dict[str, dict]:
    result: dict[str, dict] = {}
    for target in TARGETS.values():
        for table in ("Localizable", "InfoPlist"):
            data = json.loads((ROOT / target / f"{table}.xcstrings").read_text(encoding="utf8"))
            for key, value in data["strings"].items():
                if value.get("extractionState") == "stale" or not key.strip():
                    continue
                en = value.get("localizations", {}).get("en", {}).get("stringUnit", {}).get("value")
                if en is None or not re.search(r"[A-Za-z가-힣]", en + key):
                    continue
                if table == "InfoPlist" and key in ("CFBundleName", "CFBundleDisplayName"):
                    continue
                result.setdefault(f"{table}:{key}", {"table": table, "key": key, "en": en, "targets": []})["targets"].append(target)
    return result


def main():
    entries, unread, uses = collect()
    files_by_target = target_files(list(TARGETS))
    pkg = "Packages/"
    for key, e in entries.items():
        targets = []
        for target, files in files_by_target.items():
            if any(u.startswith(pkg) or Path(u).name in files for u in uses[key]):
                targets.append(target)
        e["targets"] = targets or ["TaptionPlan"]
    source = {
        "ui": sorted(entries.values(), key=lambda e: e["key"]),
        "catalog": sorted(catalogs().values(), key=lambda e: (e["table"], e["key"])),
    }
    out = ROOT / "scripts/l10n/source.json"
    out.write_text(json.dumps(source, ensure_ascii=False, indent=1) + "\n", encoding="utf8")
    report = {"ui": len(source["ui"]), "catalog": len(source["catalog"]), "unread": unread}
    (ROOT / "scripts/l10n/unread-report.json").write_text(json.dumps(report, ensure_ascii=False, indent=1) + "\n", encoding="utf8")
    words = sum(len(e["en"].split()) for e in source["ui"] + source["catalog"])
    print(f"ui {len(source['ui'])}, catalog {len(source['catalog'])}, 영어 단어 {words}, 읽지 못한 호출 {len(unread)}")


if __name__ == "__main__":
    main()
