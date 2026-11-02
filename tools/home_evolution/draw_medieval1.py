"""중세 건축물 1(HEV1102A01)."""
import re
from .kit import *

D = {}
_RECT = re.compile(r'^<rect x="([^"]+)" y="([^"]+)" width="([^"]+)" height="([^"]+)"([^>]*)/>$')
_PATH = re.compile(r'^<path d="([^"]*)"([^>]*)/>$')
_PATH_D = re.compile(r'd="([^"]*)"')


_ARGS = dict(M=2, L=2, H=1, V=1, C=6, S=4, Q=4, T=2, A=7, Z=0)


def _num(v):
    """0.1 단위 정수를 가장 짧은 숫자 글자로."""
    t = f"{abs(v) // 10}" if v % 10 == 0 else f"{abs(v) // 10 or ''}.{abs(v) % 10}"
    return ("-" if v < 0 else "") + t


def _join(vals):
    out = ""
    for t in vals:
        if out and not (t[0] == "-" or (t[0] == "." and "." in out.rsplit(" ", 1)[-1].rsplit("-", 1)[-1])):
            out += " "
        out += t
    return out


def _slim_d(d):
    """경로를 같은 모양의 가장 짧은 글자로: 절대/상대 중 짧은 쪽을 고르고 반복 명령을 생략한다."""
    toks = re.findall(r"[A-Za-z]|-?\d*\.?\d+", d)
    i, cmd, res, last = 0, "", "", ""
    x = y = sx = sy = 0
    while i < len(toks):
        if toks[i].isalpha():
            cmd = toks[i]
            i += 1
        U = cmd.upper()
        if U == "Z":
            res += "z"
            last, x, y = "z", sx, sy
            continue
        k = _ARGS[U]
        v = [round(float(t) * 10) for t in toks[i:i + k]]
        i += k
        rel = cmd.islower()
        if U == "A":
            ex, ey = v[5] + (x if rel else 0), v[6] + (y if rel else 0)
            head = [_num(v[0]), _num(v[1]), toks[i - 5], toks[i - 4], toks[i - 3]]
            A_, R_ = head + [_num(ex), _num(ey)], head + [_num(ex - x), _num(ey - y)]
        elif U == "H":
            ex, ey = v[0] + (x if rel else 0), y
            A_, R_ = [_num(ex)], [_num(ex - x)]
        elif U == "V":
            ex, ey = x, v[0] + (y if rel else 0)
            A_, R_ = [_num(ey)], [_num(ey - y)]
        else:
            ab = [q + ((x if j % 2 == 0 else y) if rel else 0) for j, q in enumerate(v)]
            ex, ey = ab[-2], ab[-1]
            A_ = [_num(q) for q in ab]
            R_ = [_num(q - (x if j % 2 == 0 else y)) for j, q in enumerate(ab)]
        if U == "L" and ey == y:
            U, A_, R_ = "H", [_num(ex)], [_num(ex - x)]
        elif U == "L" and ex == x:
            U, A_, R_ = "V", [_num(ey)], [_num(ey - y)]
        a_, r_ = _join(A_), _join(R_)
        use_rel = len(r_) < len(a_) and U != "M"
        c_ = U.lower() if use_rel else U
        body = r_ if use_rel else a_
        res += ("" if c_ == last and U != "M" else c_) + body if c_ == last and U != "M" and body[0] == "-" else (" " + body if c_ == last and U != "M" else c_ + body)
        last = c_
        x, y = ex, ey
        if U == "M":
            sx, sy = x, y
            cmd = "L" if cmd == "M" else "l"
    return res


def _slim(c):
    """같은 그림을 더 짧은 SVG로: 사각형을 경로로 바꾸고 경로 글자를 줄인다."""
    out = []
    for part in c.parts:
        m = _RECT.match(part)
        if m and " rx=" not in m.group(5):
            x, y, w, h, rest = m.groups()
            part = f'<path d="M{x} {y}h{w}v{h}h-{w}z"{rest}/>'
        part = _PATH_D.sub(lambda q: f'd="{_slim_d(q.group(1))}"', part)
        part = re.sub(r' stroke-width="(1\.7|1\.8|1\.9|2\.1)"', "", part)
        part = part.replace('stroke-width="0.', 'stroke-width=".')
        m = _PATH.match(part)
        q = _PATH.match(out[-1]) if m and out else None
        if q and 'stroke="none"' in m.group(2) and q.group(2) == m.group(2):
            out[-1] = f'<path d="{q.group(1)}{m.group(1)}"{m.group(2)}/>'
        else:
            out.append(part)
    c.parts = out


def d(f):
    def draw(c):
        f(c)
        _slim(c)
    D[f.__name__] = draw
    return f


def _tz(c, cx, y, w1, w2, h, f, s=1.6):
    """사다리꼴. y는 바닥, w1 아래 너비, w2 위 너비."""
    c.p(f"M{n(cx - w1 / 2)} {n(y)}L{n(cx - w2 / 2)} {n(y - h)}H{n(cx + w2 / 2)}L{n(cx + w1 / 2)} {n(y)}z", f, s)


def _pt(x, y, w, h):
    """첨두 아치 경로."""
    return (f"M{n(x - w / 2)} {n(y)}V{n(y - h * .6)}Q{n(x - w / 2)} {n(y - h * .85)} {n(x)} {n(y - h)}"
            f"Q{n(x + w / 2)} {n(y - h * .85)} {n(x + w / 2)} {n(y - h * .6)}V{n(y)}z")


def _sroof(c, cx, y, w, h, f, s=1.5):
    """돌 탑의 얇은 옥개석. 모서리가 살짝 들린다. y는 아랫변."""
    a, b = cx - w / 2, cx + w / 2
    c.p(f"M{n(a)} {n(y - h * .55)}Q{n(a + w * .12)} {n(y)} {n(a + w * .3)} {n(y)}H{n(b - w * .3)}"
        f"Q{n(b - w * .12)} {n(y)} {n(b)} {n(y - h * .55)}L{n(b - w * .14)} {n(y - h)}H{n(a + w * .14)}z", f, s)


def _wroof(c, cx, y, w, h, f, s=1.7, rid=.14):
    """오목하게 흐르는 기와지붕. y는 처마 줄, 모서리가 살짝 들린다."""
    a, b, k = cx - w / 2, cx + w / 2, min(h * .2, 2.4)
    r0, r1 = cx - w * rid, cx + w * rid
    c.p(f"M{n(a)} {n(y - k)}Q{n(cx)} {n(y + k * .7)} {n(b)} {n(y - k)}Q{n(r1 + w * .12)} {n(y - h * .28)} {n(r1)} {n(y - h)}"
        f"H{n(r0)}Q{n(r0 - w * .12)} {n(y - h * .28)} {n(a)} {n(y - k)}z", f, s)


def _rings(c, cx, y, k, gap, w, col=O, s=.8):
    """상륜부 고리."""
    c.p("".join(f"M{n(cx - w / 2 * (1 - i * .05))} {n(y - i * gap)}h{n(w * (1 - i * .05))}" for i in range(k)), s=s, col=col)


def _bush(c, pts, f="#6FA85E", s=1):
    """둥근 나무 덩어리들."""
    for x, y, r in pts:
        c.c(x, y, r, f, s)


@d
def tiwanaku(c):
    st, st2, dk = "#A5A798", "#868A7B", "#5D6155"
    c.p("M4 92L18 72L26 78L42 58L58 78L70 70L94 92z", "#C9D5DC", s=1)
    c.p("M36 66L42 58L48 65L43 63L40 67z", "#FFFFFF", s=.6)
    c.shadow(48, 88)
    c.r(4, 100, 88, 4.5, "#8F9284", s=1.3)
    # 너비가 높이보다 큰 한 덩어리 돌(3.8m x 2.8m), 넓은 문
    G_ = "M8 44H88V102H60V68H36V102H8z"
    c.p(G_, st, 2)
    c.r(77, 45, 10.5, 56.5, st2, s=0)
    c.r(56.8, 69, 3, 32, st2, s=0)
    c.p(G_, s=2)
    c.p("M39 102V71H57V102", s=.7, col=dk)
    # 상인방: 가운데 신상과 좌우 8칸 3줄의 날개 인물 48
    c.windows(10, 47, 29, 15, 8, 3, dk, fill=.56)
    c.windows(57, 47, 29, 15, 8, 3, dk, fill=.56)
    c.p("M10 52h29M10 57h29M57 52h29M57 57h29", s=.45, col=dk)
    c.r(40.5, 46.5, 15, 15.5, "#BDBFAF", s=1)
    c.p("M43 46.5v-1M45.3 46.5v-1M48 46.5v-1.3M50.7 46.5v-1M53 46.5v-1", s=.7)
    c.r(44.3, 49, 7.4, 6.4, st2, s=.8)
    c.p("M45.8 51h1.3M48.9 51h1.3M46.5 53.5h3", s=.7, col=dk)
    c.p("M42.7 49v11M53.3 49v11M45 55.4v5h6v-5", s=.8, col=dk)
    c.p("M10 63h29v3H10zM57 63h29v3H57z", "#94988A", s=.6)
    c.vlines(10, 63, 29, 3, 12, s=.5, col=dk)
    c.vlines(57, 63, 29, 3, 12, s=.5, col=dk)
    # 기둥의 얕은 벽감과 오른쪽 위 금
    c.p("M16 72h12v5h-2.4v9h-7.2v-9h-2.4zM67 72h12v5h-2.4v9h-7.2v-9h-2.4z", "#94988A", s=.7)
    c.p("M80 44L77 51L80 57L77 66", s=.8)
    c.p("M12 94h6M24 97h5M66 93h6M74 97h6", s=.5, col=dk)
    c.p("M100 104l-5-.5l1-3.5h4l2 2z", "#94988A", s=.9)


@d
def songyue(c):
    br, br2, dk = "#CBB48C", "#AB9570", "#7B6A4F"
    c.p("M6 88Q24 56 44 72Q66 50 94 88z", "#BFD5B5", s=.9)
    c.cypress(15, 104, 22, 8)
    c.cypress(24, 104, 15, 6, "#6FA570")
    c.shadow(50, 54)
    c.r(29, 100, 42, 4.5, "#B9A583", s=1.3)
    c.box(32, 84, 36, 16, br, br2, sw=.25, s=1.8)
    c.blocks(32, 84, 36, 16, 5, 6, s=.4, col=dk)
    _tz(c, 50, 84, 40, 38, 2.5, br2, s=1.2)
    c.box(31, 66, 38, 15.5, br, br2, sw=.25, s=1.8)
    c.arch(50, 81.5, 8, 13, "#5B4A39", s=1.1)
    for x in (38.5, 61.5):
        c.arch(x, 79, 5, 9.5, dk, s=.8)
    c.p("M34 66.5V81M66 66.5V81M31 72h7M62 72h7", s=.5, col=dk)
    # 빽빽한 15층 처마, 탄환 모양 윤곽
    body = ""
    eaves = ""
    for i in range(15):
        t0 = i / 15
        y = 66 - i * 3.3
        hw = 5.5 + 17.5 * (1 - t0 ** 1.8)
        body += f"M{n(50 - hw + 1)} {n(y)}v-3.3h{n(hw * 2 - 2)}v3.3z"
        eaves += f"M{n(50 - hw - .4)} {n(y - .3)}Q{n(50 - hw + .4)} {n(y - 1.7)} {n(50 - hw + 1.7)} {n(y - 1.8)}H{n(50 + hw - 1.7)}Q{n(50 + hw - .4)} {n(y - 1.7)} {n(50 + hw + .4)} {n(y - .3)}z"
    c.p(body, dk, s=0)
    c.p(eaves, br, s=.8)
    c.p("".join(f"M{n(50 + (5.5 + 17.5 * (1 - (i / 15) ** 1.8)) * .35)} {n(66 - i * 3.3 - 1.8)}h{n((5.5 + 17.5 * (1 - (i / 15) ** 1.8)) * .5)}" for i in range(15)), s=1.1, col=br2)
    c.p("M46 15.5Q42 13 45 11H55Q58 13 54 15.5z", "#BCA57F", s=1.2)
    c.p("M47 11Q46 8 50 7.5Q54 8 53 11z", br2, s=1.1)
    c.l(50, 7.5, 50, 2.5, s=1.4)
    c.c(50, 3.5, 1.3, br, s=.8)


@d
def san_vitale(c):
    br, br2, dk = "#BF7F58", "#9C6443", "#7C4A31"
    tile = "#B5613F"
    c.shadow(48, 84)
    c.cypress(90, 104, 22, 7)
    # 왼쪽 둥근 계단탑과 뒤쪽 낮은 앱스
    c.box(9, 66, 12, 38, "#B67853", "#99603F", sw=.3, s=1.6)
    c.p("M7.5 66L15 55L22.5 66z", tile, 1.5)
    c.hlines(9, 66, 12, 38, 5, s=.45, col=dk)
    c.arch(15, 80, 3.5, 7, "#4F4238", s=.6)
    # 아래층 팔각 회랑
    c.p("M18 104V77L30 72H70L82 77V104z", br, 1.9)
    c.p("M70 72L82 77V104H70z", br2, s=0)
    c.p("M30 72V104M70 72V104", s=1.1)
    c.p("M18 104V77L30 72H70L82 77V104z", s=1.9)
    c.blocks(30, 74, 40, 30, 5, 4, s=.4, col=dk)
    for x in (24, 40, 50, 60, 76):
        c.arch(x, 90, 4.5, 11, "#4F4238", s=.8)
        c.p(f"M{x - 3.4} {80.5}a3.4 3.4 0 0 1 6.8 0", s=.7, col=dk)
    # 낮은 나르텍스 입구
    c.p("M38 104V96Q50 89 62 96V104z", "#D6A07A", s=1.2)
    c.arch(50, 104, 7, 8, "#4F4238", s=.8)
    c.p("M18 77L30 72H70L82 77L70 79.5H30z", tile, 1.4)
    c.p("M34 75h32M38 77.5h24", s=.5, col=br2)
    # 위층 팔각 드럼
    c.p("M26 72V48L34 44.5H66L74 48V72z", "#C98B62", 1.9)
    c.p("M66 44.5L74 48V72H66z", br2, s=0)
    c.p("M34 44.5V72M66 44.5V72", s=1)
    c.p("M26 72V48L34 44.5H66L74 48V72z", s=1.9)
    c.blocks(34, 46, 32, 26, 5, 4, s=.35, col=dk)
    for x in (42, 50, 58):
        c.arch(x, 67, 5.5, 15, "#4F4238", s=.9)
    c.p("M40.5 67v-8M43.5 67v-8M48.5 67v-8M51.5 67v-8M56.5 67v-8M59.5 67v-8", s=.45, col="#B8AFA0")
    c.arch(30, 66, 3.5, 12, "#4F4238", s=.7)
    c.arch(70, 66, 3.5, 12, "#4F4238", s=.7)
    # 낮은 팔각 기와 지붕
    c.p("M24 48L38 36H62L76 48L66 46H34z", tile, 1.9)
    c.p("M38 36L34 46M50 36V46M62 36L66 46", s=.8)
    c.p("M44 36L42 46M56 36L58 46", s=.45, col="#7C4A31")
    c.r(46, 33, 8, 3, br, s=1)
    c.l(50, 33, 50, 25, s=1.4)
    c.p("M47.8 28.5h4.4", s=1.1)


@d
def palenque(c):
    st, st2, dk = "#D8D3BE", "#B5B199", "#6F6C5A"
    moss = "#8FA77F"
    _bush(c, [(11, 62, 8), (21, 54, 9), (34, 49, 8), (68, 48, 8), (80, 54, 9), (90, 63, 8)], "#6FA85E")
    _bush(c, [(8, 74, 7), (93, 74, 7)], "#5F9A55")
    c.shadow(50, 90)
    # 9단 테라스
    for i in range(9):
        y = 104 - i * 5.8
        w = 86 - i * 6.3
        _tz(c, 50, y, w, w - 2.2, 5.8, st if i % 2 else "#D0CBB5", s=1.4)
    # 이끼 얼룩
    c.p("M16 100h6M27 94h5M72 96h6M31 80h4M66 74h5M22 88h3M74 88h3", s=1.2, col=moss)
    # 가운데 계단
    c.p("M41 104L45 52H55L59 104z", "#E7E2CD", 1.3)
    c.p("".join(f"M{n(50 - (5 + (104 - y) * -0.0769 + 4))} {y}h{n((5 + (104 - y) * -0.0769 + 4) * 2)}" for y in range(56, 103, 3)), s=.45, col=dk)
    # 정상 신전: 기둥 6개, 문 5개, 경사 지붕
    c.r(29, 50, 42, 2.6, st2, s=1.3)
    c.r(31, 37, 38, 13, st, s=1.7)
    c.p("M33 50V40h5v10zM40.2 50V40h5v10zM47.5 50V40h5v10zM54.7 50V40h5v10zM62 50V40h5v10z", "#4C493D", s=.6)
    c.p("M29.5 37h41", s=1.8)
    c.p("M29 37L34 26H66L71 37z", "#C3BFA8", 1.8)
    c.p("M36 28.5c1 3 2 3 3 5M44 28c1 3-1 4 0 7M52 29c0 2 1 3 0 5M61 28c0 3 2 4 2 6", s=.5, col=dk)
    c.r(33, 23, 34, 3, st2, s=1.2)
    c.p("M36 23v-3h3v3M44 23v-5h3v5M52 23v-4h3v4M60 23v-2h3v2", s=1)
    c.birds(78, 18)


