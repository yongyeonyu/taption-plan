#!/usr/bin/env python3
"""화면 묶음별로 숫자를 직접 쓴 모서리·테두리·글자 크기·간격을 센다(STY1116A01). docs/STYLE_UNIFY.md의 표를 다시 만들 때 쓴다."""
import collections, pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent / "TaptionPlan" / "UI"
GROUPS = [
    ("여행", r"^(Travel|Trip)"), ("홈 지도", r"^MapHome"), ("시간표·편집", r"^(Timeline|Clip|NLE|Plan)"),
    ("가계부", r"^Ledger"), ("AI", r"^Assistant"), ("설정·백업", r"^(Settings|Backup|AppLock|Diagnostics)"),
]
PATTERNS = {
    "corner": re.compile(r"cornerRadius:\s*(\d+(?:\.\d+)?)\b"),
    "cornerToken": re.compile(r"TaptionCorner\.\w+"),
    "radiusToken": re.compile(r"TaptionRadius\.\w+"),
    "line": re.compile(r"lineWidth:\s*(\d+(?:\.\d+)?)\b"),
    "font": re.compile(r"\.(?:system|taption)\(size:\s*(\d+(?:\.\d+)?)\b"),
    "height": re.compile(r"\.frame\((?:[^()]*,\s*)?(?:minHeight|height):\s*(\d+(?:\.\d+)?)\)"),
    "spacing": re.compile(r"\bspacing:\s*(\d+(?:\.\d+)?)\b"),
    "padding": re.compile(r"\.padding\((?:\.\w+,\s*)?(\d+(?:\.\d+)?)\)"),
}

def group(name):
    return next((g for g, p in GROUPS if re.search(p, name)), "그 밖")

def top(counter, n=6):
    return " ".join(f"{k:g}×{v}" for k, v in sorted(counter.items(), key=lambda kv: -kv[1])[:n])

stats = collections.defaultdict(lambda: collections.defaultdict(collections.Counter))
files = collections.Counter()
for path in sorted(ROOT.rglob("*.swift")):
    g = group(path.name)
    files[g] += 1
    text = path.read_text(encoding="utf-8")
    for key, pattern in PATTERNS.items():
        for m in pattern.finditer(text):
            stats[g][key][float(m.group(1)) if m.groups() else m.group(0)] += 1

order = [g for g, _ in GROUPS] + ["그 밖"]
print("| 묶음 | 파일 | 모서리 숫자(곳·값 종류) | 4단계(8·12·16·24) 밖 | 자주 쓴 값 | TaptionCorner | TaptionRadius | 테두리 굵기 | 글자 크기 종류 | 단추·줄 높이 |")
print("|---|---:|---|---:|---|---:|---:|---|---:|---|")
for g in order:
    s = stats[g]
    corner = s["corner"]
    off = sum(v for k, v in corner.items() if k not in (8, 12, 16, 24))
    print(f"| {g} | {files[g]} | {sum(corner.values())}곳·{len(corner)}종 | {off} | {top(corner)} | {sum(s['cornerToken'].values())} | "
          f"{sum(s['radiusToken'].values())} | {top(s['line'], 4)} | {len(s['font'])} | {top(s['height'], 6)} |")
if "--detail" in sys.argv:
    for g in order:
        print(f"\n[{g}] 간격 {top(stats[g]['spacing'], 10)}\n[{g}] 여백 {top(stats[g]['padding'], 10)}\n[{g}] 글자 {top(stats[g]['font'], 12)}\n[{g}] 모서리 {top(stats[g]['corner'], 20)}")
