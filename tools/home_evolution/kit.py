"""집 성장 그림 부품(HEV1102A01). 128×128, 납작한 면 + 갈색 윤곽 + 연두 받침.

좌표: 땅 G=104. 주요 윤곽은 x=50 중심(CX), 대략 x 8~92에 둔다. 집 안 화랑이가
오른쪽 아래(x≥72, y≥52)에 앉으므로 그 자리에 건물의 핵심을 두지 않는다.
"""
import math
import re

O = "#5A4033"      # 윤곽
G = 104            # 땅 높이
CX = 50            # 건물 중심
POINTS = 72        # SVG 기준 크기(pt)

# 자주 쓰는 재료 색
SAND, SAND2 = "#E9CF97", "#CFAF72"
STONE, STONE2 = "#D5D0C4", "#B5AF9F"
MARBLE, MARBLE2 = "#F6F1E4", "#DDD5C0"
BRICK, BRICK2 = "#C4714F", "#A25A3D"
WOOD, WOOD2 = "#A9744A", "#855836"
RED, RED2 = "#CF5545", "#A83F33"
GOLD, GOLD2 = "#EDBE4E", "#CF9A2F"
COPPER, COPPER2 = "#7FBFA8", "#5F9F8A"
SLATE, SLATE2 = "#68748A", "#515C70"
GLASS, GLASS2 = "#9CCFE0", "#6FAFC8"
WIN = "#54697C"
TILE = "#5F6F78"
LEAF = "#7FB765"


def n(v):
    s = f"{v:.1f}"
    return s[:-2] if s.endswith(".0") else s


def pts(p):
    return " ".join(f"{n(x)},{n(y)}" for x, y in p)