@d
def jeongnimsa(c):
    st, st2, dk = "#C9C6B6", "#A9A695", "#6D6B5D"
    c.p("M14 104Q11 92 16 82Q18 76 16 70M15 84Q20 80 24 80", s=2, col="#8A6C50")
    c.e(15, 68, 10, 4.4, "#5F9A63", s=1.1)
    c.e(25, 78, 6.5, 3.2, "#5F9A63", s=1.1)
    c.e(8, 79, 5, 2.6, "#6FA870", s=1)
    c.p("M11 90Q8 84 8 80", s=1.2, col="#8A6C50")
    c.shadow(50, 58)
    c.p("M24 104v-3h52v3z", st2, 1.3)
    c.p("M30 101v-4h40v4z", st, 1.4)
    c.vlines(30, 97, 40, 4, 5, s=.45, col=dk)
    # 5층: 층이 얇아지는 몸돌과 넓은 옥개석
    y = 97
    for i, (bw, bh, rw) in enumerate(((24, 21, 50), (17, 8, 39), (15.5, 7, 35.5), (14, 6.5, 32), (12.5, 6, 28.5))):
        c.box(50 - bw / 2, y - bh, bw, bh, st, st2, sw=.28, s=1.5)
        q = 1.6 if i else 2.6
        # 민흘림 모서리 기둥
        c.p(f"M{n(50 - bw / 2 + q)} {n(y)}v-{n(bh)}M{n(50 + bw / 2 - q)} {n(y)}v-{n(bh)}", s=.6, col=dk)
        if i == 0:
            c.p("M50 97V76M40 86h20", s=.4, col=dk)
        c.r(50 - bw / 2 - 1.2, y - bh - 1.3, bw + 2.4, 1.4, st2, s=.8)
        y -= bh + 1.3
        _sroof(c, 50, y, rw, 3.5, st)
        y -= 3.5
    c.p(f"M45.5 {n(y + .1)}v-1.8h9v1.8z", st2, 1)
    c.p(f"M47 {n(y - 1.8)}q3-4 6 0z", st, 1)
    c.l(50, y - 3.8, 50, y - 7, s=1)


@d
def zhaozhou(c):
    st, st2, dk = "#CEC7B4", "#ABA490", "#6C6757"
    c.water(4, 96, 92, 12, "#9CD3E6")
    # 교각 몸체와 큰 아치
    c.p("M8 72Q50 56 92 72L95 96H82C76 72 60 66 50 66C40 66 24 72 18 96H5z", st, 2)
    c.p("M92 72L95 96H82C78 80 72 74 66 71z", st2, s=0)
    # 어깨의 작은 아치 네 개
    for x, y, r, t in ((20.5, 81, 4, 1), (29.5, 73.5, 3, 1), (79.5, 81, 4, -1), (70.5, 73.5, 3, -1)):
        c.p(f"M{n(x - r)} {n(y + t * 1.6)}A{n(r)} {n(r)} 0 0 1 {n(x + r)} {n(y - t * 1.6)}z", "#E4F0F3", s=1.2)
    # 큰 아치 쐐기돌 띠
    c.p("M18 96C24 72 40 66 50 66C60 66 76 72 82 96", s=2)
    c.p("M22.5 96C28 75 41 70 50 70C59 70 72 75 77.5 96", s=.8)
    d_ = ""
    for i in range(1, 16):
        a = math.pi * i / 16
        x = 50 - 29.8 * math.cos(a)
        y = 95 - 27.6 * math.sin(a) ** .72
        x2 = 50 - 25.5 * math.cos(a)
        y2 = 95 - 24.5 * math.sin(a) ** .72
        d_ += f"M{n(x)} {n(y)}L{n(x2)} {n(y2)}"
    c.p(d_, s=.6, col=dk)
    c.p("M12 78Q50 62 88 78M36 64q14 0 28 0", s=.4, col=dk)
    # 난간
    c.p("M6 68Q50 52 94 68V72Q50 56 6 72z", "#DDD6C4", 1.5)
    c.p("".join(f"M{x} {n(69.5 - 8 * (1 - ((x - 50) / 44) ** 2) + 2.5)}v-3.6" for x in range(12, 92, 6)), s=.8)
    c.p("M6 68Q50 52 94 68", s=1.8)
    c.people(45, 59, 2, 4)
    c.birds(70, 40)
    c.p("M40 100h13l-2 3h-9z", WOOD, 1)
    c.p("M46 100v-5l4 4z", "#F0E7D0", .7)


@d
def horyuji(c):
    wood, wood2, wall = "#6C4E3A", "#54392A", "#EEE7D6"
    roof, roof2 = "#6F747A", "#565B60"
    c.cypress(14, 104, 20, 8, "#5E9A63")
    c.shadow(50, 66)
    c.p("M18 104v-5h64v5z", "#C8C1AE", 1.4)
    c.vlines(18, 99, 64, 5, 7, s=.4, col="#7E7866")
    y = 99
    # 위로 갈수록 크게 좁아지는 5층
    for i, (bw, h, rw, rh) in enumerate(((40, 10, 62, 8), (35, 7, 54, 7), (30, 6.5, 47, 6.5), (25, 6, 40, 6), (20, 6, 33, 6))):
        c.r(50 - bw / 2, y - h, bw, h, wall, s=1.4)
        c.r(50 + bw * .22, y - h + .7, bw * .28 - .7, h - 1.4, "#D9D0BB", s=0)
        k = 5 if i == 0 else 3
        c.p("".join(f"M{n(50 - bw / 2 + bw * j / (k + 1))} {n(y)}v-{n(h)}" for j in range(1, k + 1)) + f"M{n(50 - bw / 2)} {n(y - h * .55)}h{n(bw)}", s=1.1, col=wood)
        if i == 0:
            c.r(45.5, y - 8.4, 9, 8.4, wood2, s=.8)
            c.l(50, y - 8.4, 50, y, s=.6)
        c.r(50 - bw / 2 - 2, y - h - 1.6, bw + 4, 1.8, wood, s=.9)
        y -= h + 1.2
        _wroof(c, 50, y, rw, rh, roof)
        c.p(f"M{n(50 - rw * .1)} {n(y - rh * .5)}L{n(50 - rw * .12)} {n(y - .2)}M{n(50)} {n(y - rh * .5)}V{n(y + .4)}M{n(50 + rw * .1)} {n(y - rh * .5)}L{n(50 + rw * .12)} {n(y - .2)}", s=.45, col=roof2)
        y -= rh - 1.2
    # 긴 상륜(구륜·수연)
    b = y + 1
    c.p(f"M46 {n(b)}v-2h8v2z", "#B9A16A", 1)
    c.l(50, b - 2, 50, 3, s=1.5, col="#6B6455")
    _rings(c, 50, b - 4, 9, 1.7, 7, "#6B6455", .9)
    c.c(50, 3.5, 1.3, GOLD, s=.7)


@d
def cheomseong(c):
    st, st2, dk = "#D8CFB3", "#B7AD90", "#7F765D"
    c.shadow(50, 54)
    c.p("M26 104v-3.5h48V104zM29 100.5v-3h42v3z", "#C5BCA1", 1.3)
    # 병 모양 곡선 몸체 27단
    def hw(y):
        t = (97 - y) / 66
        return 8 * (1 - t) ** 1.6 + 10.5
    L = "".join(f"L{n(50 - hw(y))} {y}" for y in range(95, 30, -6))
    R = "".join(f"L{n(50 + hw(y))} {y}" for y in range(31, 96, 6))
    c.p(f"M{n(50 - hw(97))} 97{L}L{n(50 - hw(31))} 31{R}L{n(50 + hw(97))} 97z", st, 2)
    # 오른쪽 그늘
    Rs = "".join(f"L{n(50 + hw(y) * .5)} {y}" for y in range(95, 30, -6))
    Re = "".join(f"L{n(50 + hw(y))} {y}" for y in range(31, 96, 6))
    c.p(f"M{n(50 + hw(97) * .5)} 96.5{Rs}{Re}L{n(50 + hw(97) - .8)} 96.5z", st2, s=0)
    # 줄눈(27단)과 어긋난 세로 줄눈
    dd = ""
    for i in range(1, 27):
        y = 97 - i * 66 / 27
        w = hw(y)
        dd += f"M{n(50 - w)} {n(y)}Q50 {n(y + .9)} {n(50 + w)} {n(y)}"
        m = 2
        for j in range(-m, m + 1):
            x = 50 + (j + (.5 if i % 2 else 0)) * w / (m + .5)
            if abs(x - 50) < w - .6:
                dd += f"M{n(x)} {n(y)}v{n(-66 / 27)}"
    c.p(dd, s=.42, col=dk)
    Ls = "".join(f"L{n(50 - hw(y))} {y}" for y in range(95, 30, -6))
    c.p(f"M{n(50 - hw(97))} 97{Ls}L{n(50 - hw(31))} 31{R}L{n(50 + hw(97))} 97", s=2)
    # 남쪽 창과 사다리
    c.r(45.5, 60, 9, 9, "#4F4A3E", s=1.4)
    c.p("M44 60.5h12M44 69.5h12", s=.9)
    # 정자석
    c.p("M36 31V24H64V31zM36 27.5H64", "#CFC6AA", 1.6)
    c.p("M39 24v-2.5h22V24zM39 31v-7M61 31v-7", "#C4BB9E", 1.1)
    c.p("M32.5 27.5h35", s=1.8)
    # 들꽃
    c.p("M12 102q1-3 0-5M17 104q1-3 2-4M86 104q0-2-1-4", s=.7, col="#5F9A55")
    c.c(12, 96.5, 1.1, "#F2C94C", s=.5)
    c.c(19.2, 99.5, 1, "#E58A9B", s=.5)


@d
def mireuksa(c):
    st, st2, dk = "#BFB7A4", "#9D9583", "#655F50"
    c.shadow(52, 78)
    # 복원된 상태처럼 한쪽만 남은 석탑. 왼쪽이 높고 오른쪽은 낮게 무너진 모습
    c.p("M14 104v-4h74v4z", "#AEA693", 1.4)
    c.blocks(14, 100, 74, 4, 1, 10, s=.4, col=dk)
    # 1층 몸체
    c.p("M20 100V72H82V86L76 90V100z", st, 2)
    c.p("M66 72H82V86L76 90V100H66z", st2, s=0)
    c.p("M20 100V72H82V86L76 90V100z", s=2)
    c.blocks(20, 72, 56, 28, 4, 5, s=.45, col=dk)
    c.p("M26 100V72M36 100V72M60 100V72M70 100V72", s=1, col=dk)
    c.r(43, 82, 11, 18, "#4A453A", s=1.3)
    c.l(48.5, 82, 48.5, 100, s=.5, col="#8A8476")
    c.r(40.5, 79.5, 16, 2.6, st2, s=.9)
    # 옥개석과 위층 — 왼쪽은 6층까지
    def tier(x0, x1, y, h, rx0, rx1, rh):
        c.r(x0, y - h, x1 - x0, h, st, s=1.6)
        c.blocks(x0, y - h, x1 - x0, h, 2, max(2, int((x1 - x0) / 10)), s=.42, col=dk)
        c.p(f"M{n(rx0)} {n(y - h)}v-{n(rh * .4)}L{n(x0 + 3)} {n(y - h - rh)}H{n(x1 - 3)}L{n(rx1)} {n(y - h - rh * .4)}V{n(y - h)}z", st2, s=1.4)
    c.p("M14 72L18 66H84L88 72z", st2, 1.7)
    c.vlines(14, 67, 74, 5, 11, s=.4, col=dk)
    tier(23, 72, 66, 9, 18, 77, 4.5)
    tier(23, 64, 52.5, 7.5, 18, 69, 4)
    tier(24, 56, 41, 6.5, 19, 60, 3.8)
    tier(25, 48, 30.7, 5.5, 20, 51, 3.5)
    tier(26, 41, 21.7, 4.5, 22, 44, 3)
    # 흩어진 돌
    c.p("M84 104l1-4h6l2 4zM6 104l1-3h7l1 3z", st2, 1.1)
    c.p("M16 107l1-2.5h5l1 2.5z", st, .9)


@d
def hwangnyong(c):
    red, red2, wall = "#B9493A", "#8F362B", "#F0E7D0"
    roof, roof2 = "#59666B", "#434F54"
    green = "#5FA08C"
    c.shadow(50, 74)
    c.p("M16 104v-3.5h68V104z", "#CBC4B1", 1.4)
    c.p("M20 100.5v-3h60v3z", "#D8D2C0", 1.3)
    c.r(43, 100.5, 14, 3.5, "#E3DDCC", s=.9)
    c.hlines(43, 100.5, 14, 3.5, 2, s=.45)
    y = 97.5
    rw, bw = 66, 36
    for i in range(9):
        h = 7 if i == 0 else 5.2 - i * .16
        c.r(50 - bw / 2, y - h, bw, h, wall, s=1.1)
        k = 5 if i < 2 else 3
        c.p("".join(f"M{n(50 - bw / 2 + bw * j / (k - 1))} {n(y)}v-{n(h)}" for j in range(k)), s=1.5, col=red)
        if i == 0:
            c.r(45, y - 6.5, 10, 6.5, red2, s=.7)
        y -= h
        c.r(50 - bw / 2 - 1.2, y - 1, bw + 2.4, 1.3, green, s=.6)
        rh = 4.4 - i * .12
        _wroof(c, 50, y - .6, rw, rh + .6, roof, s=1.3)
        y -= rh - .6
        rw -= 4.8
        bw -= 2.7
    c.l(50, y, 50, y - 15, s=1.5, col=GOLD2)
    _rings(c, 50, y - 3, 7, 1.5, 6.5, GOLD2, .9)
    c.c(50, y - 15, 1.5, GOLD, s=.7)
    c.r(7, 97, 10, 7, wall, s=1)
    c.p("M5 97l8-4.5l8 4.5z", roof, 1.1)


@d
def dayan(c):
    br, br2, dk = "#D2B480", "#B39560", "#7F673F"
    c.cloud(78, 24, .8)
    c.shadow(50, 74)
    # 넓은 벽돌 기단
    c.p("M14 104V93H86V104z", "#C9AC7A", 1.8)
    c.blocks(14, 93, 72, 11, 3, 9, s=.42, col=dk)
    c.arch(50, 104, 8, 8, "#5B4A39", s=1)
    y = 93
    w = 46
    heights = (13, 11, 10, 9.5, 9, 8.5, 8)
    for i, h in enumerate(heights):
        w2 = w - 2
        _tz(c, 50, y, w, w2, h, br, s=1.7)
        # 오른쪽 그늘
        c.p(f"M{n(50 + w * .28)} {n(y - .5)}L{n(50 + w2 * .28)} {n(y - h + .5)}H{n(50 + w2 / 2 - .6)}L{n(50 + w / 2 - .8)} {n(y - .5)}z", br2, s=0)
        # 벽돌 줄과 기둥 선
        c.p(f"M{n(50 - w * .29)} {n(y)}L{n(50 - w2 * .29)} {n(y - h)}M{n(50 + w * .29)} {n(y)}L{n(50 + w2 * .29)} {n(y - h)}", s=.45, col=dk)
        c.arch(50, y - 1.2, 4.8 - i * .25, h * .62, "#4F4238", s=.8)
        y -= h
        # 벽돌 내어쌓기 처마
        _tz(c, 50, y + .2, w2 + 3.4, w2 + 1, 1.8, "#E0C794", s=1.1)
        y -= 1.8
        w = w2 - 1.5
    # 표주박 꼭대기
    c.p(f"M{n(50 - w * .55)} {n(y)}Q50 {n(y - 6)} {n(50 + w * .55)} {n(y)}z", br2, 1.3)
    c.c(50, y - 4.8, 2.4, "#C2A36D", s=1.1)
    c.c(50, y - 8, 1.6, br, s=1)


