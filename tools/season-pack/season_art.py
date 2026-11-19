"""시즌 팩 그림 그리기 도구 (SEA1119A01).

Pillow + numpy로 그라데이션·부드러운 그림자·빛 번짐·질감을 쓴 PNG를 만든다. 4배 크기로 그린 뒤 줄여 가장자리를 매끄럽게 한다.
`generate_season_packs.py`가 이 모듈의 함수로 팩 그림을 만든다. 같은 입력이면 같은 그림이 나온다(난수는 고정 시드).
"""
import math
import random

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

SS = 4


class Art:
    """논리 좌표(w×h)로 그리는 캔버스. 칠은 색 튜플이거나 그라데이션 명세다.

    그라데이션: ("v", c0, c1, y0, y1) 세로, ("h", c0, c1, x0, x1) 가로, ("r", cx, cy, r, c_in, c_out) 원형.
    """

    def __init__(self, w, h):
        self.w, self.h = w, h
        self.im = Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))

    # -- 기본 ---------------------------------------------------------------------------------
    def _s(self, v):
        return v * SS

    def _mask(self, draw_fn):
        mask = Image.new("L", self.im.size, 0)
        draw_fn(ImageDraw.Draw(mask))
        return mask

    def _paint(self, fill):
        if isinstance(fill[0], str):
            kind = fill[0]
            yy, xx = np.mgrid[0 : self.im.size[1], 0 : self.im.size[0]].astype(np.float32)
            if kind == "v":
                _, c0, c1, a, b = fill
                t = np.clip((yy / SS - a) / max(b - a, 1e-6), 0, 1)
            elif kind == "h":
                _, c0, c1, a, b = fill
                t = np.clip((xx / SS - a) / max(b - a, 1e-6), 0, 1)
            else:
                _, cx, cy, r, c0, c1 = fill
                t = np.clip(np.hypot(xx / SS - cx, yy / SS - cy) / max(r, 1e-6), 0, 1)
            c0 = np.array(c0 if len(c0) == 4 else (*c0, 255), np.float32)
            c1 = np.array(c1 if len(c1) == 4 else (*c1, 255), np.float32)
            arr = c0[None, None, :] * (1 - t[..., None]) + c1[None, None, :] * t[..., None]
            return Image.fromarray(arr.astype(np.uint8), "RGBA")
        color = fill if len(fill) == 4 else (*fill, 255)
        return Image.new("RGBA", self.im.size, color)

    def _put(self, fill, mask, alpha=1.0):
        layer = self._paint(fill)
        if alpha < 1.0:
            mask = mask.point(lambda v: int(v * alpha))
        a = np.minimum(np.array(layer.split()[3], np.float32), np.array(mask, np.float32))
        layer.putalpha(Image.fromarray(a.astype(np.uint8), "L"))
        self.im = Image.alpha_composite(self.im, layer)

    def poly(self, pts, fill, alpha=1.0):
        self._put(fill, self._mask(lambda d: d.polygon([(self._s(x), self._s(y)) for x, y in pts], fill=255)), alpha)

    def ellipse(self, box, fill, alpha=1.0):
        self._put(fill, self._mask(lambda d: d.ellipse([self._s(v) for v in box], fill=255)), alpha)

    def rrect(self, box, fill, radius=8, alpha=1.0):
        self._put(fill, self._mask(lambda d: d.rounded_rectangle([self._s(v) for v in box], radius=self._s(radius), fill=255)), alpha)

    def stroke(self, pts, fill, width, alpha=1.0, round_ends=True):
        def fn(d):
            p = [(self._s(x), self._s(y)) for x, y in pts]
            d.line(p, fill=255, width=max(1, int(round(self._s(width)))), joint="curve")
            if round_ends:
                r = self._s(width) / 2
                for x, y in (p[0], p[-1]):
                    d.ellipse([x - r, y - r, x + r, y + r], fill=255)

        self._put(fill, self._mask(fn), alpha)

    # -- 효과 ---------------------------------------------------------------------------------
    def glow(self, cx, cy, r, color, strength=1.0, blur=None):
        """부드러운 빛 번짐."""
        layer = Image.new("RGBA", self.im.size, (0, 0, 0, 0))
        d = ImageDraw.Draw(layer)
        d.ellipse([self._s(cx - r), self._s(cy - r), self._s(cx + r), self._s(cy + r)], fill=(*color[:3], int(255 * strength)))
        layer = layer.filter(ImageFilter.GaussianBlur(self._s(blur if blur is not None else r * 0.55)))
        self.im = Image.alpha_composite(self.im, layer)

    def shadow(self, shape_fn, color=(20, 40, 80), alpha=0.28, blur=6, dx=0, dy=4):
        """그린 모양 아래에 부드러운 그림자. `shape_fn(draw, s)`로 모양을 준다."""
        mask = self._mask(lambda d: shape_fn(d, self._s))
        mask = mask.filter(ImageFilter.GaussianBlur(self._s(blur)))
        shifted = Image.new("L", self.im.size, 0)
        shifted.paste(mask, (self._s(dx), self._s(dy)))
        layer = Image.new("RGBA", self.im.size, (*color, 255))
        layer.putalpha(shifted.point(lambda v: int(v * alpha)))
        self.im = Image.alpha_composite(self.im, layer)

    def texture(self, mask_fn, strokes, seed, light, dark, length=(5, 11), width=1.3, alpha=0.55):
        """영역 안에 짧은 솔잎·털결 선을 흩뿌린다."""
        mask = self._mask(mask_fn)
        rng = random.Random(seed)
        layer = Image.new("RGBA", self.im.size, (0, 0, 0, 0))
        d = ImageDraw.Draw(layer)
        bbox = mask.getbbox()
        if not bbox:
            return
        for _ in range(strokes):
            x = rng.uniform(bbox[0], bbox[2]) / SS
            y = rng.uniform(bbox[1], bbox[3]) / SS
            ang = rng.uniform(math.radians(55), math.radians(125))
            ln = rng.uniform(*length)
            color = light if rng.random() < 0.5 else dark
            d.line([(self._s(x), self._s(y)), (self._s(x + ln * math.cos(ang)), self._s(y + ln * math.sin(ang)))],
                   fill=(*color, int(255 * alpha)), width=max(1, int(round(self._s(width)))))
        a = np.minimum(np.array(layer.split()[3], np.float32), np.array(mask, np.float32))
        layer.putalpha(Image.fromarray(a.astype(np.uint8), "L"))
        self.im = Image.alpha_composite(self.im, layer)

    def out(self, size=None):
        w, h = size or (self.w, self.h)
        return self.im.resize((w, h), Image.LANCZOS)


