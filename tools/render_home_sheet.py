#!/usr/bin/env python3
"""SVG 그림들을 PNG 묶음으로 보여 준다(HEV1102A01). qlmanage로 그려 PIL로 붙인다.
사용: render_home_sheet.py 출력.png 칸수 칸크기 이름=파일.svg ..."""
import os, re, subprocess, sys, tempfile
from PIL import Image, ImageDraw

def render(paths, size):
    out = {}
    with tempfile.TemporaryDirectory() as tmp:
        batch = []
        for i, (name, path) in enumerate(paths):
            big = os.path.join(tmp, f"{i:04d}.svg")
            s = re.sub(r'width="\d+" height="\d+"', f'width="{size}" height="{size}"', open(path).read(), count=1)
            open(big, "w").write(s)
            batch.append(big)
        for k in range(0, len(batch), 40):
            subprocess.run(["qlmanage", "-t", "-s", str(size), "-o", tmp, *batch[k:k + 40]],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for i, (name, _) in enumerate(paths):
            p = os.path.join(tmp, f"{i:04d}.svg.png")
            out[name] = Image.open(p).convert("RGB").copy() if os.path.exists(p) else None
    return out

def main():
    out, cols, size = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    items = [a.split("=", 1) for a in sys.argv[4:]]
    imgs = render(items, size)
    rows = (len(items) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * (size + 8), rows * (size + 22)), "#FDF8EC")
    dr = ImageDraw.Draw(sheet)
    for i, (name, _) in enumerate(items):
        x, y = i % cols * (size + 8), i // cols * (size + 22)
        if imgs[name]:
            sheet.paste(imgs[name], (x + 4, y + 2))
        dr.text((x + 6, y + size + 4), name[:max(8, size // 6)], fill="#5A4033")
    sheet.save(out)

if __name__ == "__main__":
    main()