@d
def kairouan(c):
    sd, sd2, dk = "#DDBE86", "#BE9E66", "#8A6E43"
    c.shadow(52, 88)
    # 긴 외벽과 버팀벽
    c.box(8, 76, 86, 28, sd, s=1.9)
    c.crenel(8, 72.5, 86, 5, 22, sd2)
    c.blocks(8, 78, 86, 26, 3, 6, s=.4, col=dk)
    c.p("M52 104V78h5v26zM64 104V78h5v26zM84 104V78h5v26z", sd2, 1.1)
    c.arch(14, 104, 6, 12, "#54493A", s=1)
    c.arch(74, 104, 7, 16, "#54493A", s=1.1)
    # 기도실 골진 돔
    c.r(52, 62, 22, 11, "#E6CB96", s=1.5)
    c.arches(54, 72, 18, 7, 4, "#54493A")
    c.p("M50.5 62L52 59.5H74L75.5 62z", sd2, 1)
    c.dome(63, 59.5, 11, "#EFE1BE", "#D2C197", ribs=7, h=12)
    c.l(63, 47.5, 63, 43, s=1.3, col=GOLD2)
    c.c(63, 44, 1, GOLD, s=.5)
    # 3층 사각 미나렛 — 요새 같은 윤곽
    c.box(14, 36, 28, 40, sd, sd2, sw=.25, s=2)
    c.blocks(14, 36, 28, 40, 5, 3, s=.42, col=dk)
    c.crenel(12.5, 31.5, 31, 6, 7, sd2)
    for yy in (68, 56, 46):
        c.p(_pt(28, yy, 4, 7.5), "#54493A", s=.8)
    c.box(19, 18, 18, 14, "#E6CB96", sd2, sw=.25, s=1.8)
    c.crenel(17.5, 14, 21, 5, 5, sd2)
    c.arches(21, 30, 14, 9, 3, "#54493A")
    c.box(23, 7.5, 10, 7, "#E6CB96", sd2, sw=.25, s=1.5)
    c.p("M22.5 7.5C22.5 1.5 33.5 1.5 33.5 7.5z", "#EFE1BE", 1.5)
    c.p("M25 7Q26 4 28 3.2M31 7Q30 4 28 3.2", s=.5)


@d
def dome_rock(c):
    tile, tile2, gold, gold2 = "#3E7FB0", "#2F6A96", "#EDBE4E", "#CF9A2F"
    m, m2 = "#EDE7D8", "#CFC8B5"
    c.cypress(90, 96, 22, 7)
    c.p("M6 104v-6h88v6z", "#D9D2BF", 1.4)
    c.blocks(6, 98, 88, 6, 1, 14, s=.4, col="#8E8878")
    # 왼쪽 독립 아케이드(콰나티르)
    c.p("M6 98V84H19V98H16.5V88.5A2.8 2.8 0 0 0 11 88.5V98H9.5z", m, 1.2)
    c.r(5, 82.5, 15, 1.8, m2, s=.9)
    # 팔각 몸체: 아래 대리석, 위 푸른 타일
    c.p("M14 98V68L26 64H74L86 68V98z", tile, 2)
    c.p("M74 64L86 68V98H74z", tile2, s=0)
    c.p("M26 64V98M74 64V98", s=1.2)
    c.p("M14.8 98V84H85.2V98z", m, s=0)
    c.p("M74 84H85.2V98H74z", m2, s=0)
    c.p("M14 84H86", s=1)
    c.p("M14 98V68L26 64H74L86 68V98zM26 64V98M74 64V98", s=1.9)
    c.p("M30 91h40M30 94h40", s=.4, col="#8E8878")
    c.vlines(26, 84, 48, 14, 7, s=.4, col="#8E8878")
    # 타일 창
    wnd = ""
    for x in (32, 41, 50, 59, 68, 19, 81):
        wnd += f"M{x - 2.5} 81V73a2.5 2.5 0 0 1 5 0V81z"
    c.p(wnd, "#1F4B6F", s=.8)
    c.p("M26 67.5h48M26 82.5h48M14 71h12M74 71h12", s=.7, col="#E6DFA8")
    c.p("".join(f"M{x} 65v2M{x + 2} 83v1" for x in range(28, 74, 4)), s=.5, col="#E6DFA8")
    # 가운데 현관
    c.p("M44 98V88a6 6 0 0 1 12 0V98z", "#CFC8B5", 1.2)
    c.arch(50, 98, 7, 12, "#3C3226", s=.8)
    # 드럼
    c.r(29, 49, 42, 15, tile, s=1.9)
    c.r(62, 50, 8, 13, tile2, s=0)
    c.arches(31, 63, 38, 11, 11, "#1F4B6F", fill=.6)
    c.p("M29 51.5H71M29 61.5H71", s=.6, col="#E6DFA8")
    # 금빛 돔
    c.p("M27 49C24 24 40 16 50 13C60 16 76 24 73 49z", gold, 2)
    c.p("M58 18C68 23 72 34 70 48.5H60C63 38 62 26 58 18z", gold2, s=0)
    c.p("M36 48C34 34 40 22 50 13M64 48C66 34 60 22 50 13M50 13V48", s=.5, col=gold2)
    c.p("M27 49C24 24 40 16 50 13C60 16 76 24 73 49z", s=2)
    c.l(50, 13, 50, 6, s=1.4, col=gold2)
    c.p("M52.6 3.8a2.7 2.7 0 1 0 0 3.6a2.3 2.3 0 1 1 0-3.6z", gold, .6)


@d
def tikal(c):
    st, st2, dk = "#BDB5A0", "#99917C", "#5E5848"
    # 밀림 위로 솟은 모습
    _bush(c, [(10, 84, 8), (20, 90, 8), (88, 84, 8), (80, 90, 8)], "#5F9A55")
    _bush(c, [(7, 94, 7), (93, 94, 7), (28, 96, 6), (72, 96, 6)], "#6FA85E")
    c.shadow(50, 58)
    # 9단의 가파른 몸체
    y, w = 104, 52
    for i in range(9):
        h = 6.3
        _tz(c, 50, y, w, w - 2, h, st, s=1.4)
        c.p(f"M{n(50 + w * .26)} {n(y - .5)}V{n(y - h + .5)}H{n(50 + (w - 2) / 2 - .5)}L{n(50 + w / 2 - .7)} {n(y - .5)}z", st2, s=0)
        y -= h
        w -= 2.9
    # 가운데 가파른 계단
    c.p("M41.5 104L44.5 47H55.5L58.5 104z", "#D3CCB8", 1.3)
    c.p("".join(f"M{n(50 - (5.5 + (y2 - 47) * .0526))} {y2}h{n(2 * (5.5 + (y2 - 47) * .0526))}" for y2 in range(50, 103, 3)), s=.42, col=dk)
    # 신전 방과 높은 지붕 빗(로프콤)
    c.box(38, 34, 24, 13, st, st2, sw=.25, s=1.7)
    c.r(46.5, 37.5, 7, 9.5, "#3C382E", s=1)
    c.r(36.5, 32.5, 27, 2.4, st2, s=1.1)
    c.p("M40.5 32.5L43 12H57L59.5 32.5z", st, 1.9)
    c.p("M52.5 12H57L59.5 32.5H54z", st2, s=0)
    c.p("M40.5 32.5L43 12H57L59.5 32.5z", s=1.9)
    c.p("M42 26.5h16M43 19h14", s=.7)
    c.p("M45 31v-3h3v3M52 31v-3h3v3M46.5 25v-4.5h7V25zM47 12V8.5h6V12z", "#A69E89", .8)
    c.c(50, 22.5, 1.4, dk, s=0)
    c.birds(12, 30)


@d
def umayyad(c):
    st, st2, dk = "#E2D4B5", "#C4B593", "#857A5F"
    lead = "#8E9AA0"
    # 오른쪽 예수의 미나렛(흰 탑, 뾰족)
    c.box(82, 34, 8, 44, "#F3EEE0", "#D8D2C0", sw=.3, s=1.6)
    c.r(80.5, 33, 11, 2, "#F3EEE0", s=1)
    c.poly([(82, 33), (86, 17), (90, 33)], lead, 1.5)
    c.l(86, 17, 86, 13, s=1.1, col=GOLD2)
    # 왼쪽 신부의 미나렛
    c.box(10, 40, 9, 40, st, st2, sw=.3, s=1.6)
    c.r(8.5, 50, 12, 1.8, st, s=1)
    c.r(11, 30, 7, 10, "#F3EEE0", s=1.3)
    c.r(9.5, 38.5, 10, 1.8, st, s=1)
    c.p("M11 30q3.5-6 7 0z", lead, 1.2)
    # 긴 본당 지붕
    c.p("M12 66L18 58H84L90 66z", lead, 1.7)
    c.p("M18 62h66", s=.5, col="#66727A")
    # 안뜰 아케이드와 벽
    c.box(8, 78, 86, 26, st, s=1.9)
    c.r(8, 66, 86, 12, "#EADDC0", s=1.5)
    c.arches(10, 77.5, 82, 7, 16, "#54493A", fill=.56)
    c.arches(10, 103, 82, 17, 7, "#54493A", fill=.62)
    c.p("M8 86.5h86", s=.6, col=dk)
    # 가운데 금빛 모자이크 익랑
    c.p("M36 104V54L50 44L64 54V104z", "#D7B65A", 1.9)
    c.p("M36 54L50 44L64 54L50 49z", lead, 1.4)
    c.p("M39 57q4 3 3 7M47 54q-3 5 2 7M57 56q-3 3-1 7", s=.8, col="#5F9A63")
    c.p("M39 90V73a3 3 0 0 1 6 0V90zM47 90V73a3 3 0 0 1 6 0V90zM55 90V73a3 3 0 0 1 6 0V90z", "#54493A", s=.7)
    c.arch(50, 104, 10, 12, "#4A3F31", s=1)
    c.p("M36 90.5H64", s=.8)
    # 독수리 돔
    c.r(43, 34, 14, 12, st, s=1.5)
    c.arches(44, 45, 12, 7, 4, "#54493A")
    c.dome(50, 34, 9, lead, "#6F7C83", h=11)
    c.l(50, 23, 50, 18, s=1.2, col=GOLD2)
    # 왼쪽 보물 돔(기둥 위 팔각)
    c.vlines(21, 93, 8, 11, 3, s=1, col="#7A6C50")
    c.r(20, 85, 10, 8, "#7EA67A", s=1.1)
    c.p("M20 85q5-7 10 0z", lead, 1.1)


@d
def dabo(c):
    st, st2, dk = "#D9D3C0", "#B8B19C", "#716B5A"
    c.shadow(50, 66)
    # 기단과 네 방향 계단
    c.p("M18 104v-8h64v8z", st, 1.7)
    c.blocks(18, 96, 64, 8, 2, 8, s=.42, col=dk)
    c.p("M41 104V96H59V104z", "#E4DFCF", 1.2)
    c.hlines(41, 96, 18, 8, 3, s=.5, col=dk)
    c.p("M41 104l-2-1V97l2-1M59 104l2-1V97l-2-1", s=1)
    # 돌사자
    c.p("M23 96v-4q0-3 3-3q3 0 3 3v1h3v3z", st2, 1)
    c.c(25.5, 87.8, 1.8, st, s=.8)
    # 1층: 네 돌기둥과 가운데 기둥
    c.r(33, 78, 34, 18, "#7E7867", s=1.3)
    c.r(47, 78, 6, 18, st2, s=.9)
    for x in (33, 42, 54, 63):
        c.r(x, 78, 4, 18, st, s=1.2)
    # 공포 받침과 네모 지붕
    c.p("M31 78v-2h38v2zM33 76l-2-2h38l-2 2z", st2, 1)
    _sroof(c, 50, 74, 54, 5, st)
    c.p("M32 71h36", s=.4, col=dk)
    # 네모 난간
    c.p("M31 69h38M31 65h38", s=1)
    c.p("M31 69V63M37 69V65M43 69V65M50 69V63M57 69V65M63 69V65M69 69V63", s=1.1)
    # 팔각 몸돌(대나무 마디 기둥)
    c.r(37, 56, 26, 13, "#7E7867", s=1.2)
    c.p("M38 56h4v13h-4zM44 56h4v13h-4zM52 56h4v13h-4zM58 56h4v13h-4z", st, .9)
    c.p("M38 62.5h4M44 62.5h4M52 62.5h4M58 62.5h4", s=1.2)
    c.p("M36 56h28l-2-2H38z", st2, 1)
    # 팔각 난간과 연꽃 받침
    c.p("M36 54V50M43 54V50M50 54V50M57 54V50M64 54V50M36 50.5h28", s=.9)
    c.p("M37 50q3-3 6 0q3-3 7 0q4-3 7 0q3-3 6 0L60 47H40z", st, 1)
    # 위 팔각 기둥과 지붕
    c.r(41, 39, 18, 8, "#7E7867", s=1.1)
    c.p("M41 39h3v8h-3zM48.5 39h3v8h-3zM56 39h3v8h-3z", st, .8)
    _sroof(c, 50, 39, 34, 5.5, st)
    c.p("M38 35.8h24", s=.4, col=dk)
    # 상륜
    c.p("M45.5 33.5v-1.8h9v1.8z", st2, 1)
    c.p("M46 31.7q4-4.5 8 0z", st, 1)
    c.c(50, 26, 2.3, st, s=1)
    c.p("M45.5 23h9l-2-1.5h-5z", st2, .9)
    c.c(50, 19.5, 1.7, st, s=.9)
    c.l(50, 18, 50, 12, s=1.3)


@d
def todaiji(c):
    wood, wall, roof, roof2 = "#6A4A36", "#EFE6D2", "#59625F", "#454D4B"
    c.shadow(50, 88)
    c.r(8, 100, 84, 4, "#BEB7A5", s=1.3)
    # 아래층
    c.r(12, 76, 76, 24, wall, s=1.8)
    c.r(70, 77, 17, 22, "#D8CDB6", s=0)
    c.p("M23 100V76M34 100V76M66 100V76M77 100V76", s=1.8, col=wood)
    c.p("M12 90h76", s=1.3, col=wood)
    c.p("M14 78h7v10h-7zM25 78h7v10h-7zM68 78h7v10h-7zM79 78h7v10h-7z", wood, s=0)
    c.vlines(14, 78, 7, 10, 2, s=.5, col=wall)
    c.vlines(25, 78, 7, 10, 2, s=.5, col=wall)
    c.vlines(68, 78, 7, 10, 2, s=.5, col=wall)
    # 가운데 큰 문
    c.r(38, 78, 24, 22, wood, s=1.3)
    c.p("M50 78V100M44 78V100M56 78V100", s=.6, col=wall)
    # 아래 처마
    _wroof(c, 50, 76, 92, 11, roof, rid=.34)
    c.p("M18 73Q50 75.5 82 73", s=.6, col=roof2)
    # 가운데 금빛 창과 곡선 박공(가라하후)
    c.p("M34 74Q42 73 44 67Q50 62 56 67Q58 73 66 74z", roof, 1.5)
    c.p("M45 72v-4h10v4z", GOLD, 1)
    c.vlines(45, 68, 10, 4, 3, s=.5)
    c.p("M44 67Q50 62 56 67", s=1, col=GOLD2)
    # 위층 벽과 공포
    c.r(18, 54, 64, 12, wall, s=1.7)
    c.p("M30 66V54M42 66V54M58 66V54M70 66V54", s=1.6, col=wood)
    c.p("M18 60h64", s=.9, col=wood)
    c.p("M20 61h8v3h-8zM32 61h8v3h-8zM60 61h8v3h-8zM72 61h8v3h-8z", wood, s=0)
    c.r(16, 51.5, 68, 2.6, wood, s=.9)
    # 큰 지붕
    _wroof(c, 50, 52, 94, 30, roof, s=2, rid=.26)
    c.p("M30 23Q22 40 12 46M70 23Q78 40 88 46", s=.9, col=roof2)
    c.p("M38 23Q34 38 28 47M50 23V49M62 23Q66 38 72 47M44 23L40 48M56 23L60 48", s=.45, col=roof2)
    c.p("M24 22.5h52", s=2.4)
    # 금빛 치미
    c.p("M24 24Q22 19 26 17Q26 20 28 21.5V24zM76 24Q78 19 74 17Q74 20 72 21.5V24z", GOLD, 1.1)
    # 등롱과 사슴
    c.p("M47 104v-5h6v5zM45.5 99l4.5-3l4.5 3z", "#7C7A5F", 1)
    c.p("M14 104l.5-5h6l1 5M14 99.5q3-1.5 6.5-.5l1.5-3.5l2 .5l-1.5 4.5", "#B5895B", .8)


