#!/usr/bin/env python3
"""집 성장 그림 366개를 SVG 이미지 세트로 만든다(HEV1102A01).

1일 씨앗, 366일 롯데월드타워, 그 사이는 catalog.txt 건물을 시대순으로 놓고
영화 건축물을 고르게 끼운다. 그림은 home_evolution/draw_*.py의 함수(이름 = 키)다.
  generate_home_evolution.py            자산·목록·미리보기 생성
  generate_home_evolution.py --list     일자 표만 출력
  generate_home_evolution.py --check    목록·그림 누락과 연속 금지 검사
  generate_home_evolution.py --sheet draw_x 출력.png [칸크기]   한 모듈 그림을 PNG 묶음으로
  generate_home_evolution.py --fit      화면 밖으로 나가는 그림의 축소 배율을 다시 계산
"""
import html, importlib, json, os, pkgutil, sys

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TOOLS)
ASSETS = os.path.join(ROOT, "TaptionPlan/Assets.xcassets")
LIST = os.path.join(ROOT, "docs/HOME_EVOLUTION_LIST.md")
PREVIEW = os.path.join(ROOT, "build/validation/HEV1102A01/home-evolution-366.html")
sys.path.insert(0, TOOLS)
from home_evolution.kit import svg

SEED = dict(key="seed", ko="씨앗", en="Seed", country="-", year=0, family="seed", rights="", era="시작")
FINAL = dict(key="lotte", ko="롯데월드타워", en="Lotte World Tower", country="대한민국", year=2017, family="final", rights="T", era="최종")
ERA_ORDER = ["고대", "중세", "근대", "현대"]


def load_catalog():
    rows, era = [], None
    for line in open(os.path.join(TOOLS, "home_evolution/catalog.txt"), encoding="utf-8"):
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        if line.startswith("@"):
            era = line[1:]
            continue
        key, ko, en, country, year, family, rights = line.split("|")
        rows.append(dict(key=key, ko=ko, en=en, country=country, year=int(year), family=family, rights=rights, era=era))
    return rows


def spread(rows):
    """연도순을 지키되 앞쪽 몇 칸 안에서 같은 계열·같은 나라가 이어지지 않게 고른다."""
    rest = sorted(rows, key=lambda r: r["year"])
    out = []
    while rest:
        prev = out[-1] if out else None
        pick = next((r for r in rest[:8] if not prev or (r["family"] != prev["family"] and r["country"] != prev["country"])), None)
        pick = pick or next((r for r in rest[:8] if r["family"] != prev["family"]), rest[0])
        rest.remove(pick)
        out.append(pick)
    return out


def schedule():
    """366일 순서. 영화는 2~365일 사이에 고르게 끼운다."""
    rows = load_catalog()
    films = sorted((r for r in rows if r["era"] == "영화"), key=lambda r: r["year"])
    main = []
    for era in ERA_ORDER:
        main += spread([r for r in rows if r["era"] == era])
    days = list(main)
    step = (len(main) + len(films)) / (len(films) + 1)
    for i, film in enumerate(films):
        days.insert(round(step * (i + 1)), film)
    return [SEED] + days + [FINAL]


def drawings():
    pkg = importlib.import_module("home_evolution")
    out = {}
    for m in pkgutil.iter_modules(pkg.__path__):
        if m.name.startswith("draw_"):
            out.update(importlib.import_module(f"home_evolution.{m.name}").D)
    return out


RIGHTS = {"F": "영화 IP(저작권·상표)", "T": "상표·이미지 이용 조건 확인", "C": "건축 저작권 존속 가능"}


FIT = os.path.join(TOOLS, "home_evolution/fit.json")


def fits():
    return json.load(open(FIT)) if os.path.exists(FIT) else {}


def art(key, draws, table):
    return svg(draws[key], fit=table.get(key))


