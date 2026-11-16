#!/usr/bin/env python3
"""APS1115A01: App Store 스크린샷 합성.

일레븐랩스로 만든 배경(source/backgrounds) 위에 문구와 실제 앱 화면(시뮬레이터 캡처)을 얹는다.
사용: python3 compose.py <캡처 폴더> <출력 폴더>
"""
import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent
FONTS = ROOT.parent.parent / "TaptionPlan" / "Fonts"
NAVY = (15, 42, 87)
CREAM = (245, 223, 194)
SIZES = {"iphone": (1290, 2796), "duo": (2007, 2853), "ipad": (2064, 2752)}
PANO = ROOT / "source" / "backgrounds" / "bg-pano.jpg"  # 앞 3장이 나눠 쓰는 넓은 배경(검색 결과에 나란히 보임)
ROSE = (199, 109, 134)


def cover(img, size):
    w, h = size
    scale = max(w / img.width, h / img.height)
    img = img.resize((round(img.width * scale), round(img.height * scale)), Image.LANCZOS)
    left, top = (img.width - w) // 2, img.height - h
    return img.crop((left, top, left + w, top + h))


def rounded(img, radius):
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, *img.size), radius, fill=255)
    out = img.convert("RGBA")
    out.putalpha(mask)
    return out


def device(screen, width):
    """앱 화면을 남색 테두리 기기 모양으로 감싼다."""
    scale = width / screen.width
    inner = screen.convert("RGB").resize((width, round(screen.height * scale)), Image.LANCZOS)
    bezel = max(10, width // 46)
    radius = width // 7
    body = Image.new("RGBA", (inner.width + bezel * 2, inner.height + bezel * 2), (0, 0, 0, 0))
    ImageDraw.Draw(body).rounded_rectangle((0, 0, *body.size), radius + bezel, fill=NAVY + (255,))
    body.alpha_composite(rounded(inner, radius), (bezel, bezel))
    return body


def shadow(layer, blur, offset):
    sh = Image.new("RGBA", (layer.width + blur * 4, layer.height + blur * 4), (0, 0, 0, 0))
    alpha = layer.getchannel("A").point(lambda a: a * 0.35)
    sh.paste((40, 10, 30, 255), (blur * 2, blur * 2), alpha)
    return sh.filter(ImageFilter.GaussianBlur(blur)), (offset - blur * 2)


def layout(shot, kind, canvas, ox=0):
    """문구를 쓰고 기기 자리(x, top, phone)를 돌려준다."""
    w, h = SIZES[kind]
    draw = ImageDraw.Draw(canvas)
    unit = w / 1290 if kind == "iphone" else h / 2796
    head = ImageFont.truetype(str(FONTS / "SUIT-ExtraBold.otf"), round(118 * unit))
    sub = ImageFont.truetype(str(FONTS / "SUIT-SemiBold.otf"), round(52 * unit))
    y = round(170 * unit)
    for line in shot["headline"].split("\n"):
        tw = draw.textlength(line, font=head)
        draw.text((ox + (w - tw) / 2, y), line, font=head, fill=NAVY)
        y += round(150 * unit)
    y += round(24 * unit)
    tw = draw.textlength(shot["sub"], font=sub)
    draw.text((ox + (w - tw) / 2, y), shot["sub"], font=sub, fill=(255, 250, 244))
    return y + round(120 * unit), unit


def place(canvas, capture, kind, top, unit, ox=0):
    w, h = SIZES[kind]
    phone_w = round(w * {"iphone": 0.62, "duo": 0.48, "ipad": 0.46}[kind])
    phone = device(Image.open(capture), phone_w)
    x = ox + (w - phone.width) // 2
    sh, delta = shadow(phone, round(30 * unit), round(24 * unit))
    canvas.alpha_composite(sh, (x + delta, top + delta + round(30 * unit)))
    canvas.alpha_composite(phone, (x, top))
    return x, phone


def compose(shot, capture, kind):
    w, h = SIZES[kind]
    canvas = cover(Image.open(ROOT / "source" / "backgrounds" / shot["background"]).convert("RGB"), (w, h)).convert("RGBA")
    top, unit = layout(shot, kind, canvas)
    place(canvas, capture, kind, top, unit)
    return canvas.convert("RGB")


def route(canvas, points, width):
    """세 장을 가로지르는 점선 길(고양이가 걷는 길)."""
    draw = ImageDraw.Draw(canvas)
    dash, gap = width * 3, width * 2
    for (x0, y0), (x1, y1) in zip(points, points[1:]):
        length = ((x1 - x0) ** 2 + (y1 - y0) ** 2) ** 0.5
        t = 0.0
        while t < length:
            a, b = t / length, min(t + dash, length) / length
            draw.line((x0 + (x1 - x0) * a, y0 + (y1 - y0) * a, x0 + (x1 - x0) * b, y0 + (y1 - y0) * b), fill=ROSE + (235,), width=width)
            t += dash + gap
    for x, y in points[1:-1]:
        r = width * 2.2
        draw.ellipse((x - r, y - r, x + r, y + r), fill=(255, 250, 244, 255), outline=ROSE + (255,), width=max(2, width // 2))


def panorama(shots, captures, kind):
    """앞 세 장을 한 장면으로 그리고 잘라 돌려준다."""
    w, h = SIZES[kind]
    canvas = cover(Image.open(PANO).convert("RGB"), (w * 3, h)).convert("RGBA")
    tops = [layout(shot, kind, canvas, ox=i * w) for i, shot in enumerate(shots)]
    unit = tops[0][1]
    ys = [h * f for f in (0.86, 0.70, 0.90, 0.66, 0.88)]
    route(canvas, [(-20, ys[0]), (w * 0.5, ys[1]), (w * 1.5, ys[2]), (w * 2.5, ys[3]), (w * 3 + 20, ys[4])], max(8, round(16 * unit)))
    for i, shot in enumerate(shots):
        place(canvas, captures / shot["capture"], kind, tops[i][0], unit, ox=i * w)
    return [canvas.crop((i * w, 0, (i + 1) * w, h)).convert("RGB") for i in range(3)]


def main():
    captures, out = Path(sys.argv[1]), Path(sys.argv[2])
    shots = json.loads((ROOT / "copy.json").read_text())
    for kind in SIZES:
        (out / kind).mkdir(parents=True, exist_ok=True)
        start = 1
        if PANO.exists() and all((captures / s["capture"]).exists() for s in shots[:3]):
            for n, img in enumerate(panorama(shots[:3], captures, kind), 1):
                img.save(out / kind / f"{n:02d}-{shots[n - 1]['id']}.png", optimize=True)
                print(kind, n, shots[n - 1]["id"], img.size, "pano")
            start = 4
        for n, shot in enumerate(shots, 1):
            if n < start:
                continue
            if not (captures / shot["capture"]).exists():
                print("skip", shot["id"]); continue
            img = compose(shot, captures / shot["capture"], kind)
            img.save(out / kind / f"{n:02d}-{shot['id']}.png", optimize=True)
            print(kind, n, shot["id"], img.size)


if __name__ == "__main__":
    main()