@d
def kailasa(c):
    st, st2, dk = "#98826E", "#7A6654", "#4B3E33"
    rock, rock2 = "#C6B29C", "#A8947E"
    # 뒤와 양옆을 두른 깎아낸 바위 절벽
    c.p("M6 104V58L14 54L24 58L34 52L44 56H70L78 52L88 56L94 60V104z", rock, 1.8)
    c.p("M72 64h22M74 74h20", s=.6, col=rock2)
    c.shadow(50, 72)
    # 기단: 코끼리 띠
    c.box(26, 84, 54, 20, st, st2, sw=.2, s=1.8)
    c.p("M26 90h54M26 100h54", s=.8, col=dk)
    c.p("".join(f"M{x} 100v-5q0-3 4-3t4 3v5h-1.6v-2h-4.8v2z" for x in range(30, 74, 9)), st2, .7)
    # 앞 만다파
    c.box(44, 70, 30, 14, "#A28C77", st2, sw=.25, s=1.5)
    c.arches(46, 84, 26, 9, 5, dk)
    c.p("M42 70L46 65H72L76 70z", st2, 1.3)
    # 비마나: 드라비다식 층단 탑
    y, w = 70, 36
    for i in range(5):
        c.box(40 - w / 2, y - 6.5, w, 6.5, st, st2, sw=.25, s=1.4)
        c.windows(40 - w / 2 + 1, y - 5.5, w - 2, 4, max(3, int(w / 6)), 1, dk, fill=.6)
        c.r(40 - w / 2 - 1.2, y - 7.7, w + 2.4, 1.8, st2, s=.9)
        y -= 7.7
        w -= 5.4
    c.p(f"M31.5 {n(y)}C31.5 {n(y - 11)} 48.5 {n(y - 11)} 48.5 {n(y)}z", st, 1.8)
    c.p(f"M36 {n(y)}Q36 {n(y - 6)} 40 {n(y - 8.2)}M44 {n(y)}Q44 {n(y - 6)} 40 {n(y - 8.2)}", s=.6, col=dk)
    c.c(40, y - 9.5, 1.8, st2, s=1)
    c.l(40, y - 11, 40, y - 15, s=1.2)
    # 깃발 기둥과 코끼리상
    c.r(11, 62, 4.6, 42, st, s=1.4)
    c.p("M11 72h4.6M11 86h4.6", s=.6, col=dk)
    c.p("M9.5 62h7.6l-1.5-2.5h-4.6z", st2, 1)
    c.l(13.3, 59.5, 13.3, 53, s=1.2)
    c.p("M18 104V94Q18 89 23 89Q27 89 27.5 93Q29 97 27.5 104H26V99H24V104H20V100H19V104z", st2, 1.1)
    c.c(25.2, 92, .5, O, s=0)


@d
def seokguram(c):
    st, st2, dk = "#D8D3C4", "#B3AD9B", "#6F6A5A"
    c.sun(84, 20, 6)
    # 토함산 흙 봉분 위에 소나무
    c.p("M6 104C12 66 30 34 50 34C70 34 88 66 94 104z", "#86B96E", 1.9)
    c.p("M62 38C74 48 86 72 90 104H94C88 66 72 40 62 38z", "#6FA85E", s=0)
    c.p("M18 76q4-2 8 0M12 92q4-2 7 0M72 60q4-2 7 0M34 48q3-2 6 0", s=.7, col="#5F9A55")
    c.p("M24 56Q24 50 21 44M21 48Q17 46 15 46", s=1.5, col="#8A6C50")
    c.e(21, 42, 7, 3.2, "#5F9A63", s=1)
    c.e(14, 45, 4, 2, "#5F9A63", s=.9)
    # 돌 아치 입구
    c.p("M18 104V78A28 28 0 0 1 74 78V104z", st, 2)
    d_ = ""
    for i in range(1, 12):
        a = math.pi * i / 12
        d_ += f"M{n(46 - 28 * math.cos(a))} {n(78 - 28 * math.sin(a))}L{n(46 - 23 * math.cos(a))} {n(78 - 23 * math.sin(a))}"
    c.p(d_ + "M18 86h5M18 95h5M69 86h5M69 95h5", s=.7, col=dk)
    # 어두운 굴 안
    c.p("M23 104V78A23 23 0 0 1 69 78V104z", "#47545F", 1.5)
    # 둥근 천장 돌 줄
    c.p("M33 62A18 18 0 0 1 59 62M28 76A18 18 0 0 1 36 62M64 76A18 18 0 0 0 56 62", s=.6, col="#6A7883")
    # 광배와 본존불
    c.c(46, 66, 10.5, "#EFE3BE", s=1.2)
    c.c(46, 66, 7.8, "none", s=.5)
    c.p("M36 100C36 84 40 79 46 79C52 79 56 84 56 100z", "#F4F0E4", 1.4)
    c.p("M42 82Q44 90 40 96M50 81Q50 88 56 90M46 80v4", s=.5, col=dk)
    c.c(46, 72, 5.4, "#F4F0E4", s=1.3)
    c.c(46, 66.2, 2.2, "#F4F0E4", s=1)
    c.p("M43.6 72h1.6M46.8 72h1.6M44.8 74.8q1.2.6 2.4 0", s=.5)
    # 연화대
    c.p("M32 100q3.5-3 7 0q3.5-3 7 0q3.5-3 7 0q3.5-3 7 0v4H32z", st, 1.2)
    # 입구 팔각 돌기둥
    c.r(14, 68, 4.5, 36, st2, s=1.3)
    c.r(73.5, 68, 4.5, 36, st2, s=1.3)
    c.r(13, 66, 6.5, 2.2, st, s=.9)
    c.r(72.5, 66, 6.5, 2.2, st, s=.9)


def _horseshoe(c, x, y, r, stripes=9):
    """붉은·크림 줄무늬 말굽 아치. (x, y)는 아치 중심."""
    a0, a1 = -math.pi * 1.2, math.pi * .2
    p = lambda a, q: f"{n(x + q * math.cos(a))} {n(y + q * math.sin(a))}"
    ri = r * .62
    c.p(f"M{p(a0, r)}A{n(r)} {n(r)} 0 1 1 {p(a1, r)}L{p(a1, ri)}A{n(ri)} {n(ri)} 0 1 0 {p(a0, ri)}z", "#F2E5C7", 1.3)
    dd = ""
    for i in range(0, stripes, 2):
        u, v = a0 + (a1 - a0) * i / stripes, a0 + (a1 - a0) * (i + 1) / stripes
        dd += f"M{p(u, r)}L{p(v, r)}L{p(v, ri)}L{p(u, ri)}z"
    c.p(dd, "#B5473A", s=0)
    c.p(f"M{p(a0, ri)}A{n(ri)} {n(ri)} 0 1 1 {p(a1, ri)}V104H{n(x - ri * .95)}z", "#3F3429", 1)


@d
def cordoba(c):
    sd, sd2, dk = "#E2C690", "#C4A66E", "#8C7247"
    # 뒤의 대성당 몸체
    c.box(36, 34, 36, 30, "#E9D9B2", sd2, sw=.25, s=1.7)
    c.p("M34 34L54 22L74 34z", "#B5613F", 1.6)
    c.p("M40 62V42a3 3 0 0 1 6 0V62zM50 62V42a3 3 0 0 1 6 0V62zM60 62V42a3 3 0 0 1 6 0V62z", "#54493A", s=.7)
    # 긴 기와지붕
    c.p("M8 62L12 54H88L94 62z", "#C06D49", 1.6)
    c.p("M18 62L21 54M30 62L32 54M42 62L43 54M54 62V54M66 62L65 54M78 62L76 54", s=.6, col="#8C4C31")
    # 종탑(옛 미나렛)
    c.box(12, 28, 13, 34, sd, sd2, sw=.3, s=1.7)
    c.p("M18.5 54V46M15 40h7v-5a3.5 3.5 0 0 0-7 0z", "#54493A", s=.6)
    c.r(10.5, 26, 16, 2.4, sd2, s=1.1)
    c.box(14, 14, 9, 12, "#EDDDB6", sd2, sw=.3, s=1.5)
    c.arch(18.5, 24, 4, 8, "#54493A", s=.6)
    c.p("M13 14l5.5-5l5.5 5z", "#B98C4A", 1.3)
    c.l(18.5, 9, 18.5, 3, s=1.4, col=GOLD2)
    c.c(18.5, 3, 1.1, GOLD, s=.6)
    # 앞 벽과 줄무늬 말굽 아치
    c.box(8, 62, 86, 42, sd, s=2)
    c.crenel(8, 58.5, 86, 4.5, 21, sd2)
    c.blocks(8, 64, 86, 8, 2, 9, s=.4, col=dk)
    for x in (22, 46, 70):
        _horseshoe(c, x, 84, 10)
    c.p("M34 104V72M58 104V72", s=.9, col=dk)
    # 오렌지 나무
    c.p("M88 104v-6", s=1.4, col="#8A6C50")
    c.c(88, 95, 5, "#5F9A63", s=1)
    c.p("M86 94h.1M90 92.5h.1M88.5 97h.1", s=1.5, col="#ED9A3A")


def _bell(x, y, r, h):
    """작은 종 모양 스투파 경로."""
    return f"M{n(x - r)} {n(y)}Q{n(x - r)} {n(y - h)} {n(x)} {n(y - h)}Q{n(x + r)} {n(y - h)} {n(x + r)} {n(y)}z"


@d
def borobudur(c):
    st, st2, dk = "#8E8D80", "#6F6E62", "#4A4A41"
    c.p("M8 84Q30 60 50 50Q70 60 92 84z", "#C8D6CF", 1)
    c.palm(90, 104, 22)
    c.shadow(50, 90)
    # 여섯 층 네모 테라스
    y, w = 104, 86
    for i in range(6):
        h = 6.6 - i * .2
        c.r(50 - w / 2, y - h, w, h, st if i % 2 == 0 else "#999789", s=1.5)
        k = int(w / 8.5)
        cw = w / k
        c.p("".join(f"M{n(50 - w / 2 + cw * (j + .25))} {n(y - .7)}v-{n(h * .55)}h{n(cw * .5)}v{n(h * .55)}z" for j in range(k)), dk, s=0)
        y -= h
        w -= 9.8
    # 계단
    c.p("M45 104L47.5 69H52.5L55 104z", "#AAA898", 1)
    c.p("".join(f"M{n(46 + (104 - q) * .05)} {q}h{n(8 - (104 - q) * .1)}" for q in range(74, 103, 4)), s=.4, col=dk)
    # 세 원형 단과 종 스투파
    for w2, k2, h2, r2 in ((36, 8, 5, 2.2), (28, 6, 5, 2.2), (20, 4, 5, 2.2)):
        c.r(50 - w2 / 2, y - 2.2, w2, 2.2, "#A3A192", s=1.2, rx=1)
        y -= 2.2
        c.p("".join(_bell(50 - w2 / 2 + 2.6 + (w2 - 5.2) * j / (k2 - 1), y, r2, h2) for j in range(k2)), "#A9A798", .8)
        c.p("".join(f"M{n(50 - w2 / 2 + 2.6 + (w2 - 5.2) * j / (k2 - 1))} {n(y - h2)}v-1.4" for j in range(k2)), s=.7)
        y -= 3.2
    # 중앙 큰 스투파
    c.p(_bell(50, y + 1.5, 8.5, 16), st, 1.7)
    c.p(f"M47 {n(y - 14.5)}v-2.2h6v2.2z", st2, 1)
    c.p(f"M48.3 {n(y - 16.7)}L50 {n(y - 26)}L51.7 {n(y - 16.7)}z", st, 1.1)
    c.p(f"M45 {n(y - 3)}q5 2 10 0", s=.5, col=dk)


@d
def aachen(c):
    st, st2, dk = "#E3DBC4", "#C2BAA2", "#7F7963"
    sl, sl2 = "#5D6878", "#4A5462"
    c.shadow(52, 84)
    # 서쪽 탑과 뾰족 첨탑
    c.box(11, 34, 15, 70, st, st2, sw=.28, s=1.8)
    c.p("M13 34L18.5 6L24 34z", sl, 1.6)
    c.p("M18.5 6V3", s=1.2)
    c.p("M15 56V40a3.5 3.5 0 0 1 7 0V56zM16 78V66a2.5 2.5 0 0 1 5 0V78z", WIN, s=.8)
    c.arch(18.5, 104, 7, 12, "#4F4238", s=1)
    c.p("M11 60h15M11 84h15", s=.8)
    # 고딕 유리 성가대석(오른쪽 위로 높게)
    c.r(60, 34, 26, 50, st, s=1.8)
    c.p("M64 80V46Q64 40 66.5 38Q69 40 69 46V80zM71 80V46Q71 40 73.5 38Q76 40 76 46V80zM78 80V46Q78 40 80.5 38Q83 40 83 46V80z", "#7FB0CF", 1)
    c.p("M64 52h5M71 52h5M78 52h5M64 62h5M71 62h5M78 62h5M64 72h5M71 72h5M78 72h5M66.5 40v40M73.5 40v40M80.5 40v40", s=.45)
    c.p("M58 34L73 14L88 34z", sl, 1.8)
    c.p("M62 30h22M66 25h14M73 14V8", s=.6, col="#D5D0C4")
    c.c(73, 8, 1.2, GOLD, s=.6)
    c.p("M60 34V26M86 34V26M85 26l1-4l1 4M59 26l1-4l1 4", s=1)
    c.r(60, 84, 30, 20, st, s=1.7)
    c.r(78, 85, 11, 18, st2, s=0)
    c.arches(62, 102, 24, 12, 3, "#54493A")
    # 카롤링거 팔각당과 16면 돔
    c.p("M24 104V62L32 56H56L64 62V104z", "#D8CFB6", 2)
    c.p("M56 56L64 62V104H56z", st2, s=0)
    c.p("M32 56V104M56 56V104", s=1.1)
    c.p("M24 104V62L32 56H56L64 62V104z", s=2)
    c.blocks(32, 58, 24, 46, 5, 3, s=.4, col=dk)
    c.p("M44 100V82a5 5 0 0 0-5 5V100zM44 82a5 5 0 0 1 5 5V100H44z", "#4F4238", s=.8)
    c.p("M36 76V67a2.5 2.5 0 0 1 5 0V76zM47 76V67a2.5 2.5 0 0 1 5 0V76z", WIN, s=.7)
    c.p("M26 90V72a2 2 0 0 1 4 0V90zM58 90V72a2 2 0 0 1 4 0V90z", WIN, s=.6)
    c.r(29, 52, 30, 4, st, s=1.3)
    c.p("M27 52L33 32Q44 26 55 32L61 52z", sl, 2)
    c.p("M36 52L38 29M44 52V27.5M52 52L50 29M30 45L58 45", s=.8, col=GOLD)
    c.p("M41 28h6v-5h-6z", st, 1.2)
    c.p("M40 23q4-5 8 0z", sl, 1)
    c.l(44, 20, 44, 14, s=1.3, col=GOLD2)
    c.p("M42.2 16.5h3.6", s=1, col=GOLD2)


@d
def prambanan(c):
    st, st2, dk = "#8F8A7F", "#716D63", "#46433B"
    def tower(x, base, w, h, k, sw, qs=(-.5, .5)):
        """뾰족한 층단 힌두 탑. 층마다 작은 종 꼭지를 올린다."""
        c.box(x - w / 2, base - h * .32, w, h * .32, st, st2, sw=.25, s=sw)
        c.arch(x, base, w * .3, h * .22, dk, s=1)
        y = base - h * .32
        step = h * .68 / k
        body, knobs = "", ""
        for i in range(k):
            ww = w * (1 - .92 * i / k) + 1.5
            w2 = w * (1 - .92 * (i + 1) / k) + 1.5
            body += f"M{n(x - ww / 2)} {n(y)}L{n(x - w2 / 2)} {n(y - step * .78)}H{n(x - w2 / 2 - .9)}L{n(x - w2 / 2)} {n(y - step)}H{n(x + w2 / 2)}L{n(x + w2 / 2 + .9)} {n(y - step * .78)}H{n(x + w2 / 2)}L{n(x + ww / 2)} {n(y)}z"
            for q in qs:
                knobs += _bell(x + q * w2 * .94, y - step * .78, max(1, ww * .05), step * .55)
            y -= step
        c.p(body, st, sw * .75)
        c.p(knobs, "#A5A094", .5)
        c.p(_bell(x, y, w * .13, step * 1.1), st, sw * .75)
        c.l(x, y - step * 1.1, x, y - step * 1.7, s=1.1)
    c.shadow(50, 88)
    c.palm(92, 104, 20)
    tower(17, 92, 18, 44, 5, 1.5, (-.5, .5))
    tower(80, 92, 18, 44, 5, 1.5, (-.5, .5))
    c.p("M6 104V92H92V104z", "#7F7B71", 1.8)
    c.blocks(6, 92, 86, 12, 2, 7, s=.42, col=dk)
    c.p("M40 104V92H60V104z", "#A19C90", 1.3)
    c.hlines(40, 92, 20, 12, 4, s=.5, col=dk)
    tower(50, 92, 32, 78, 7, 1.8)