class C:
    """그림 한 장. 기본 윤곽 굵기 2, 세부는 s=1.2 또는 s=0."""

    def __init__(self):
        self.parts = []

    def _a(self, f, s):
        a = f' fill="{f}"' if f != "none" else ' fill="none"'
        if s == 0:
            a += ' stroke="none"'
        elif s != 2:
            a += f' stroke-width="{n(s)}"'
        return a

    def raw(self, t):
        self.parts.append(t)

    def r(self, x, y, w, h, f, s=2, rx=0):
        q = f' rx="{n(rx)}"' if rx else ""
        self.parts.append(f'<rect x="{n(x)}" y="{n(y)}" width="{n(w)}" height="{n(h)}"{q}{self._a(f, s)}/>')

    def p(self, d, f="none", s=2, col=None):
        q = f' stroke="{col}"' if col else ""
        self.parts.append(f'<path d="{d}"{self._a(f, s)}{q}/>')

    def poly(self, points, f, s=2):
        self.parts.append(f'<path d="M{pts(points)}z"{self._a(f, s)}/>'.replace(",", " ").replace("M", "M", 1))

    def c(self, x, y, r, f, s=2):
        self.parts.append(f'<circle cx="{n(x)}" cy="{n(y)}" r="{n(r)}"{self._a(f, s)}/>')

    def e(self, x, y, rx, ry, f, s=2):
        self.parts.append(f'<ellipse cx="{n(x)}" cy="{n(y)}" rx="{n(rx)}" ry="{n(ry)}"{self._a(f, s)}/>')

    def l(self, x1, y1, x2, y2, s=1.2, col=None):
        c = f' stroke="{col}"' if col else ""
        self.parts.append(f'<path d="M{n(x1)} {n(y1)}L{n(x2)} {n(y2)}" fill="none" stroke-width="{n(s)}"{c}/>')

    # ── 면 ──────────────────────────────────────
    def shade(self, x, y, w, h, f):
        """오른쪽 그늘 면(윤곽 없음)."""
        self.r(x, y, w, h, f, s=0)

    def box(self, x, y, w, h, f, f2=None, sw=.28, s=2):
        """그늘 띠가 있는 상자. y는 윗변."""
        self.r(x, y, w, h, f, s=0)
        if f2:
            self.r(x + w * (1 - sw), y, w * sw, h, f2, s=0)
        self.r(x, y, w, h, "none", s=s)

    def windows(self, x, y, w, h, nx, ny, f=WIN, fill=.55):
        """창 격자. 칸마다 작은 사각형 하나, 파일 크기를 위해 한 경로로 묶는다."""
        cw, ch = w / nx, h / ny
        ww, wh = cw * fill, ch * fill
        d = "".join(
            f"M{n(x + cw * i + (cw - ww) / 2)} {n(y + ch * j + (ch - wh) / 2)}h{n(ww)}v{n(wh)}h{n(-ww)}z"
            for i in range(nx) for j in range(ny)
        )
        self.p(d, f, s=0)

    def hlines(self, x, y, w, h, k, s=1, col=None):
        d = "".join(f"M{n(x)} {n(y + h * (i + 1) / (k + 1))}h{n(w)}" for i in range(k))
        c = f' stroke="{col}"' if col else ""
        self.parts.append(f'<path d="{d}" fill="none" stroke-width="{n(s)}"{c}/>')

    def vlines(self, x, y, w, h, k, s=1, col=None):
        d = "".join(f"M{n(x + w * (i + 1) / (k + 1))} {n(y)}v{n(h)}" for i in range(k))
        c = f' stroke="{col}"' if col else ""
        self.parts.append(f'<path d="{d}" fill="none" stroke-width="{n(s)}"{c}/>')

    # ── 고전 ────────────────────────────────────
    def steps(self, cx, y, w, k, h, f, inset=4):
        """y를 바닥으로 위로 좁아지는 계단. 맨 위 y를 돌려준다."""
        for i in range(k):
            ww = w - i * inset * 2
            self.r(cx - ww / 2, y - (i + 1) * h, ww, h, f, s=1.4)
        return y - k * h

    def columns(self, x, y, w, h, k, f=MARBLE, f2=MARBLE2, cw=None):
        """x~x+w 사이 기둥 k개. y는 기둥 윗변."""
        cw = cw or max(2.4, w / k * .46)
        gap = (w - cw) / (k - 1) if k > 1 else 0
        for i in range(k):
            xx = x + gap * i
            self.r(xx, y, cw, h, f, s=1.2)
            self.r(xx + cw * .62, y + .6, cw * .3, h - 1.2, f2, s=0)

    def pediment(self, cx, y, w, h, f=MARBLE):
        """삼각 박공. y는 아랫변."""
        self.poly([(cx - w / 2, y), (cx, y - h), (cx + w / 2, y)], f)

    def temple(self, cx, base, w, h, k, f=MARBLE, f2=MARBLE2, roof=None, st=3):
        """그리스식 신전 정면. 위 y를 돌려준다."""
        y = self.steps(cx, base, w + 8, st, 2.6, f2, inset=1.6)
        ch = h
        self.r(cx - w / 2 + 3, y - ch, w - 6, ch, "#8D8069", s=0)
        self.columns(cx - w / 2 + 1, y - ch, w - 2, ch, k, f, f2)
        self.r(cx - w / 2 - 1, y - ch - 5, w + 2, 5, f, s=1.6)
        self.pediment(cx, y - ch - 5, w + 4, w * .24, roof or f)
        return y - ch - 5 - w * .24

    def arch(self, cx, y, w, h, f=WIN, s=1.4):
        """아치 문·창. y는 바닥."""
        r = w / 2
        self.p(f"M{n(cx - r)} {n(y)}V{n(y - h + r)}A{n(r)} {n(r)} 0 0 1 {n(cx + r)} {n(y - h + r)}V{n(y)}z", f, s)

    def arches(self, x, y, w, h, k, f=WIN, fill=.62):
        """x~x+w 사이 아치 k개."""
        cw = w / k
        for i in range(k):
            self.arch(x + cw * (i + .5), y, cw * fill, h, f, s=0)

    # ── 지붕·탑 ─────────────────────────────────
    def dome(self, cx, y, r, f, f2=None, ribs=0, h=None):
        """반구 돔. y는 돔 바닥."""
        h = h or r
        self.p(f"M{n(cx - r)} {n(y)}C{n(cx - r)} {n(y - h * 1.33)} {n(cx + r)} {n(y - h * 1.33)} {n(cx + r)} {n(y)}z", f)
        if f2:
            self.p(f"M{n(cx + r * .3)} {n(y - h * .96)}C{n(cx + r * .7)} {n(y - h * .75)} {n(cx + r * .86)} {n(y - h * .4)} {n(cx + r * .86)} {n(y - .8)}H{n(cx + r - 1)}C{n(cx + r - 1)} {n(y - h * .6)} {n(cx + r * .7)} {n(y - h * .85)} {n(cx + r * .3)} {n(y - h * .96)}z", f2, s=0)
        for i in range(ribs):
            t = (i + 1) / (ribs + 1) * 2 - 1
            self.p(f"M{n(cx + t * r)} {n(y)}Q{n(cx + t * r * .9)} {n(y - h * .7)} {n(cx)} {n(y - h)}", s=1)

    def onion(self, cx, y, r, h, f):
        """양파 돔. y는 바닥. 꼭대기 y를 돌려준다."""
        t = y - h
        self.p(f"M{n(cx - r * .7)} {n(y)}C{n(cx - r * 1.5)} {n(y - h * .45)} {n(cx - r * .3)} {n(y - h * .7)} {n(cx)} {n(t)}C{n(cx + r * .3)} {n(y - h * .7)} {n(cx + r * 1.5)} {n(y - h * .45)} {n(cx + r * .7)} {n(y)}z", f)
        return t

    def spire(self, cx, y, w, h, f):
        self.poly([(cx - w / 2, y), (cx, y - h), (cx + w / 2, y)], f)
        return y - h

    def crenel(self, x, y, w, h, k, f):
        """성벽 윗줄. y는 총안 윗변, h는 이 높이만큼 내려간 띠."""
        cw = w / (2 * k - 1)
        d = f"M{n(x)} {n(y + h)}"
        for i in range(k):
            d += f"V{n(y)}h{n(cw)}V{n(y + h * .5)}" + (f"h{n(cw)}" if i < k - 1 else "")
        d += f"V{n(y + h)}z"
        self.p(d, f)

    def tower(self, cx, y, w, h, f, f2=None, top="cren"):
        """성탑. y는 바닥. 꼭대기 y를 돌려준다."""
        self.box(cx - w / 2, y - h, w, h, f, f2)
        t = y - h
        if top == "cren":
            self.crenel(cx - w / 2 - 1.5, t - 4, w + 3, 6, 3, f)
            return t - 4
        if top == "cone":
            return self.spire(cx, t, w + 4, w * 1.2, RED)
        if top == "slate":
            return self.spire(cx, t, w + 4, w * 1.4, SLATE)
        return t

    def eave(self, cx, y, w, h, f, lift=None):
        """동아시아 기와지붕. 처마 끝이 살짝 들린다. y는 처마 줄."""
        k = lift if lift is not None else h * .35
        a, b = cx - w / 2, cx + w / 2
        self.p(f"M{n(a)} {n(y - k)}Q{n(a + w * .12)} {n(y + k * .5)} {n(a + w * .22)} {n(y - h * .35)}L{n(cx - w * .16)} {n(y - h)}H{n(cx + w * .16)}L{n(b - w * .22)} {n(y - h * .35)}Q{n(b - w * .12)} {n(y + k * .5)} {n(b)} {n(y - k)}Q{n(cx)} {n(y + k)} {n(a)} {n(y - k)}z", f)

    def pagoda(self, cx, base, w, k, th, f, roof, shrink=.84, finial=GOLD):
        """층탑. 위 y를 돌려준다."""
        y, ww = base, w
        for i in range(k):
            bw = ww * .66
            self.box(cx - bw / 2, y - th, bw, th, f, s=1.4)
            self.vlines(cx - bw / 2, y - th + 1, bw, th - 1.6, 2, s=.8)
            self.eave(cx, y - th, ww, th * .55, roof)
            y -= th + th * .55 - th * .25
            ww *= shrink
        self.l(cx, y + 2, cx, y - 8, s=1.8, col=finial)
        return y - 8

    def gable(self, x, y, w, h, f):
        """맞배지붕. y는 처마 줄."""
        self.poly([(x - 2, y), (x + w / 2, y - h), (x + w + 2, y)], f)

    def minaret(self, cx, base, h, w=5, f=MARBLE, cap=None):
        self.box(cx - w / 2, base - h, w, h, f, s=1.4)
        self.r(cx - w / 2 - 1, base - h * .7, w + 2, 2, f, s=1)
        self.r(cx - w / 2 - 1, base - h - 1, w + 2, 2.2, f, s=1)
        self.spire(cx, base - h - 1, w, 8, cap or f)

    def gothic(self, cx, y, w, h, f, f2, spire=SLATE):
        """고딕 쌍탑 대신 쓰는 뾰족 탑 하나."""
        self.box(cx - w / 2, y - h, w, h, f, f2)
        self.spire(cx, y - h, w + 2, h * .7, spire)
        self.arch(cx, y - h * .5, w * .45, h * .28, WIN, s=0)

    def rose(self, cx, cy, r, f="#7FA6C9"):
        self.c(cx, cy, r, f, s=1.4)
        self.c(cx, cy, r * .35, GOLD, s=.8)
        d = "".join(f"M{n(cx + r * .4 * math.cos(a))} {n(cy + r * .4 * math.sin(a))}L{n(cx + r * math.cos(a))} {n(cy + r * math.sin(a))}"
                    for a in [i * math.pi / 4 for i in range(8)])
        self.p(d, s=.7)

    # ── 근현대 ──────────────────────────────────
    def glass(self, x, y, w, h, f=GLASS, f2=GLASS2, nx=3, ny=8, line="#E8F4F4"):
        """유리 커튼월 상자."""
        self.box(x, y, w, h, f, f2)
        self.vlines(x, y + 1, w, h - 2, nx - 1, s=.7, col=line)
        self.hlines(x + 1, y, w - 2, h, ny - 1, s=.7, col=line)

    def trunk(self, x, h=9, r=6):
        """작은 나무(받침 왼쪽·오른쪽 장식)."""
        self.r(x - 1, G - h, 2, h, WOOD, s=1)
        self.c(x, G - h - r * .6, r, LEAF, s=1.4)

    def flag(self, x, y, h=8, f=RED):
        self.l(x, y, x, y - h, s=1.2)
        self.poly([(x, y - h), (x + 6, y - h + 2), (x, y - h + 4)], f, s=.8)