# ---- 공용 도형 -------------------------------------------------------------------------------
def star_points(cx, cy, r, inner=0.5, rotate=-math.pi / 2):
    return [(cx + (r if i % 2 == 0 else r * inner) * math.cos(rotate + i * math.pi / 5),
             cy + (r if i % 2 == 0 else r * inner) * math.sin(rotate + i * math.pi / 5)) for i in range(10)]


def rounded_star(art, cx, cy, r, c_light, c_dark, outline=None):
    pts = star_points(cx, cy, r, 0.52)
    # 모서리를 둥글게: 꼭짓점 둘레에 작은 원을 겹친다.
    if outline:
        art.poly(star_points(cx, cy, r * 1.08, 0.52), outline)
    art.poly(pts, ("v", c_light, c_dark, cy - r, cy + r))
    for i in range(0, 10, 2):
        art.ellipse((pts[i][0] - r * 0.1, pts[i][1] - r * 0.1, pts[i][0] + r * 0.1, pts[i][1] + r * 0.1), ("v", c_light, c_dark, cy - r, cy + r))
    art.poly([(cx, cy - r * 0.78), (cx - r * 0.16, cy - r * 0.14), (cx - r * 0.46, cy - r * 0.14)], (255, 255, 255, 120))


def ball(art, x, y, r, c_light, c_dark, cap=True):
    """장식 구슬: 원형 그라데이션·하이라이트·금속 캡."""
    art.shadow(lambda d, s: d.ellipse([s(x - r + 1), s(y - r + 2), s(x + r + 1), s(y + r + 2)], fill=255), color=(10, 30, 20), alpha=0.35, blur=2, dy=2)
    art.ellipse((x - r, y - r, x + r, y + r), ("r", x - r * 0.35, y - r * 0.4, r * 1.5, c_light, c_dark))
    art.ellipse((x - r * 0.55, y - r * 0.72, x - r * 0.05, y - r * 0.3), (255, 255, 255, 190))
    art.ellipse((x + r * 0.2, y + r * 0.35, x + r * 0.62, y + r * 0.7), (255, 255, 255, 50))
    if cap:
        art.rrect((x - r * 0.28, y - r - r * 0.34, x + r * 0.28, y - r + r * 0.08), ("v", (255, 226, 130), (196, 144, 40), y - r - 3, y - r), radius=1.5)
        art.stroke([(x, y - r - r * 0.34), (x, y - r - r * 0.62)], (210, 170, 60), 1.2)