@d
def samarra(c):
    br, br2, ramp, dk = "#D2AE78", "#B28F5C", "#E6CB98", "#7F6540"
    c.palm(12, 104, 24)
    c.shadow(50, 80)
    # 네모 기단: 벽의 아치 벽감
    c.box(16, 92, 68, 12, br, br2, sw=.2, s=1.9)
    c.arches(18, 103, 64, 8, 13, dk, fill=.58)
    c.p("M45 104V92H55V104z", ramp, 1)
    def hw(y):
        return 29 - (92 - y) * .295
    # 민벽돌 원뿔을 오른쪽으로 오르며 다섯 바퀴 도는 나선 경사로
    y, H, S = 92, 12, 4
    while y - H > 24:
        a0, ytop = hw(y), y - H
        a1 = a0 - 1.6
        c.p(f"M{n(50 - a0)} {y}L{n(50 + a0)} {y - S}L{n(50 + a1)} {ytop - S}L{n(50 - a1)} {ytop}z", br, 1.7)
        c.p(f"M{n(50 + a0 * .42)} {n(y - S * .71)}L{n(50 + a0)} {y - S}L{n(50 + a1)} {ytop - S}L{n(50 + a1 * .42)} {n(ytop - S * .71)}z", br2, s=0)
        c.p(f"M{n(50 - a1)} {ytop}L{n(50 + a1)} {ytop - S}l-.2 2.8L{n(50 - a1 + .2)} {ytop + 2.8}z", ramp, .8)
        dd = "".join(f"M{n(50 - a1 + (a1 * 2) * t)} {n(y - S * t - 2.6)}h3" for t in (.15, .5, .82))
        dd += "".join(f"M{n(50 - a1 + (a1 * 2) * t)} {n(y - S * t - 5.8)}h3" for t in (.32, .68))
        c.p(dd, s=.5, col=dk)
        y -= H
    # 꼭대기 둥근 원통과 얕은 벽감
    t = y - S / 2
    D_ = f"M41 {n(t + 1)}V{n(t - 11)}A9 2 0 0 1 59 {n(t - 11)}V{n(t + 1)}A9 2 0 0 1 41 {n(t + 1)}z"
    c.p(D_, br, s=1.7)
    c.p(f"M54 {n(t - 12.4)}A9 2 0 0 1 59 {n(t - 11)}V{n(t + 1)}A9 2 0 0 1 54 {n(t + 2.4)}z", br2, s=0)
    c.p(D_, s=1.7)
    c.arches(43, t + 1.6, 14, 8, 4, dk)
    c.e(50, t - 11, 9, 2, ramp, s=1.1)
    c.people(50 - hw(y) + 2, y, 1)


@d
def uxmal(c):
    st, st2, dk = "#E4DEC8", "#C3BDA5", "#6F6A58"
    _bush(c, [(9, 92, 6), (17, 97, 6), (91, 92, 6)], "#6FA85E")
    c.shadow(50, 76)
    # 타원 평면이라 둥글게 흐르는 몸체
    c.p("M14 104C18 94 26 60 34 34H66C74 60 82 94 86 104z", st, 2)
    c.p("M68 104H86C82 94 74 60 66 34H60C63 60 66 88 68 104z", st2, s=0)
    c.p("M14 104C18 94 26 60 34 34H66C74 60 82 94 86 104z", s=2)
    dd = ""
    for y in range(44, 103, 6):
        t = (104 - y) / 70
        hw = 36 - 20 * t ** .85
        dd += f"M{n(50 - hw)} {y}Q50 {n(y + 5 * (1 - t) + 1)} {n(50 + hw)} {y}"
    c.p(dd, s=.6, col=dk)
    c.p("M22 96h8M30 80h6M24 86h4M64 74h5M70 90h6", s=.9, col="#A6A98C")
    # 아주 가파른 계단
    c.p("M41 104L45 40H55L59 104z", "#F0EBD8", 1.4)
    c.p("".join(f"M{n(50 - (5 + (q - 40) * .0625))} {q}h{n(2 * (5 + (q - 40) * .0625))}" for q in range(43, 103, 3)), s=.42, col=dk)
    c.p("M41 104L45 40M59 104L55 40", s=1.5)
    # 위 신전: 체네스 양식 가면 문
    c.box(32, 20, 36, 15, st, st2, sw=.2, s=1.8)
    c.r(30, 34, 40, 2.4, st2, s=1.1)
    c.r(30, 18, 40, 2.6, st2, s=1.2)
    c.p("M41 34V25h3v-2h12v2h3v9z", "#8D8A77", 1.1)
    c.p("M45 34V26h10v8z", "#3C382E", .9)
    c.p("M41.5 22.5h4v2h-4zM54.5 22.5h4v2h-4z", "#3C382E", s=0)
    c.p("M43 18v-2.5M47 18v-2.5M53 18v-2.5M57 18v-2.5M35 18v-2.5M65 18v-2.5", s=1)
    c.p("M34 24h5v2h-5v3h5M61 24h5v2h-5v3h5", s=.7, col=dk)
    c.sun(84, 22, 5)
    # 이구아나
    c.p("M26 104q3-3 8-2.2l3-1l.5 1.2l-3 2z", "#7E9A63", .7)


@d
def chichen(c):
    li, da, dk = "#E0D8BB", "#BDB498", "#6F6A58"
    c.cloud(82, 20, .8)
    c.shadow(50, 88)
    # 모서리에서 본 9단: 왼쪽 면 밝게, 오른쪽 면 어둡게
    S = .19
    L, R = "", ""
    for i in range(9):
        a0 = 42 - i * 3.1
        a1 = a0 - 1.5
        y0 = 97 - i * 7
        y1 = y0 - 7
        L += f"M{n(50 - a0)} {n(y0)}L50 {n(y0 + a0 * S)}V{n(y1 + a1 * S)}L{n(50 - a1)} {n(y1)}z"
        R += f"M{n(50 + a0)} {n(y0)}L50 {n(y0 + a0 * S)}V{n(y1 + a1 * S)}L{n(50 + a1)} {n(y1)}z"
    c.p(L, li, 1.4)
    c.p(R, da, 1.4)
    # 네 면 계단 중 보이는 두 면
    for sg, f in ((-1, "#F0EAD2"), (1, "#D2CAAC")):
        bx, by = 50 + sg * 21, 97 + 21 * S
        tx, ty = 50 + sg * 6.5, 34 + 6.5 * S
        c.p(f"M{n(bx - 7.5)} {n(by + sg * 7.5 * S)}L{n(tx - 2.6)} {n(ty + sg * 2.6 * S)}L{n(tx + 2.6)} {n(ty - sg * 2.6 * S)}L{n(bx + 7.5)} {n(by - sg * 7.5 * S)}z", f, 1.3)
        dd = ""
        for j in range(1, 16):
            t = j / 16
            xx, yy, w = bx + (tx - bx) * t, by + (ty - by) * t, 7.5 + (2.6 - 7.5) * t
            dd += f"M{n(xx - w)} {n(yy + sg * w * S)}L{n(xx + w)} {n(yy - sg * w * S)}"
        c.p(dd, s=.42, col=dk)
    # 깃털 뱀 머리
    c.p("M15 101q-3-1-4 1.5q2 2.5 6 2l3-1v-3z", "#8FA877", 1)
    c.c(13.5, 101.8, .5, O, s=0)
    # 정상 신전
    c.p("M38 20V35L50 37V22z", li, 1.7)
    c.p("M62 20V35L50 37V22z", da, 1.7)
    c.p("M41.5 36V26L46.5 27V36.5z", "#3C382E", .8)
    c.p("M58.5 36V26L53.5 27V36.5z", "#3C382E", .8)
    c.p("M36.5 20L50 22.5L63.5 20L50 17.5z", "#CFC7A8", 1.5)
    c.p("M38 24L50 26L62 24", s=.6, col=dk)


@d
def brihadisvara(c):
    st, st2, dk = "#D9BE8E", "#B79C6C", "#7C6540"
    c.shadow(50, 84)
    # 왼쪽 난디(소) 정자
    c.r(6, 88, 17, 16, "#E4CDA0", s=1.4)
    c.p("M4.5 88L14.5 81L24.5 88z", st2, 1.3)
    c.p("M9 104V92h11v12z", "#6F5C45", .8)
    c.p("M10 103v-4q0-2 3-2h3l2-2l1 1v7z", "#3F3A33", s=0)
    # 오른쪽 낮은 만다파
    c.box(70, 86, 24, 18, st, st2, sw=.3, s=1.5)
    c.r(68.5, 84, 27, 2.4, st2, s=1.1)
    c.vlines(70, 86, 24, 18, 4, s=.7, col=dk)
    # 2층 벽체와 벽감
    c.box(24, 72, 52, 32, st, st2, sw=.22, s=1.9)
    c.p("M24 88H76", s=1)
    c.r(22.5, 70, 55, 2.6, st2, s=1.2)
    c.p("M29 86V77h5v9zM38 86V77h5v9zM47 86V77h6v9zM57 86V77h5v9zM66 86V77h5v9z", "#6F5C45", s=.6)
    c.p("M29 102V92h5v10zM38 102V92h5v10zM57 102V92h5v10zM66 102V92h5v10z", "#6F5C45", s=.6)
    c.arch(50, 104, 8, 12, "#3F3429", s=1)
    # 13층 곧은 피라미드 탑
    y, w = 70, 46
    body, nich, sh = "", "", ""
    for i in range(13):
        h = 4.2 - i * .05
        ww = w - 2.3
        body += f"M{n(50 - w / 2)} {n(y)}v{n(-h * .72)}l1.3 {n(-h * .28)}h{n(w - 2.6)}l1.3 {n(h * .28)}v{n(h * .72)}z"
        sh += f"M{n(50 + w * .22)} {n(y - .5)}v{n(-h + 1)}H{n(50 + w / 2 - 1)}V{n(y - .5)}z"
        k = max(3, int(w / 10))
        for j in range(k):
            xx = 50 - w / 2 + (j + .5) * w / k
            nich += f"M{n(xx - .9)} {n(y - .7)}v{n(-h * .5)}h1.8v{n(h * .5)}z"
        y -= h
        w = ww - .5 if i % 2 else ww
    c.p(body, st, 1.2)
    c.p(sh, st2, s=0)
    c.p(nich, dk, s=0)
    c.p(f"M28 70L{n(50 - w / 2)} {n(y)}M72 70L{n(50 + w / 2)} {n(y)}", s=1.7)
    # 팔각 돔과 금빛 칼라샤
    c.p(f"M{n(50 - w / 2 - 2)} {n(y + .5)}C{n(50 - w / 2 - 2)} {n(y - 9)} {n(50 + w / 2 + 2)} {n(y - 9)} {n(50 + w / 2 + 2)} {n(y + .5)}z", st, 1.7)
    c.p(f"M50 {n(y - 7)}V{n(y + .5)}M45 {n(y + .5)}Q45 {n(y - 4)} 50 {n(y - 7)}M55 {n(y + .5)}Q55 {n(y - 4)} 50 {n(y - 7)}", s=.5, col=dk)
    c.p(f"M47.5 {n(y - 7)}Q46 {n(y - 10)} 50 {n(y - 15)}Q54 {n(y - 10)} 52.5 {n(y - 7)}z", GOLD, 1)


@d
def mont_michel(c):
    rock, rock2, st, st2, dk = "#A8A08E", "#8A8272", "#CFC6B0", "#AFA690", "#6E6858"
    sl = "#5A6476"
    # 밀물 갯벌
    c.water(4, 98, 92, 11, "#A7D3DF")
    # 바위섬
    c.p("M12 100C20 92 24 76 34 64L66 62C72 74 82 90 90 100z", rock, 2)
    c.p("M66 62C72 74 82 90 90 100H72C70 86 66 74 60 63z", rock2, s=0)
    # 수도원 고딕 본당과 메르베유
    c.r(30, 44, 42, 22, st, s=1.8)
    c.r(60, 45, 11, 20, st2, s=0)
    c.p("M36 66V44M44 66V44M52 66V44M60 66V44M66 66V44", s=.8, col=dk)
    c.p("M32 62V50a2 2 0 0 1 4 0V62zM40 62V50a2 2 0 0 1 4 0V62zM48 62V50a2 2 0 0 1 4 0V62zM56 62V50a2 2 0 0 1 4 0V62zM63 62V50a2 2 0 0 1 3 0V62z", WIN, s=.5)
    c.p("M36 66v-3M44 66v-3M52 66v-3M60 66v-3", s=1)
    c.p("M28 44L36 36H66L74 44z", sl, 1.8)
    c.p("M34 40h34", s=.5, col="#7B8598")
    # 첨탑과 금빛 미카엘
    c.r(44.5, 28, 11, 9, st, s=1.5)
    c.arches(45.5, 36, 9, 5, 3, WIN)
    c.p("M43.5 28L50 9L56.5 28z", sl, 1.7)
    c.p("M47 20h6M46 24h8M50 9V4", s=.5, col="#D5D0C4")
    c.l(50, 9, 50, 4, s=1.2)
    c.c(50, 3.5, 1.5, GOLD, s=.7)
    # 층층이 쌓인 마을 집
    def house(x, y, w, h):
        c.r(x, y, w, h, "#D7CDB5", s=1.1)
        c.p(f"M{n(x - 1)} {n(y)}L{n(x + w / 2)} {n(y - 4.5)}L{n(x + w + 1)} {n(y)}z", sl, 1.1)
    for x, y, w, h in ((30, 72, 9, 8), (40, 74, 8, 7), (50, 72, 9, 9), (24, 80, 8, 8), (33, 82, 9, 7), (44, 83, 8, 7), (54, 82, 9, 8), (64, 80, 8, 8)):
        house(x, y, w, h)
    # 성벽과 둥근 탑
    c.p("M12 104V92H90V104z", "#BDB49E", 1.8)
    c.crenel(12, 89, 78, 4.5, 18, "#AFA690")
    c.blocks(12, 93, 78, 11, 2, 8, s=.4, col=dk)
    for x in (14, 40):
        c.r(x, 86, 9, 18, st, s=1.5)
        c.crenel(x - 1, 83, 11, 4, 3, st2)
    c.arch(49, 104, 6, 7, "#3F3429", s=.9)


@d
def khajuraho(c):
    st, st2, dk = "#DFC090", "#BF9F6D", "#7E6340"
    def spire(x, y, w, h, sw=1.5, cap=True):
        """곡선 시카라 하나. 가로 띠와 꼭대기 아말라카."""
        c.p(f"M{n(x - w / 2)} {n(y)}C{n(x - w / 2)} {n(y - h * .6)} {n(x - w * .24)} {n(y - h * .9)} {n(x - w * .12)} {n(y - h)}H{n(x + w * .12)}C{n(x + w * .24)} {n(y - h * .9)} {n(x + w / 2)} {n(y - h * .6)} {n(x + w / 2)} {n(y)}z", st, sw)
        c.p(f"M{n(x + w * .15)} {n(y)}C{n(x + w * .16)} {n(y - h * .6)} {n(x + w * .1)} {n(y - h * .9)} {n(x + w * .05)} {n(y - h)}H{n(x + w * .12)}C{n(x + w * .24)} {n(y - h * .9)} {n(x + w * .47)} {n(y - h * .6)} {n(x + w * .47)} {n(y)}z", st2, s=0) if h > 60 else None
        if h > 30:
            c.p("".join(f"M{n(x - w / 2 * (1 - f ** 2.2 * .8))} {n(y - h * f)}h{n(w * (1 - f ** 2.2 * .8))}" for f in (.25, .5, .75)), s=.5, col=dk)
        c.e(x, y - h - 1.2, w * .17, 1.5, st2, s=.9)
        c.l(x, y - h - 2.7, x, y - h - 5, s=1)
    c.shadow(50, 88)
    # 높은 기단
    c.p("M8 104V97H92V104z", "#CDAE7C", 1.7)
    c.p("M12 97V90H88V97z", st, 1.6)
    c.vlines(8, 97, 84, 7, 13, s=.45, col=dk)
    # 왼쪽 입구 계단과 낮은 만다파 지붕들
    c.p("M6 104L12 94V104z", st2, 1)
    spire(20, 78, 14, 12, 1.3)
    spire(30, 78, 16, 19, 1.4)
    # 조각 띠 벽
    c.box(12, 76, 72, 14, st, st2, sw=.2, s=1.7)
    c.windows(13, 78, 70, 8, 10, 2, dk, fill=.5)
    # 겹겹이 솟는 작은 시카라와 큰 시카라
    spire(82, 76, 11, 22, 1.3)
    spire(40, 76, 13, 32, 1.4)
    spire(74, 76, 13, 36, 1.4)
    spire(47, 76, 14, 46, 1.5)
    spire(68, 76, 14, 50, 1.5)
    spire(58, 76, 28, 66, 1.9)
    spire(50, 70, 8, 20, 1.1)
    spire(66, 70, 8, 20, 1.1)