def compute_fits(days, draws):
    """건물만 넓은 화면에 그려 실제 범위를 재고, 넘치는 그림의 배율을 정한다."""
    import tempfile
    from render_home_sheet import render
    margin, side, table = 30, 188, {}
    px = 3
    for k in range(0, len(days), 40):
        with tempfile.TemporaryDirectory() as tmp:
            items = []
            for r in days[k:k + 40]:
                path = os.path.join(tmp, r["key"] + ".svg")
                open(path, "w").write(svg(draws[r["key"]], with_ground=False, view=f"{-margin} {-margin} {side} {side}"))
                items.append((r["key"], path))
            for key, img in render(items, side * px).items():
                box = img.convert("L").point(lambda v: 255 if v < 235 else 0).getbbox()
                x0, y0, x1 = box[0] / px - margin, box[1] / px - margin, box[2] / px - margin
                s = min((61 / (64 - x0)) if x0 < 3 else 1, (61 / (x1 - 64)) if x1 > 125 else 1, (102 / (104 - y0)) if y0 < 2 else 1)
                if s < 1:
                    table[key] = round(s - .005, 2)
    json.dump(table, open(FIT, "w"), ensure_ascii=False, indent=0, sort_keys=True)
    print("축소", len(table), table)


def rights_note(r):
    if r["rights"]:
        return RIGHTS[r["rights"]]
    return RIGHTS["C"] if r["year"] >= 1930 else ""


def check(days, draws):
    errs = []
    keys = [r["key"] for r in days]
    if len(keys) != 366:
        errs.append(f"일수 {len(keys)} != 366")
    if len(set(keys)) != len(keys):
        errs.append("중복 키: " + ", ".join(k for k in set(keys) if keys.count(k) > 1))
    for a, b in zip(days, days[1:]):
        if a["family"] == b["family"] and a["family"] != "film":
            errs.append(f"같은 계열 연속: {a['key']}, {b['key']} ({a['family']})")
    miss = [k for k in keys if k not in draws]
    if miss:
        errs.append(f"그림 없음 {len(miss)}개: " + ", ".join(miss[:40]))
    return errs