def bulb(art, x, y, color, lit, glow_r=15):
    """전구: 점등이면 번짐과 밝은 중심."""
    if lit:
        art.glow(x, y, glow_r, color, 0.55)
        art.ellipse((x - 5.5, y - 5, x + 5.5, y + 7), ("r", x, y, 8, (255, 255, 240), color))
        art.ellipse((x - 2.5, y - 3.5, x - 0.5, y - 0.5), (255, 255, 255, 230))
    else:
        art.ellipse((x - 5, y - 4.5, x + 5, y + 6), ("v", tuple(min(255, int(c * 0.9 + 30)) for c in color), tuple(int(c * 0.65) for c in color), y - 5, y + 6))
        art.ellipse((x - 2.5, y - 3, x - 0.8, y - 0.8), (255, 255, 255, 150))
    art.rrect((x - 2.6, y - 8, x + 2.6, y - 3.8), (70, 80, 70), radius=1)


def scalloped_tier(apex_y, base_y, half, bumps, sag=9, cx=256):
    """위쪽이 뾰족하고 아래 가장자리가 물결 모양인 가지층 윤곽."""
    pts = [(cx, apex_y)]
    # 오른쪽 변: 살짝 오목하게
    for i in range(1, 7):
        t = i / 6
        x = cx + half * t * (0.9 + 0.1 * t)
        y = apex_y + (base_y - apex_y) * t
        pts.append((x, y))
    # 물결 밑단
    for k in range(bumps * 8 + 1):
        t = k / (bumps * 8)
        x = cx + half - 2 * half * t
        y = base_y + sag * abs(math.sin(math.pi * t * bumps)) - sag * 0.15
        pts.append((x, y))
    for i in range(6, 0, -1):
        t = i / 6
        pts.append((cx - half * t * (0.9 + 0.1 * t), apex_y + (base_y - apex_y) * t))
    return pts


def drooping_tier(apex_y, base_y, half, tips, droop=16, cx=256):
    """가지 끝이 뾰족하게 아래로 처지는 가지층 윤곽(두 번째 레퍼런스 관찰: 겹겹의 처진 가지)."""
    pts = [(cx, apex_y)]
    for i in range(1, 9):
        t = i / 8
        pts.append((cx + half * (t ** 0.92), apex_y + (base_y - apex_y) * t))
    n = tips * 2
    for k in range(n + 1):
        t = k / n
        x = cx + half - 2 * half * t
        if k % 2 == 1:  # 가지 끝(처짐)
            pts.append((x, base_y + droop * (0.8 + 0.2 * math.sin(k * 1.7))))
        else:  # 가지 사이 골
            pts.append((x, base_y - droop * 0.35))
    for i in range(8, 0, -1):
        t = i / 8
        pts.append((cx - half * (t ** 0.92), apex_y + (base_y - apex_y) * t))
    return pts


def snow_clump(art, x, y, w, c0=(255, 255, 255), c1=(212, 226, 248), alpha=0.97):
    """가지 위에 쌓인 눈덩이: 크기가 다른 둥근 덩이 셋."""
    for dx, dy, sw, sh in ((-0.28, 0.1, 0.55, 0.7), (0.0, -0.05, 0.62, 1.0), (0.3, 0.12, 0.5, 0.65)):
        art.ellipse((x + dx * w - sw * w / 2, y + dy * w - sh * w * 0.3, x + dx * w + sw * w / 2, y + dy * w + sh * w * 0.3),
                    ("v", c0, c1, y - w * 0.3, y + w * 0.3), alpha=alpha)