@d
def byodoin(c):
    red, red2, wall = "#C5573C", "#9E412C", "#F3EBD8"
    roof, roof2 = "#5B5F63", "#44484C"
    c.p("M6 76Q20 62 40 72M60 70Q78 60 94 76V96H6z", "#BFD9B4", s=0)
    c.water(4, 96, 92, 12, "#9CD3E6")
    # 양쪽 날개 회랑: 기둥 위 2층
    for sg in (-1, 1):
        x0 = 50 + sg * 30
        c.p("".join(f"M{n(50 + sg * (18 + i * 4.5))} 96V80" for i in range(6)), s=1.3, col=red)
        c.r(6 if sg < 0 else 66, 76, 28, 4, wall, s=1.2)
        c.r(6 if sg < 0 else 66, 78, 28, 2, red, s=.8)
        c.vlines(6 if sg < 0 else 66, 76, 28, 2.2, 6, s=.5, col=red2)
        _wroof(c, x0, 76, 34, 6, roof, s=1.3, rid=.4)
        # 끝 누각
        tx = 50 + sg * 37
        c.r(tx - 3.5, 62, 7, 8, wall, s=1.1)
        c.p(f"M{n(tx - 3.5)} 70v-8M{n(tx + 3.5)} 70v-8M{n(tx)} 70v-8", s=.8, col=red)
        _wroof(c, tx, 62, 15, 7, roof, s=1.3, rid=.06)
        c.c(tx, 54.5, 1, GOLD, s=.6)
    # 가운데 본당 아래층
    c.r(32, 78, 36, 18, wall, s=1.6)
    c.p("M38 96V78M44 96V78M56 96V78M62 96V78", s=1.5, col=red)
    c.p("M44 96V80h12v16z", red2, s=.8)
    c.c(50, 84, 2.4, GOLD, s=.7)
    c.p("M32 88h6M62 88h6", s=.8, col=red)
    # 아래 처마(모코시)
    _wroof(c, 50, 77, 54, 8, roof, rid=.34)
    c.p("M28 73.8Q50 76 72 73.8", s=.5, col=roof2)
    # 위층과 큰 지붕
    c.r(37, 60, 26, 10, wall, s=1.4)
    c.p("M43 70V60M50 70V60M57 70V60", s=1.2, col=red)
    c.r(35, 58.5, 30, 2, red, s=.8)
    _wroof(c, 50, 59, 60, 19, roof, s=1.9, rid=.2)
    c.p("M38 40Q30 50 24 55M62 40Q70 50 76 55M46 41L42 56M54 41L58 56M50 40V57", s=.5, col=roof2)
    c.p("M37.5 40h25", s=2)
    # 금 봉황 한 쌍
    for x, sg in ((38, -1), (62, 1)):
        c.p(f"M{x} 39.5q{sg * -1} -3 {sg * 1} -5q{sg * 2} -1.5 {sg * 3} .5l{sg * -1.5} .5l{sg * 3} 4q{sg * -3} 1 {sg * -7} 0z", GOLD, .9)
    # 수면 반영
    c.p("M26 101h16M56 103h18M14 104h8", s=.8, col="#E8F4F4")
    c.p("M36 100h28", s=1.2, col="#7FB5C9")


@d
def st_mark(c):
    m, m2, dk = "#EFE7D6", "#D3C9B2", "#7C735F"
    lead = "#8F9CA3"
    gold = "#E2B64A"
    # 왼쪽 붉은 벽돌 종탑
    c.box(5, 22, 10, 82, "#BE6F52", "#9D5840", sw=.3, s=1.7)
    c.vlines(5, 26, 10, 54, 2, s=.5, col="#8A4C36")
    c.r(4, 14, 12, 8, m, s=1.2)
    c.vlines(4, 15, 12, 6.5, 2, s=1)
    c.p("M4 14L10 3L16 14z", "#7FBFA8", 1.5)
    c.c(10, 2.8, 1.1, GOLD, s=.6)
    # 납빛 돔 셋 + 가운데 크게
    for x, r, base in ((31, 9, 46), (69, 9, 46), (50, 11, 42)):
        c.r(x - r * .72, base, r * 1.44, 12, m2, s=1.2)
        c.p("".join(f"M{n(x + r * q)} {base + 10}V{base + 3}" for q in (-.45, -.15, .15, .45)), s=1)
        c.p(f"M{n(x - r * .78)} {base}C{n(x - r * 1.25)} {base - r} {n(x - r * .4)} {n(base - r * 1.45)} {x} {n(base - r * 1.6)}C{n(x + r * .4)} {n(base - r * 1.45)} {n(x + r * 1.25)} {base - r} {n(x + r * .78)} {base}z", lead, 1.8)
        t = base - r * 1.6
        c.p(f"M{n(x - 1.5)} {n(t + .5)}v-3h3v3z", gold, .8)
        c.p(f"M{n(x - 1.8)} {n(t - 2.5)}q1.8-3 3.6 0z", lead, .8)
        c.c(x, t - 5, .9, GOLD, s=.5)
    # 아래층 문 다섯
    c.r(12, 76, 76, 28, m, s=1.9)
    c.p("M12 90h76", s=.4, col=dk)
    for x, w in ((20, 11), (35, 12), (50, 16), (65, 12), (80, 11)):
        c.p(f"M{n(x - w / 2)} 104V{n(90 - w / 2 + 2)}a{n(w / 2)} {n(w / 2)} 0 0 1 {w} 0V104z", gold, 1.2)
        q = w / 2 - 1.8
        c.p(f"M{n(x - q)} 104V{n(92 - w / 2 + 6)}h{n(q * 2)}V104z", "#3F3429", .7)
    c.p("M27 104V82M42.5 104V82M57.5 104V82M73 104V82", s=1.4, col=dk)
    # 위층 물결 박공과 금 모자이크
    def ogee(x, w, h, base=76):
        t = base - h
        c.p(f"M{n(x - w / 2)} {base}V{n(t + h * .45)}Q{n(x - w / 2)} {n(t + h * .22)} {n(x - w * .12)} {n(t + h * .12)}L{x} {t}L{n(x + w * .12)} {n(t + h * .12)}Q{n(x + w / 2)} {n(t + h * .22)} {n(x + w / 2)} {n(t + h * .45)}V{base}z", m, 1.5)
    for x, w, h in ((20, 14, 15), (80, 14, 15), (35, 15, 16), (65, 15, 16)):
        ogee(x, w, h)
        c.p(f"M{n(x - w * .28)} 74V{n(68 - w * .05)}a{n(w * .28)} {n(w * .28)} 0 0 1 {n(w * .56)} 0V74z", gold, .8)
    ogee(50, 22, 26)
    c.p("M41 74V62a9 9 0 0 1 18 0V74z", "#6FA3C7", 1.2)
    c.p("M50 53V74M44.5 56v18M55.5 56v18M41 64h18", s=.5)
    c.p("M12 76h76", s=1.6)
    c.p("M42.5 76v-2h15v2z", "#7E9A63", .7)
    c.l(50, 50, 50, 46, s=1, col=gold)
    c.c(50, 46, 1, GOLD, s=.5)


@d
def windsor(c):
    st, st2, dk = "#CFC4A8", "#AFA488", "#7A725C"
    c.cloud(78, 24, .7)
    # 둥근 탑이 올라앉은 초록 둔덕
    c.p("M18 84Q32 58 46 56Q60 58 76 84z", "#8FC066", 1.7)
    c.box(32, 30, 28, 30, st, st2, sw=.25, s=2)
    c.crenel(30.5, 25.5, 31, 6, 7, st2)
    c.blocks(32, 32, 28, 28, 4, 3, s=.42, col=dk)
    c.p("M38 56V47a2.5 2.5 0 0 1 5 0V56zM49 56V47a2.5 2.5 0 0 1 5 0V56z", WIN, s=.6)
    c.p("M38 40V36h5v4zM49 40V36h5v4z", WIN, s=.5)
    # 깃대와 왕실 깃발
    c.l(46, 26, 46, 9, s=1.3)
    c.r(46, 9, 12, 7, "#C6503F", s=.8)
    c.p("M46 9h6v3.5h-6zM52 12.5h6V16h-6z", "#EDBE4E", s=0)
    c.p("M46 12.5h12M52 9v7", s=.5)
    # 왼쪽 세인트 조지 예배당
    c.r(8, 64, 24, 18, "#DDD3B9", s=1.7)
    c.p("M10 82V70l2-3l2 3v12zM16 82V70l2-3l2 3v12zM22 82V70l2-3l2 3v12z", WIN, s=.6)
    c.p("M7 64V58l1-3l1 3v6M31 64V58l1-3l1 3v6M19 64V59l1-3l1 3v5", st2, .8)
    c.p("M8 64L12 59H28L32 64z", "#6E7787", 1.2)
    # 긴 외곽 성벽
    c.box(6, 82, 88, 22, st, s=2)
    c.crenel(6, 78.5, 88, 4.5, 20, st2)
    c.blocks(6, 84, 88, 20, 3, 8, s=.4, col=dk)
    c.p("M52 100V90h4v10zM64 100V90h4v10z", WIN, s=.5)
    # 앞 탑들과 정문
    for x, w, h in ((14, 13, 32), (36, 12, 28), (72, 13, 30), (88, 11, 26)):
        c.box(x - w / 2, G - h, w, h, "#D8CDB2", st2, sw=.3, s=1.7)
        c.crenel(x - w / 2 - 1, G - h - 3.5, w + 2, 5, 3, st2)
        c.r(x - 1, G - h + 6, 2, 5, WIN, s=0)
    c.arch(14, 104, 6, 10, "#3F3429", s=1)
    c.people(44, 104, 3, 3)


@d
def tower_london(c):
    w, w2, dk = "#F2EDDF", "#D6CFBC", "#7F7A69"
    lead = "#6D7884"
    # 뒤쪽 두 탑
    for x in (31, 61):
        c.r(x - 3.5, 24, 7, 10, w2, s=1.3)
        c.p(f"M{x - 4.5} 24Q{x - 4} 18 {x} 14Q{x + 4} 18 {x + 4.5} 24z", lead, 1.3)
        c.l(x, 14, x, 9, s=1)
    # 흰 탑 몸체
    c.box(20, 34, 52, 54, w, w2, sw=.22, s=2)
    c.crenel(19, 30.5, 54, 5, 12, w2)
    c.p("M33 34V88M46 34V88M59 34V88", s=.9, col=dk)
    d_ = ""
    for x in (26.5, 39.5, 52.5, 65.5):
        for y, h in ((46, 7), (59, 7), (72, 6)):
            d_ += f"M{x - 1.7} {y}v-{h - 1.7}a1.7 1.7 0 0 1 3.4 0v{h - 1.7}z"
    c.p(d_, "#4F4A3E", s=.6)
    # 앞 양쪽 모서리 탑(왼쪽은 둥근 계단탑)
    c.box(14, 26, 11, 62, w, w2, sw=.35, s=1.8)
    c.box(67, 26, 11, 62, w, w2, sw=.35, s=1.8)
    c.p("M12.8 26Q13.5 18 19.5 11Q25.5 18 26.2 26z", lead, 1.7)
    c.p("M65.8 26Q66.5 18 72.5 11Q78.5 18 79.2 26z", lead, 1.7)
    c.p("M19.5 11V6M72.5 11V6", s=1.2)
    c.p("M19.5 6l3 1-3 1M72.5 6l3 1-3 1", GOLD, .7)
    c.p("M17.5 44V39h4v5zM17.5 64V59h4v5zM70.5 44V39h4v5zM70.5 64V59h4v5z", "#4F4A3E", s=.5)
    # 꿀빛 외곽 성벽과 둥근 탑
    c.box(6, 86, 88, 18, "#D9BE8C", "#BB9F6C", sw=.14, s=1.9)
    c.crenel(6, 82.5, 88, 4.5, 20, "#CDB17E")
    c.blocks(6, 88, 88, 16, 2, 8, s=.4, col="#8A7247")
    for x in (10, 88):
        c.box(x - 6, 78, 12, 26, "#DFC594", "#BB9F6C", sw=.3, s=1.7)
        c.crenel(x - 7, 74.5, 14, 5, 3, "#CDB17E")
    # 물 문
    c.p("M38 104V92a8 8 0 0 1 16 0V104z", "#CDB17E", 1.5)
    c.p("M41 104V92a5 5 0 0 1 10 0V104z", "#3F3429", .9)
    c.vlines(41, 90, 10, 14, 3, s=.5, col="#A79A7C")
    # 까마귀
    c.p("M28 104q0-3 3-3l2-1l.8 1l-1.3.6q0 2.4-1.5 2.4z", "#3A3A3F", .6)


@d
def ananda(c):
    w, w2, dk = "#F4EFE2", "#D7D0BE", "#8A8370"
    gold, gold2 = "#E8BB4A", "#C99A30"
    # 열기구 — 바간 하늘
    c.p("M82 10a9 9 0 0 1 9 9c0 5-5 8-7 11h-4c-2-3-7-6-7-11a9 9 0 0 1 9-9z", "#E2694F", 1.2)
    c.p("M82 10c-3 3-4 7-2 20h4c2-13 1-17-2-20z", "#F2C94C", .6)
    c.r(80.5, 32, 3, 2.4, WOOD, s=.7)
    c.shadow(50, 84)
    # 기단
    c.p("M8 104V97H92V104z", "#E8E2D2", 1.7)
    c.vlines(8, 97, 84, 7, 13, s=.45, col=dk)
    # 몸체와 네 방향 현관
    c.box(16, 78, 68, 19, w, w2, sw=.2, s=1.8)
    c.arches(18, 96, 64, 11, 8, "#55504A", fill=.42)
    c.p("M36 97V78h28v19z", w, 1.5)
    c.arch(50, 97, 10, 15, "#3F3429", s=1)
    # 층단 지붕 — 흰 테라스와 모서리 작은 탑
    for y, wd, hh in ((78, 70, 6), (72, 56, 6), (66, 44, 6), (60, 32, 5)):
        c.p(f"M{n(50 - wd / 2)} {y}Q{n(50 - wd / 2 + 2)} {y - hh + 1} {n(50 - wd / 2 + 4)} {y - hh}H{n(50 + wd / 2 - 4)}Q{n(50 + wd / 2 - 2)} {y - hh + 1} {n(50 + wd / 2)} {y}z", "#ECE6D6", 1.5)
        for x in (50 - wd / 2 + 3, 50 + wd / 2 - 3):
            c.p(f"M{n(x - 1.8)} {y - hh + .5}Q{n(x)} {y - hh - 5} {n(x + 1.8)} {y - hh + .5}z", gold, .8)
    # 현관을 다시 앞으로
    c.p("M36 78L42 68L50 60L58 68L64 78z", gold, 1.5)
    c.p("M40 78L50 66L60 78", s=.7, col=gold2)
    c.arch(50, 77, 8, 9, "#55504A", s=.8)
    # 금빛 시카라와 티(우산)
    c.p("M38 55C39 40 45 28 50 16C55 28 61 40 62 55z", gold, 1.9)
    c.p("M53 24C57 34 60 44 60.5 54.5H55C56 44 55 34 53 24z", gold2, s=0)
    c.p("M41 48h18M43 41h14M45 34h10M47 27h6", s=.6, col=gold2)
    c.p("M38 55C39 40 45 28 50 16C55 28 61 40 62 55z", s=1.9)
    c.l(50, 16, 50, 8, s=1.2, col=gold2)
    _rings(c, 50, 14, 4, 1.6, 5, gold2, .9)
    c.c(50, 7.5, .9, gold, s=.5)