def ground(c, extra=""):
    """연두 받침. 화랑이가 앉는 자리까지 넓게 깐다."""
    c.raw('<ellipse cx="64" cy="108" rx="58" ry="14" fill="#A9D57B"/>'
          '<path d="M14 113Q64 128 114 113Q118 120 64 123Q10 120 14 113z" fill="#8FC066" stroke="none"/>'
          + extra)


_PATH = re.compile(r'<path d="([^"]*)"([^>]*)/>$')


def merge_paths(parts):
    """같은 속성의 윤곽 없는·채우기 없는 연속 경로를 하나로 합쳐 용량을 줄인다."""
    out = []
    for part in parts:
        m = _PATH.match(part)
        if m and out and 'fill="none"' in m.group(2):
            prev = _PATH.match(out[-1])
            if prev and prev.group(2) == m.group(2):
                out[-1] = f'<path d="{prev.group(1)}{m.group(1)}"{m.group(2)}/>'
                continue
        out.append(part)
    return out


def svg(draw, fit=None, with_ground=True, view=None):
    """그림 함수 하나를 SVG 문자열로. fit은 받침 위 건물을 (64, G) 기준으로 줄이는 배율."""
    c = C()
    draw(c)
    body = "".join(merge_paths(c.parts))
    if fit:
        k = n(64 * (1 - fit)) + " " + n(G * (1 - fit))
        body = f'<g transform="translate({k}) scale({fit})">{body}</g>'
    base = C()
    if with_ground:
        ground(base)
    # 표시 크기는 최대 68pt다. 기준 크기를 낮춰 카탈로그의 @2x·@3x 래스터 용량을 줄인다.
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{POINTS}" height="{POINTS}" viewBox="{view or "0 0 128 128"}">'
            f'<g stroke="{O}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">'
            + "".join(base.parts) + body + "</g></svg>")