def write_assets(days, draws):
    contents = lambda name: json.dumps({
        "images": [{"filename": f"{name}.svg", "idiom": "universal", "scale": "1x"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {"preserves-vector-representation": True},
    }, indent=2) + "\n"
    total = 0
    table = fits()
    for i, r in enumerate(days, 1):
        name = f"HomeEvolution{i:03d}"
        folder = os.path.join(ASSETS, f"{name}.imageset")
        os.makedirs(folder, exist_ok=True)
        data = art(r["key"], draws, table)
        total += len(data.encode())
        open(os.path.join(folder, f"{name}.svg"), "w").write(data)
        open(os.path.join(folder, "Contents.json"), "w").write(contents(name))
    return total


def write_list(days):
    lines = ["# 집 성장 366일 건축물 목록", "",
             "`tools/generate_home_evolution.py`가 만든다(HEV1102A01). 권리 칸은 출시 전 법률 확인이 필요한 항목 표시이며 법률 판단이 아니다.", "",
             "| 일 | 건물 | 영문 | 나라 | 시대 | 연도 | 권리 |", "|---|---|---|---|---|---|---|"]
    for i, r in enumerate(days, 1):
        y = "-" if r["key"] == "seed" else (f"기원전 {-r['year']}" if r["year"] < 0 else str(r["year"]))
        lines.append(f"| {i} | {r['ko']} | {r['en']} | {r['country']} | {r['era']} | {y} | {rights_note(r)} |")
    open(LIST, "w", encoding="utf-8").write("\n".join(lines) + "\n")


def write_preview(days, draws):
    table = fits()
    cards = []
    for i, r in enumerate(days, 1):
        if r["key"] not in draws:
            continue
        big = art(r["key"], draws, table)
        cards.append(f'<figure data-era="{r["era"]}"><b>{i}</b>{big}<figcaption>{html.escape(r["ko"])}<small>{html.escape(r["country"])} · {r["era"]}</small></figcaption></figure>')
    os.makedirs(os.path.dirname(PREVIEW), exist_ok=True)
    open(PREVIEW, "w", encoding="utf-8").write(f'''<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1"><title>집 성장 366일</title>
<style>:root{{color-scheme:light}}body{{margin:0;padding:16px;background:#F4EEDF;color:#5A4033;font:14px -apple-system,sans-serif}}h1{{font-size:20px;margin:0 0 12px}}main{{display:grid;grid-template-columns:repeat(auto-fill,minmax(132px,1fr));gap:8px}}figure{{position:relative;margin:0;background:#FDF8EC;border-radius:12px;padding:6px;text-align:center}}figure b{{position:absolute;left:8px;top:6px;font-size:12px}}svg{{width:100%;height:auto;max-width:128px}}figcaption{{font-size:12px;line-height:1.3}}small{{display:block;opacity:.7;font-size:11px}}</style>
<h1>집 성장 366일 ({len(cards)}개)</h1><main>{"".join(cards)}</main>''')


def sheet(module, out, size="170"):
    """한 모듈의 그림을 큰 크기·실제 마커 크기로 묶어 본다. 바이트 수도 출력한다."""
    import tempfile
    from render_home_sheet import render
    from PIL import Image, ImageDraw
    draws = importlib.import_module(f"home_evolution.{module}").D
    size = int(size)
    with tempfile.TemporaryDirectory() as tmp:
        items = []
        for key, fn in draws.items():
            data = svg(fn)
            print(key, len(data.encode()))
            path = os.path.join(tmp, f"{key}.svg")
            open(path, "w").write(data)
            items.append((key, path))
        # qlmanage는 작은 크기에서 그림을 칸의 절반으로 그려, 크게 그린 뒤 줄인다.
        full = render(items, 512)
        big = {k: v.resize((size, size)) if v else None for k, v in full.items()}
        small = {k: v.resize((56, 56)) if v else None for k, v in full.items()}
    cols = 6
    rows = (len(items) + cols - 1) // cols
    img = Image.new("RGB", (cols * (size + 8), rows * (size + 22)), "#FDF8EC")
    dr = ImageDraw.Draw(img)
    for i, (key, _) in enumerate(items):
        x, y = i % cols * (size + 8), i // cols * (size + 22)
        if big[key]:
            img.paste(big[key], (x + 4, y + 2))
        if small[key]:
            img.paste(small[key], (x + size - 54, y + 4))
        dr.text((x + 6, y + size + 4), key, fill="#5A4033")
    img.save(out)


def write_names(days):
    """앱이 집 이름을 보여 줄 수 있게 일자별 이름표를 Swift로 쓴다."""
    def row(text):
        return json.dumps(text, ensure_ascii=False)
    lines = [
        "/// tools/generate_home_evolution.py가 만든다. 직접 고치지 않는다.",
        "enum MapHomeHomeNames {",
        "    /// 1일부터 366일까지 (한국어, 영어).",
        "    static let names: [(korean: String, english: String)] = [",
    ]
    lines += [f"        ({row(r['ko'])}, {row(r['en'])})," for r in days]
    lines += ["    ]", "}", ""]
    path = os.path.join(os.path.dirname(TOOLS), "TaptionPlan/UI/MapHomeHomeNames.swift")
    with open(path, "w", encoding="utf-8") as out:
        out.write("\n".join(lines))


def main():
    if "--sheet" in sys.argv:
        return sheet(*sys.argv[sys.argv.index("--sheet") + 1:])
    days = schedule()
    draws = drawings()
    if "--list" in sys.argv:
        for i, r in enumerate(days, 1):
            print(i, r["key"], r["ko"], r["era"], r["year"], "OK" if r["key"] in draws else "-")
        return
    if "--names" in sys.argv:
        return write_names(days)
    if "--fit" in sys.argv:
        return compute_fits(days, draws)
    errs = check(days, draws)
    for e in errs:
        print("!", e)
    if "--check" in sys.argv:
        sys.exit(1 if errs else 0)
    write_list(days)
    write_names(days)
    write_preview(days, draws)
    if not errs:
        print("SVG 합계 바이트", write_assets(days, draws))


if __name__ == "__main__":
    main()