@d
def alcazar(c):
    w, w2, dk = "#E9D8B5", "#CBB88F", "#857656"
    sl = "#5A6C82"
    # 뱃머리처럼 왼쪽으로 뾰족한 바위
    c.p("M6 104Q12 92 24 84H86L94 104z", "#AFA18A", 1.9)
    c.p("M12 100l6-4M28 94l8-1M48 98l10-2M72 96l8 2", s=.7, col="#7F7361")
    # 후안 2세 탑: 윗부분에 총안 달린 반원 작은 탑 줄(고깔 없음)
    c.box(58, 30, 24, 56, w, w2, sw=.3, s=2)
    c.blocks(58, 40, 24, 46, 5, 3, s=.35, col=dk)
    c.p("M63 60V52a2.5 2.5 0 0 1 5 0V60zM72 60V52a2.5 2.5 0 0 1 5 0V60zM67 76V68a2.5 2.5 0 0 1 5 0V76z", WIN, s=.6)
    c.crenel(57, 25, 26, 5, 6, w2)
    for x in (56.5, 63.2, 70, 76.8, 83.5):
        c.p(f"M{n(x - 2.4)} 22V31Q{x} 36 {n(x + 2.4)} 31V22z", w, s=1.1)
        c.crenel(x - 3, 18.6, 6, 4.4, 2, w2)
        c.l(x, 25, x, 29, s=.7, col=dk)
    # 본관
    c.r(26, 54, 34, 32, w, s=1.9)
    c.r(50, 55, 9, 30, w2, s=0)
    c.p("M26 54V86", s=1.9)
    c.blocks(26, 60, 34, 26, 4, 4, s=.35, col=dk)
    c.p("M31 72V64a2 2 0 0 1 4 0V72zM39 72V64a2 2 0 0 1 4 0V72zM47 72V64a2 2 0 0 1 4 0V72zM31 83V77h4v6zM39 83V77h4v6zM47 83V77h4v6z", WIN, s=.5)
    c.p("M24 54L30 42H60V54z", sl, 1.8)
    c.p("M30 48h30M36 42L33 54M46 42L44 54", s=.5, col="#7A8BA0")
    # 왼쪽 동화 같은 고깔 탑들(뱃머리)
    for x, y0, wd, h, k in ((48, 54, 10, 8, 22), (33, 54, 11, 12, 24), (20, 88, 14, 40, 28)):
        c.box(x - wd / 2, y0 - h, wd, h, w, w2, sw=.3, s=1.7)
        c.p(f"M{n(x - wd / 2 - 1.5)} {n(y0 - h)}L{x} {n(y0 - h - k)}L{n(x + wd / 2 + 1.5)} {n(y0 - h)}z", sl, 1.8)
        c.p(f"M{x} {n(y0 - h - k)}v-3", s=1)
        c.p(f"M{n(x + 1)} {n(y0 - h - k * .7)}L{n(x + wd / 2)} {n(y0 - h - 1)}", s=.5, col="#7A8BA0")
    c.p("M18.5 66V60a1.5 1.5 0 0 1 3 0V66zM18.5 82V76a1.5 1.5 0 0 1 3 0V82z", WIN, s=.5)
    c.p("M90 92V84", s=1.6, col="#8A6C50")
    c.c(90, 80, 6, "#7FB765", s=1.1)


@d
def kalyan(c):
    br, br2, dk = "#DBBE8D", "#BC9F6E", "#7E6741"
    tq = "#3E9CAB"
    # 낮은 모스크 벽과 푸른 돔
    c.r(62, 72, 22, 16, "#E6CDA0", s=1.5)
    c.dome(73, 72, 11, tq, "#2F8290", h=13)
    c.p("M64 74h18", s=.8, col="#2F8290")
    c.p("M6 104V88H94V104z", br, 1.9)
    c.blocks(6, 88, 88, 16, 3, 11, s=.4, col=dk)
    c.arch(16, 104, 8, 12, "#3F3429", s=1)
    c.arches(62, 103, 30, 10, 4, "#54493A")
    # 위로 좁아지는 벽돌 미나렛 — 무늬 띠
    def hw(y):
        return 8 + (104 - y) * .045
    def band(y0, y1, f=None):
        return f"M{n(44 - hw(y0))} {y0}L{n(44 - hw(y1))} {y1}H{n(44 + hw(y1))}L{n(44 + hw(y0))} {y0}z"
    c.p(band(104, 22), br, 2)
    c.p(f"M{n(44 + hw(104) * .4)} 103.5L{n(44 + hw(22) * .4)} 22.5H{n(44 + hw(22) - .8)}L{n(44 + hw(104) - .8)} 103.5z", br2, s=0)
    c.p(band(104, 22), s=2)
    # 격자·줄 무늬
    dd = ""
    for y0, y1, kind in ((88, 76, 0), (74, 64, 1), (62, 52, 0), (50, 42, 1), (40, 32, 0)):
        for j in range(-3, 3):
            xa = 44 + j * hw(y0) / 3
            xb = 44 + (j + 1) * hw(y1) / 3
            if kind == 0:
                dd += f"M{n(xa)} {y0}L{n(xb)} {y1}M{n(xb)} {y0}L{n(xa)} {y1}"
            else:
                dd += f"M{n(xa + 1)} {y0}V{y1}"
    c.p(dd, s=.5, col=dk)
    c.p("".join(f"M{n(44 - hw(y))} {y}h{n(2 * hw(y))}" for y in (89, 75, 63, 51, 41, 31)), s=1)
    c.p(band(34, 31), tq, .9)
    c.p(band(76, 74), tq, .8)
    # 꼭대기 로툰다: 벌어진 처마와 16 아치
    c.p("M34.5 22Q37 18 31.5 14H56.5Q51 18 53.5 22z", br, 1.7)
    c.p("M36 18h16", s=.6, col=dk)
    c.r(32, 6, 24, 8, "#E6CDA0", s=1.7)
    c.arches(33, 13.5, 22, 6, 8, "#4F4238", fill=.64)
    c.p("M30.5 6L33 3.5H55L57.5 6z", tq, 1.3)
    c.p("M36.5 3.5Q44-.5 51.5 3.5z", br2, 1.2)


@d
def krak(c):
    st, st2, dk = "#D3C29E", "#B3A27E", "#7C6F52"
    def round_tower(x, wd, top, bot, f):
        """둥근 탑: 위아래가 굽은 몸통, 오른쪽 그늘, 굽은 총안."""
        r = wd / 2
        P = f"M{n(x - r)} {n(bot)}V{n(top)}A{n(r)} 1.8 0 0 1 {n(x + r)} {n(top)}V{n(bot)}A{n(r)} 1.8 0 0 1 {n(x - r)} {n(bot)}z"
        c.p(P, f, s=1.8)
        c.p(f"M{n(x + r * .3)} {n(top + 1.5)}H{n(x + r)}V{n(bot)}Q{n(x + r * .7)} {n(bot + 1.4)} {n(x + r * .3)} {n(bot + 1.6)}z", st2, s=0)
        c.p(P, s=1.8)
        d_ = "".join(f"M{n(x + r * t - 1)} {n(top - 2.4 + (1 - t * t) * 1.8)}h2v3h-2z" for t in (-.82, -.32, .32, .82))
        c.p(d_, f, s=.9)
        c.p(f"M{n(x - r)} {n(top + 2)}A{n(r)} 1.8 0 0 0 {n(x + r)} {n(top + 2)}", s=.7)
    # 언덕
    c.p("M4 104Q14 82 30 80H72Q88 82 96 104z", "#A9B677", 1.8)
    c.p("M14 96q6-3 10-1M38 98q6-3 12 0M66 94q5-2 10 0", s=.7, col="#7E8C58")
    # 바깥 성벽과 반원 탑
    c.p("M12 96L16 66H88L92 96z", st, 2)
    c.p("M76 66H88L92 96H78z", st2, s=0)
    c.crenel(16, 62.5, 72, 4.5, 18, st2)
    c.blocks(16, 68, 72, 28, 3, 6, s=.42, col=dk)
    c.p("M12 96L16 66M88 66L92 96", s=2)
    for x, wd in ((15, 12), (40, 11), (64, 11), (88, 11)):
        round_tower(x, wd, 60, 96.5, "#DDCDAA")
        c.r(x - .7, 69, 1.4, 6, "#3F3429", s=0)
    c.arch(28, 96, 6, 9, "#3F3429", s=1)
    # 안쪽 비탈 벽(글라시스)과 내성
    c.p("M26 62L32 40H72L78 62z", "#C7B58F", 1.9)
    c.p("M30 56h44M31.5 48h41", s=.5, col=dk)
    c.r(32, 28, 40, 12, st, s=1.8)
    c.crenel(32, 24.5, 40, 4.5, 10, st2)
    c.p("M38 38V33a1.8 1.8 0 0 1 3.6 0v5zM46 38V33a1.8 1.8 0 0 1 3.6 0v5z", "#3F3429", s=.5)
    # 내성 큰 둥근 탑 셋
    for x, wd, h in ((24, 14, 38), (60, 16, 48), (76, 14, 40)):
        round_tower(x, wd, 64 - h, 64, "#DDCDAA")
        c.p(f"M{n(x - 1)} {64 - h + 7}v5h2v-5zM{n(x - 1)} {64 - h + 21}v5h2v-5z", "#3F3429", s=0)


@d
def koutoubia(c):
    pk, pk2, dk = "#DDA588", "#BE866A", "#8C5B44"
    tq = "#4FA79B"
    c.palm(10, 104, 26)
    c.palm(90, 96, 22)
    c.shadow(52, 80)
    # 낮은 분홍 사원 벽
    c.p("M6 104V88H94V104z", "#D7A084", 1.8)
    c.crenel(6, 84.5, 88, 4.5, 20, pk2)
    c.arches(58, 103, 34, 10, 5, "#54403A")
    # 사각 탑
    c.box(28, 24, 28, 80, pk, pk2, sw=.26, s=2.1)
    c.blocks(28, 30, 28, 74, 6, 3, s=.32, col=pk2)
    c.p("M31 100V30H53V100z", s=.6, col=dk)
    # 세 단의 창과 얽힘 무늬 패널
    for y in (92, 68, 44):
        c.p(f"M36 {y}V{y - 9}Q36 {y - 13} 42 {y - 15}Q48 {y - 13} 48 {y - 9}V{y}z", "#EDC0A6", 1)
        c.p(f"M39 {y}V{y - 8}Q39 {y - 10.5} 42 {y - 11.5}Q45 {y - 10.5} 45 {y - 8}V{y}z", "#4A3730", .7)
        c.p(f"M34 {y - 17}h16v-4h-16zM34 {y - 17}l4-4l4 4l4-4l4 4", s=.5, col=dk)
    # 흰 띠, 터키석 타일, 총안
    c.r(28, 24, 28, 6, "#EFE7CF", s=1.3)
    c.p("M29.5 27q1.5-2.2 3 0q1.5-2.2 3 0q1.5-2.2 3 0q1.5-2.2 3 0q1.5-2.2 3 0q1.5-2.2 3 0q1.5-2.2 3 0q1.5-2.2 3 0", s=.8, col=tq)
    c.crenel(27, 19.5, 30, 5.5, 7, pk)
    # 작은 등탑과 금 공 셋
    c.box(36, 8, 12, 14, pk, pk2, sw=.3, s=1.7)
    c.arch(42, 20, 5, 9, "#4A3730", s=.7)
    c.r(36, 8, 12, 2.4, tq, s=.9)
    c.p("M35 8L42 3.5L49 8z", "#67A698", 1.3)
    c.l(42, 4, 42, 0, s=1.2, col=GOLD2)
    c.p("M41 3.2h2M41.2 1.2h1.6", s=1.7, col=GOLD)


@d
def itsukushima(c):
    red, red2, dk = "#D2503C", "#AB3B2A", "#4A4A4A"
    # 뒤쪽 미센 산
    c.p("M4 90Q18 54 34 62Q46 40 62 56Q76 46 96 90z", "#8DBB85", 1.1)
    c.p("M6 90Q30 68 50 74Q72 64 94 90z", "#74A873", .8)
    c.water(4, 86, 92, 24, "#9CD3E6")
    # 네 받침 기둥
    c.p("M18 100V62M34 100V62M60 100V62M76 100V62", s=4.2)
    c.p("M18 100V62M34 100V62M60 100V62M76 100V62", s=2.6, col=red2)
    c.p("M16 75H36M58 75H78M16 66H36M58 66H78", s=2.6)
    c.p("M16 75H36M58 75H78M16 66H36M58 66H78", s=1.4, col=red2)
    # 큰 기둥
    c.p("M24 104L27 24H33L36 104zM58 104L61 24H67L70 104z", red, 2)
    c.p("M32 104L30.6 26H33L36 104zM66 104L64.6 26H67L70 104z", red2, s=0)
    c.p("M24 104L27 24H33L36 104zM58 104L61 24H67L70 104z", s=2)
    # 관(가로대)와 현판
    c.r(16, 41, 62, 5, red, s=1.7)
    c.p("M58 42h20v3.2H58z", red2, s=0)
    c.r(42.5, 26, 9, 15, "#2F4A5E", s=1.2)
    c.p("M44.5 29h5M47 28v11M44.5 33h5M44.5 36.5h5", s=.7, col=GOLD)
    # 위 이중 가로대: 끝이 들린 지붕보
    c.r(13, 25, 68, 5, red, s=1.7)
    c.p("M6 12Q47 21 88 12L85 25H9z", red, 2)
    c.p("M60 18.5Q78 17 87 13L84 24.5H60z", red2, s=0)
    c.p("M5 10Q47 19 89 10L88 14Q47 23 6 14z", dk, 1.9)
    c.p("M9 16.5L11 25M17 18L18.5 25M28 19.5V25M47 20.5V25M66 19.5V25M77 18L75.5 25M85 16.5L83 25", s=.5, col=red2)
    c.p("M24 100h12M58 100h12", s=2.4, col="#3F3429")
    c.p("M27 36h6M61 36h6M27 54h7M61 54h7", s=.6, col=red2)
    # 물 위 반영과 물결
    c.p("M24 106h12M58 106h12", s=1.8, col="#E0837A")
    c.p("M10 92h10M40 96h14M44 102h10M82 100h8", s=.9, col="#E8F4F4")


@d
def pisa(c):
    m, m2, dk = "#F4EEDF", "#DAD1BC", "#8C8674"
    k = .125
    X = lambda x, y: x + (104 - y) * k
    def tier(hw, y0, y1, f=m, sw=1.7):
        c.p(f"M{n(X(42 - hw, y0))} {y0}L{n(X(42 - hw, y1))} {y1}L{n(X(42 + hw, y1))} {y1}L{n(X(42 + hw, y0))} {y0}Q{n(X(42, y0 + 3))} {y0 + 3} {n(X(42 - hw, y0))} {y0}z", f, sw)
    c.cloud(82, 26, .8)
    c.shadow(44, 56)
    c.p("M26 104v-3h36v3z", "#C9C3B1", 1.3)
    # 맨 아래 긴 층: 막힌 아치
    tier(15.5, 102, 82)
    c.p("".join(f"M{n(X(42 + q, 100))} 100L{n(X(42 + q, 90))} 90a2.2 2.2 0 0 1 4.4 0L{n(X(42 + q + 4.4, 100))} 100z" for q in (-14, -8, -2, 4, 10)), m2, .7)
    # 여섯 회랑
    top = 82
    h = 9.8
    for i in range(6):
        y0 = top - i * h
        y1 = y0 - h
        tier(15 - i * .08, y0, y1)
        c.p(f"M{n(X(50, y0))} {n(y0 + 1)}L{n(X(50, y1))} {n(y1 + .5)}H{n(X(56.5, y1))}L{n(X(56.5, y0))} {n(y0 + 1)}z", m2, s=0)
        dd = ""
        for q in (-13, -7, -1, 5, 11):
            xb, xt = X(42 + q, y0 - .8), X(42 + q, y1 + 3)
            dd += f"M{n(xb)} {n(y0 - .8)}L{n(xt)} {n(y1 + 3)}a1.3 1.3 0 0 1 2.6 0L{n(xb + 2.6)} {n(y0 - .8)}z"
        c.p(dd, "#6E6A5C", s=.5)
        c.p(f"M{n(X(26.5, y1))} {y1}Q{n(X(42, y1 + 2.6))} {n(y1 + 2.6)} {n(X(57.5, y1))} {y1}", s=1.1)
    # 맨 위 종층
    yt = top - 6 * h
    tier(9.5, yt, 11, m)
    c.p("".join(f"M{n(X(42 + q, yt - .5))} {n(yt - .5)}L{n(X(42 + q, 15))} 15a1.5 1.5 0 0 1 3 0L{n(X(42 + q + 3, yt - .5))} {n(yt - .5)}z" for q in (-8.5, -3.5, 1.5, 6)), "#6E6A5C", .6)
    c.p(f"M{n(X(32.5, 11))} 11Q{n(X(42, 7))} 7 {n(X(51.5, 11))} 11z", m2, 1.3)
    c.people(14, 104, 3, 3)