# ── 세부 묘사(디테일 시안 이후) ─────────────────
def _blocks(self, x, y, w, h, rows, k=4, s=.6, col="#00000033"):
    """돌·벽돌 줄눈. 줄마다 어긋난 세로 줄눈을 한 경로에 넣는다."""
    rh = h / rows
    d = "".join(f"M{n(x)} {n(y + rh * j)}h{n(w)}" for j in range(1, rows))
    cw = w / k
    for j in range(rows):
        off = cw / 2 if j % 2 else 0
        d += "".join(f"M{n(x + off + cw * i)} {n(y + rh * j)}v{n(rh)}" for i in range(k) if off + cw * i > 0)
    self.parts.append(f'<path d="{d}" fill="none" stroke-width="{n(s)}" stroke="{col}"/>')


def _shadow(self, cx, w, y=G + 1):
    """받침 위 건물 그림자."""
    self.e(cx, y, w / 2, 3.4, "#7FAE5C", s=0)


def _cloud(self, x, y, k=1, f="#FFFFFF"):
    self.p(f"M{n(x)} {n(y)}a{n(4 * k)} {n(4 * k)} 0 0 1 {n(3 * k)}-{n(6 * k)}a{n(5 * k)} {n(5 * k)} 0 0 1 {n(9 * k)}-{n(1 * k)}a{n(4 * k)} {n(4 * k)} 0 0 1 {n(5 * k)} {n(7 * k)}z", f, s=1)