@d
def borgund(c):
    w, w2, rf, rf2 = "#7D5539", "#634229", "#5B3E2B", "#3F2A1C"
    # 뒤쪽 노르웨이 산과 전나무
    c.p("M6 90L20 64L30 74L42 58L60 76L74 62L94 90z", "#C7D7DC", .9)
    c.p("M16 72L20 64L24 70zM70 68L74 62L78 68z", "#FFFFFF", .5)
    c.p("M8 104L12.5 84L17 104zM88 104L92 86L96 104z", "#4F7F58", 1)
    c.shadow(48, 72)
    # 아래 회랑
    c.r(16, 90, 64, 14, w, s=1.7)
    c.vlines(16, 94, 64, 10, 12, s=.7, col=rf2)
    c.p("M30 104V96h4v8zM60 104V96h4v8z", rf2, s=0)
    # 첫 지붕
    c.p("M10 90L24 72H72L86 90z", rf, 1.9)
    d_ = "".join(f"M{n(10 + i * 2.3)} {88 - i * 3}H{n(86 - i * 2.3)}" for i in range(0, 6))
    c.p(d_, s=.5, col=rf2)
    # 정면 박공과 조각 문
    c.p("M38 104V84L48 68L58 84V104z", w, 1.7)
    c.p("M43 104V90a5 5 0 0 1 10 0V104z", rf2, 1)
    c.p("M40 84L48 72L56 84", s=.7, col=rf2)
    c.l(48, 68, 48, 63, s=1.2)
    c.p("M46 65h4", s=1.1)
    # 2단 벽과 지붕
    c.r(28, 60, 40, 12, w2, s=1.6)
    c.vlines(28, 60, 40, 12, 7, s=.6, col=rf2)
    c.p("M24 60L38 44H58L72 60z", rf, 1.9)
    c.p("M28 57h40M32 52.5h32M36 48h24", s=.5, col=rf2)
    # 3단 벽과 지붕
    c.r(37, 37, 22, 7, w2, s=1.4)
    c.vlines(37, 37, 22, 7, 3, s=.6, col=rf2)
    c.p("M33 37L44 24H52L63 37z", rf, 1.8)
    c.p("M37 33h22M41 28.5h14", s=.5, col=rf2)
    # 용머리 넷
    for x, y, sg in ((24, 46, -1), (72, 46, 1), (38, 26, -1), (58, 26, 1)):
        c.p(f"M{x - sg * 3} {y + 4}Q{x} {y + 2} {x + sg * 1} {y - 2}q{sg * 2} -2 {sg * 3} 0l{sg * -2} 1", s=1.4)
    # 꼭대기 탑과 첨탑
    c.r(44, 17, 8, 7, w2, s=1.3)
    c.vlines(44, 18, 8, 5, 1, s=.6, col=rf2)
    c.p("M42.5 17L48 3L53.5 17z", rf, 1.6)
    c.p("M48 3V0.5", s=1.1)
    # 삼각 십자 박공 장식
    c.p("M48 44v-5M46 41h4", s=1)


def _face(c, x, y, w, h, f, dk, f2):
    """크메르 탑의 잔잔한 미소."""
    c.p(f"M{n(x - w / 2)} {n(y + h)}V{n(y + h * .15)}Q{n(x)} {n(y - h * .1)} {n(x + w / 2)} {n(y + h * .15)}V{n(y + h)}z", f, 1.3)
    if w > 20:
        c.p(f"M{n(x - w * .38)} {n(y + h * .32)}q{n(w * .17)} {n(-h * .1)} {n(w * .33)} 0M{n(x + w * .05)} {n(y + h * .32)}q{n(w * .17)} {n(-h * .1)} {n(w * .33)} 0", s=.9)
    c.p(f"M{n(x - w * .34)} {n(y + h * .44)}q{n(w * .13)} {n(h * .06)} {n(w * .26)} 0M{n(x + w * .08)} {n(y + h * .44)}q{n(w * .13)} {n(h * .06)} {n(w * .26)} 0", s=.8)
    c.p(f"M{n(x)} {n(y + h * .36)}L{n(x - w * .08)} {n(y + h * .62)}H{n(x + w * .08)}z", f2, .6)
    c.p(f"M{n(x - w * .27)} {n(y + h * .74)}Q{n(x)} {n(y + h * .9)} {n(x + w * .27)} {n(y + h * .74)}Q{n(x)} {n(y + h * .76)} {n(x - w * .27)} {n(y + h * .74)}z", dk, .7)


def _bud(c, x, y, w, h, f, f2, dk):
    """연꽃 봉오리 탑 머리."""
    c.p(f"M{n(x - w / 2)} {y}C{n(x - w / 2)} {n(y - h * .5)} {n(x - w * .2)} {n(y - h * .85)} {x} {y - h}C{n(x + w * .2)} {n(y - h * .85)} {n(x + w / 2)} {n(y - h * .5)} {n(x + w / 2)} {y}z", f, 1.6)
    c.p("".join(f"M{n(x - w / 2 * (1 - q * .55))} {n(y - h * q)}h{n(w * (1 - q * .55))}" for q in (.25, .55)), s=.6, col=dk)


@d
def bayon(c):
    st, st2, dk = "#AEA48D", "#8E8570", "#5E5848"
    moss = "#87986B"
    _bush(c, [(7, 84, 6), (93, 82, 6)], "#6FA85E")
    c.shadow(50, 88)
    # 뒤 탑들
    for x, y, w, h in ((35, 58, 12, 18), (66, 58, 12, 18)):
        _bud(c, x, y, w, h, st2, st2, dk)
        c.r(x - w / 2, y, w, 14, st2, s=1.3)
    # 왼쪽·오른쪽 얼굴 탑
    for x in (20, 78):
        _bud(c, x, 56, 19, 22, st, st2, dk)
        _face(c, x, 56, 19, 19, st, dk, st2)
        c.r(x - 10, 75, 20, 8, st2, s=1.3)
    # 가운데 큰 얼굴 탑
    _bud(c, 49, 40, 27, 34, st, st2, dk)
    c.p("M49 6V2", s=1.2)
    _face(c, 49, 40, 27, 26, st, dk, st2)
    c.r(34, 66, 30, 13, st2, s=1.5)
    c.arches(36, 78.5, 26, 9, 5, dk)
    # 회랑과 기단
    c.box(8, 83, 84, 21, st, st2, sw=.16, s=1.9)
    c.arches(10, 103, 80, 12, 8, dk, fill=.58)
    c.p("M8 83V79H92V83z", st2, 1.3)
    c.p("M14 81h10M60 81h10M44 44h5", s=1.1, col=moss)
    # 계단
    c.p("M43 104V92H55V104z", "#BEB49D", 1.1)
    c.hlines(43, 92, 12, 12, 3, s=.5, col=dk)


@d
def chartres(c):
    st, st2, dk = "#D9CCA8", "#B8AB87", "#7C7154"
    cu = "#7FB5A0"
    # 초록 동판 본당 지붕(뒤), 오른쪽으로 이어짐
    c.p("M30 48L38 36H68L76 48z", cu, 1.7)
    c.r(74, 58, 18, 24, st, s=1.6)
    c.p("M72 58L78 48H92V58z", cu, 1.5)
    c.p("M78 80V66l2-3l2 3v14zM85 80V66l2-3l2 3v14z", "#5E7FA8", s=.6)
    # 오른쪽 탑: 수수한 팔각 첨탑(낮음)
    c.box(58, 38, 20, 66, st, st2, sw=.28, s=1.9)
    c.p("M60 38L68 8L76 38z", "#C9BC96", 1.9)
    c.p("M68 8V38M64 38L68 8M72 38L68 8M61.5 32h13M63 26h10M64.5 20h7", s=.5, col=dk)
    c.p("M62 38L60 30L64 38M74 38L76 30L72 38", st2, .8)
    # 왼쪽 탑: 화려한 불꽃 첨탑(높음)
    c.box(10, 40, 20, 64, st, st2, sw=.28, s=1.9)
    c.p("M12 40L20 2L28 40z", "#CDBF99", 1.9)
    c.p("M20 2V40M14 36h12M15 30h10M16.5 24h7M18 17h4", s=.5, col=dk)
    c.p("M12 40V26l-1.5-.5L12 20l1.5 5.5L13 26V40zM28 40V26l1.5-.5L28 20l-1.5 5.5L27 26V40z", st, .9)
    c.p("M15 34l1.5-5l1.5 5M22 34l1.5-5l1.5 5M17 22l1-4l1 4M21 22l1-4l1 4", s=.7)
    # 가운데 정면
    c.r(30, 44, 28, 60, "#E3D7B6", s=1.8)
    c.p("M30 44L44 34L58 44z", st, 1.6)
    # 왕의 갤러리와 장미창
    c.r(30, 44, 28, 4, st2, s=.9)
    c.vlines(30, 44, 28, 4, 9, s=.7)
    c.rose(44, 58, 9, "#3F6FA8")
    # 세 란셋 창과 왕의 문
    c.p(_pt(36, 84, 5, 14) + _pt(44, 84, 5, 14) + _pt(52, 84, 5, 14), "#3F6FA8", .9)
    c.p("M30 86h28", s=.9)
    for x, w_ in ((36, 7), (44, 8), (52, 7)):
        c.p(_pt(x, 104, w_, 16), "#CDBF99", 1.1)
        c.p(_pt(x, 104, w_ - 3, 11), "#4A4034", .7)
    # 탑 창과 세로 띠
    for x in (20, 68):
        c.p(_pt(x, 70, 6, 22), "#3F6FA8", .9)
        c.l(x, 52, x, 70, s=.5)
        c.p(_pt(x, 96, 8, 16), "#5A5041", .8)
    c.p("M10 74h20M58 74h20M10 50h20M58 50h20", s=.8)
    c.blocks(10, 76, 20, 28, 5, 3, s=.32, col=dk)


@d
def giralda(c):
    br, br2, dk = "#D39F78", "#B5825E", "#8A5E42"
    w, w2 = "#F0E6CF", "#D3C7AA"
    # 뒤 대성당의 고딕 부벽(오른쪽)
    c.p("M58 104V78L66 70L74 78L82 72L90 80V104z", "#E2D4B2", 1.6)
    c.p("M66 70V60M74 78V66M82 72V62M90 80V70", s=1.3)
    c.p("M64.8 62l1.2-5l1.2 5zM72.8 68l1.2-5l1.2 5zM80.8 64l1.2-5l1.2 5z", "#CFC09C", .7)
    c.p(_pt(68, 96, 4, 14) + _pt(76, 96, 4, 14) + _pt(84, 96, 4, 14), "#6F86A0", .6)
    # 오렌지 나무
    c.p("M14 104v-8", s=1.7, col="#8A6C50")
    c.c(14, 91, 7.5, "#5F9A63", s=1.1)
    c.p("M11 90h.1M16 88h.1M14 93h.1M17.5 92h.1", s=1.7, col="#ED9A3A")
    c.shadow(46, 44)
    # 벽돌 몸체
    c.box(30, 40, 30, 64, br, br2, sw=.2, s=2.1)
    # 세브카 마름모 무늬: 좌우 패널
    dd = ""
    for px in (31, 49.5):
        for y in range(46, 90, 7):
            for i in range(2):
                x0 = px + i * 5
                dd += f"M{n(x0)} {y + 3.5}l2.5-3.5l2.5 3.5l-2.5 3.5z"
    c.p(dd, s=.6, col=dk)
    # 가운데 창 줄
    c.r(42, 44, 6, 58, "#C58F69", s=.8)
    for y in (58, 74, 90):
        c.p(f"M43 {y}V{y - 5}a2 2 0 0 1 4 0V{y}z", "#4A3730", .6)
    c.arch(45, 104, 7, 9, "#3F3429", s=.9)
    # 코니스와 난간
    c.r(28, 38, 34, 3, w, s=1.3)
    # 르네상스 종루(흰 3단)
    c.box(33, 26, 24, 12, w, w2, sw=.25, s=1.8)
    c.arches(35, 37.5, 20, 9, 3, "#4F4238", fill=.6)
    c.p("M37.5 31.5a1 1 0 0 0 2 0zM44 31.5a1 1 0 0 0 2 0zM50.5 31.5a1 1 0 0 0 2 0z", GOLD, .5)
    c.r(31.5, 24, 27, 2.4, GOLD, s=1)
    c.box(38, 15, 14, 9, w, w2, sw=.3, s=1.6)
    c.arches(39, 23.5, 12, 6, 3, "#4F4238", fill=.6)
    c.r(36.5, 13.5, 17, 1.8, w2, s=1)
    c.p("M40 13.5C40 7 50 7 50 13.5z", "#E6C25A", 1.4)
    # 히랄디요 풍향 조각
    c.l(45, 8.5, 45, 2.5, s=1.3, col="#6C5A3A")
    c.p("M45 4l3.5-1.5v3zM43.5 8.5l1.5-3l1.5 3z", "#8E7A46", .7)


@d
def qutub(c):
    r, r2, dk = "#BE6448", "#984C33", "#6F3524"
    m = "#EFE6D3"
    # 왼쪽 쿠와트 사원 아치 잔해
    c.p("M6 104V72L12 60L18 52L24 60L30 72V104H25V76L18 66L11 76V104z", "#C7A98A", 1.6)
    c.p("M8 88h3M25 86h3M14 58l-4 8M22 58l4 8", s=.5, col=dk)
    c.r(32, 92, 2.4, 12, "#5D5E63", s=.8)
    c.shadow(52, 50)
    # 5층: 각 층이 좁아지고 발코니 띠로 나뉜다
    def story(y0, h, w0, w1, f, f2, flutes):
        c.p(f"M{n(52 - w0 / 2)} {y0}L{n(52 - w1 / 2)} {y0 - h}H{n(52 + w1 / 2)}L{n(52 + w0 / 2)} {y0}z", f, 1.9)
        c.p(f"M{n(52 + w0 * .22)} {y0 - .5}L{n(52 + w1 * .22)} {y0 - h + .5}H{n(52 + w1 / 2 - .5)}L{n(52 + w0 / 2 - .7)} {y0 - .5}z", f2, s=0)
        dd = ""
        for j in range(1, flutes):
            t = j / flutes - .5
            dd += f"M{n(52 + t * w0)} {y0}L{n(52 + t * w1)} {y0 - h}"
        c.p(dd, s=.65, col=dk)
    def balcony(y, w):
        c.p(f"M{n(52 - w / 2 - 2.5)} {y}L{n(52 - w / 2)} {y + 3}H{n(52 + w / 2)}L{n(52 + w / 2 + 2.5)} {y}z", "#D9B58E", 1.3)
        c.p(f"M{n(52 - w / 2 - 2.5)} {y}h{w + 5}", s=1.7)
    story(104, 32, 32, 25, r, r2, 8)
    c.p("M36.5 96h31M38 88h28M39.5 80h25", s=.8, col="#E3C7A2")
    balcony(70, 25)
    story(70, 22, 24, 19, r, r2, 7)
    c.p("M41 62h22M42 55h20", s=.8, col="#E3C7A2")
    balcony(46, 19)
    story(46, 16, 18, 15, r, r2, 6)
    c.p("M44 38h16", s=.8, col="#E3C7A2")
    balcony(28, 15)
    # 위 두 층은 흰 대리석과 사암
    story(28, 10, 14, 12.5, m, "#D7CDB6", 4)
    c.r(45.7, 20, 12.6, 2, r, s=.8)
    balcony(16, 12.5)
    story(16, 7, 12, 10, r, r2, 4)
    c.p("M46.5 9L47.5 7H56.5L57.5 9z", m, 1.1)
    c.p("M48 7C48 2 56 2 56 7z", m, 1.3)
    c.l(52, 3.5, 52, .5, s=1.1)