def _sun(self, x, y, r=6):
    d = "".join(f"M{n(x + (r + 1.6) * math.cos(a))} {n(y + (r + 1.6) * math.sin(a))}L{n(x + (r + 4) * math.cos(a))} {n(y + (r + 4) * math.sin(a))}"
                for a in [i * math.pi / 4 for i in range(8)])
    self.p(d, s=1)
    self.c(x, y, r, "#F5C65A", s=1.2)


def _birds(self, x, y):
    self.p(f"M{x} {y}q2-2 4 0q2-2 4 0M{x + 12} {y - 5}q1.6-1.6 3 0q1.4-1.6 3 0", s=.9)


def _cypress(self, x, y=G, h=18, w=7, f="#5E9A63"):
    self.p(f"M{x} {y - h}C{x + w * .7} {y - h * .55} {x + w * .55} {y - h * .1} {x} {y}C{x - w * .55} {y - h * .1} {x - w * .7} {y - h * .55} {x} {y - h}z", f, s=1.1)


def _palm(self, x, y=G, h=22):
    self.p(f"M{x} {y}Q{x + 1.5} {y - h * .5} {x + 3} {y - h}", s=2)
    t = y - h
    self.p(f"M{x + 3} {t}q-7-4-10 2q6-2 10-2zM{x + 3} {t}q7-4 10 2q-6-2-10-2zM{x + 3} {t}q-5-7-10-5q6 1 10 5zM{x + 3} {t}q5-7 10-5q-6 1-10 5z", LEAF, s=.9)


def _water(self, x, y, w, h=7, f="#9CD3E6"):
    """못·강. 잔물결 두 줄."""
    self.r(x, y, w, h, f, s=1.1, rx=h / 2.4)
    self.parts.append(f'<path d="M{n(x + w * .15)} {n(y + h * .4)}h{n(w * .22)}M{n(x + w * .55)} {n(y + h * .68)}h{n(w * .25)}" fill="none" stroke="#fff" stroke-width=".8"/>')


def _people(self, x, y=G, k=3, gap=3.4):
    """사람 크기 비교용 작은 점 인물."""
    self.p("".join(f"M{n(x + i * gap)} {y}v-3.4M{n(x + i * gap)} {n(y - 5)}h.01" for i in range(k)), s=1.2)


def _fluted(self, x, y, w, h, k, f=MARBLE, f2=MARBLE2):
    """세로 홈 기둥 줄(주두 포함)."""
    self.columns(x, y + 1.6, w, h - 1.6, k, f, f2)
    cw = max(2.4, w / k * .46)
    gap = (w - cw) / (k - 1) if k > 1 else 0
    self.p("".join(f"M{n(x + gap * i - .8)} {n(y + 1)}h{n(cw + 1.6)}" for i in range(k)), s=1.2)


C.blocks, C.shadow, C.cloud, C.sun, C.birds = _blocks, _shadow, _cloud, _sun, _birds
C.cypress, C.palm, C.water, C.people, C.fluted = _cypress, _palm, _water, _people, _fluted
