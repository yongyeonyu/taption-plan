"""근현대 건축 2구역(1984~2023)."""
import math

from .kit import *

D = {}
def d(f):
    D[f.__name__] = f
    return f


def _cube(c, cx, cy, r, top, left, right, win="#5E7482"):
    """모서리로 선 큐브 하나. 지붕 마름모와 양쪽 벽."""
    dx = r * .866
    ul, ur, ll, lr = (cx - dx, cy - r / 2), (cx + dx, cy - r / 2), (cx - dx, cy + r / 2), (cx + dx, cy + r / 2)
    t, m, b = (cx, cy - r), (cx, cy), (cx, cy + r)
    c.poly([t, ur, m, ul], top, s=1.3)
    c.poly([ul, m, b, ll], left, s=1.3)
    c.poly([m, ur, lr, b], right, s=1.3)
    def q(a, u, w, v0, v1):
        ax, ay = a
        p = []
        for uu, vv in ((v0, u), (v1, u), (v1, w), (v0, w)):
            p.append((ax + (m[0] - ax) * uu + (ll[0] - ax if ax < cx else lr[0] - ax) * vv,
                      ay + (m[1] - ay) * uu + (ll[1] - ay if ax < cx else lr[1] - ay) * vv))
        return "M" + pts(p).replace(",", " ") + "z"
    c.p(q(ul, .25, .5, .2, .45) + q(ul, .25, .5, .6, .85) + q(ur, .25, .5, .2, .45) + q(ur, .25, .5, .6, .85), win, s=0)
    c.p(f"M{n(cx - dx * .5)} {n(cy - r * .5)}L{n(cx)} {n(cy - r * .75)}L{n(cx + dx * .5)} {n(cy - r * .5)}L{n(cx)} {n(cy - r * .25)}z", "#AFC3CB", s=.6)


@d
def cube_houses(c):
    # 연필 탑(Blaaktoren)은 왼쪽 뒤에
    c.p("M7 72V24L12 8L17 24V72z", "#A9B0B4", s=1.4)
    c.p("M7 24H17M9.5 30v38M14.5 30v38", s=.5)
    c.shadow(46, 84)
    c.r(8, 92, 78, 12, "#D8D3C8", s=1.5)
    c.p("M14 96h10v8h-10zM30 96h10v8h-10zM46 96h10v8h-10zM62 96h10v8h-10z", "#7D93A0", s=.7)
    c.hlines(8, 92, 78, 3, 1, s=.5)
    a, b, t = "#F4CE3F", "#D9A92B", "#EFEDE6"
    # 뒷줄
    for x in (32, 60):
        c.r(x - 2.5, 50, 5, 44, "#BDB8AD", s=1)
        _cube(c, x, 42, 15, t, "#EFC945", "#D3A52F")
    # 앞줄: 육각 기둥 위 기운 큐브
    for x in (18, 46, 74):
        c.p(f"M{x - 4} 92V76H{x + 4}V92z", "#CBC6BA", s=1.3)
        c.l(x + 1.4, 78, x + 1.4, 92, s=.5)
        _cube(c, x, 62, 16, t, a, b)


@d
def sixty_three(c):
    g, g2, ln = "#EFC862", "#CC9A3A", "#A9772A"
    c.water(6, 106, 88, 6, "#8FC6DC")
    c.cloud(74, 22, .8)
    # 수족관·아이맥스 저층부
    c.p("M64 104V90L88 90V104z", "#E8D5A6", s=1.4)
    c.r(67, 94, 18, 6, "#8FB5C4", s=.7)
    c.p("M12 104V96L24 90H36V104z", "#E2C377", s=1.4)
    c.vlines(14, 96, 20, 8, 4, s=.5, col=ln)
    # 금빛 유리 몸통, 위로 갈수록 계단처럼 물러나는 지붕
    body = "M33 104L37 8H45V12H50V17H55V23H60V30L63 30L67 104z"
    c.p(body, g, s=0)
    c.p("M50 12V104H67L63 30H60V23H55V17H50z", g2, s=0)
    d_ = ""
    for y in range(14, 104, 5):
        t = (y - 8) / 96
        l = 37 - 4 * t
        r = min(67 - (104 - y) * 4 / 74, 40 + (y - 8) * 1.05 if y < 30 else 99)
        d_ += f"M{n(l + .6)} {y}H{n(r - .6)}"
    c.p(d_, s=.45, col=ln)
    c.p("M38 12L34.2 100L38.6 100L41 12z", "#F9E6A8", s=0)
    c.p("M43 8.5L41.5 104M50 12V104M58.5 23L60 104", s=.6, col="#8C6220")
    c.p(body, s=1.9)
    # 하늘 전망대 띠
    c.p("M37 11H45V16H36.8z", "#F8E4A4", s=.9)
    c.l(40, 8, 40, 2, s=1.3)
    c.r(44, 98, 12, 6, "#8FB5C4", s=1)


@d
def hundertwasser(c):
    c.shadow(46, 80)
    # 물결치는 지붕선과 벽 전체
    wall = "M9 104V52Q14 45 20 50T34 46T50 44T64 48T80 46Q85 50 85 58V104z"
    c.p(wall, "#F6EEDC", s=0)
    # 층마다 다른 색 조각
    c.p("M9 104V82Q20 76 30 82T48 80V104z", "#E0645A", s=0)
    c.p("M48 104V76Q60 72 70 78T85 76V104z", "#F2C744", s=0)
    c.p("M9 82V62Q18 58 28 62L30 82Q20 76 9 82z", "#6FA8D8", s=0)
    c.p("M48 76L50 58Q58 54 66 58L70 78Q60 72 48 76z", "#EE9FB2", s=0)
    c.p("M70 78L66 58Q74 54 85 58V76z", "#7CC08A", s=0)
    c.p("M30 82L28 62Q38 58 50 58L48 80Q40 78 30 82z", "#F4E3B2", s=0)
    c.p("M9 82Q20 76 30 82T48 80M48 76Q60 72 70 78T85 76M9 62Q18 58 28 62Q38 58 50 58Q58 54 66 58Q74 54 85 58M30 82L28 62M50 58L48 104M66 58L70 78", s=.7)
    # 제각각인 창
    for x, y, w, h, f in ((14, 66, 7, 9, "#FBF6E8"), (34, 64, 6, 8, "#F06E5E"), (54, 62, 7, 8, "#FFF6DD"), (74, 62, 6, 9, "#F2C744"),
                          (14, 88, 6, 8, "#F2C744"), (37, 84, 7, 8, "#F6EEDC"), (56, 82, 6, 8, "#6FA8D8")):
        c.r(x, y, w, h, f, s=1, rx=1)
        c.r(x + 1.6, y + 1.6, w - 3.2, h - 3.2, WIN, s=0)
    # 도자기 기둥 아치 입구
    c.arch(28, 104, 11, 14, "#54697C", s=1.1)
    for x in (21, 34):
        c.r(x, 91, 3.4, 13, "#F2C744", s=.9)
        c.p(f"M{x} 95h3.4M{x} 99h3.4", s=1.2, col="#3F7FB5")
        c.c(x + 1.7, 90, 2.1, "#E0645A", s=.8)
    c.p("M44 103q3-2 6 0t6 0t6 0t6 0", s=1, col="#3F7FB5")
    c.p(wall, s=1.9)
    # 지붕 위 나무와 금빛 양파 탑
    for x, y, r in ((16, 44, 6), (43, 39, 7), (72, 41, 6.5), (58, 41, 4.5)):
        c.c(x, y, r, "#7FB765", s=1.2)
    c.r(24, 34, 8, 14, "#EE9FB2", s=1.3)
    c.onion(28, 34, 6, 13, GOLD)
    c.l(28, 21, 28, 15, s=1.2)
    c.c(28, 15, 1.2, GOLD, s=.6)
    c.c(52, 34, 5, "#3F7FB5", s=1.1)
    c.r(49, 38, 6, 8, "#F4E3B2", s=1.1)
    c.onion(52, 30, 3.8, 9, GOLD)


def _petal(c, x, y, a, l, w, f):
    """연꽃잎 하나. 밑점에서 각도 a(0=위)로 l만큼."""
    sa, ca = math.sin(a), math.cos(a)
    def P(u, v):
        return f"{n(x + u * ca + v * sa)} {n(y + u * sa - v * ca)}"
    c.p(f"M{P(-w, 0)}C{P(-w, l * .5)} {P(-w * .3, l * .85)} {P(0, l)}C{P(w * .3, l * .85)} {P(w, l * .5)} {P(w, 0)}z", f, s=1.3)
    c.p(f"M{P(0, l * .1)}L{P(0, l * .92)}", s=.5, col="#A79F8C")


@d
def lotus(c):
    c.shadow(50, 88)
    # 아홉 연못과 계단 대좌
    c.p("M6 104L14 96H86L94 104z", "#EDE6D6", s=1.4)
    c.p("M8 104q6-5 12 0zM24 104q7-5 14 0zM42 104q8-5 16 0zM62 104q7-5 14 0zM80 104q6-5 12 0z", "#8FCFE3", s=.8)
    c.r(18, 90, 64, 6, "#E2DBC9", s=1.3)
    c.vlines(18, 90, 64, 6, 15, s=.45)
    # 안쪽 꽃잎(곧게 선다)
    for a, l in ((-.42, 44), (.42, 44), (-.2, 52), (.2, 52), (0, 58)):
        _petal(c, 50 + a * 18, 90, a, l, 9, "#F2EEE3")
    # 가운데 입구 꽃잎
    for a, l, f in ((-.72, 42, "#F8F5EC"), (.72, 42, "#E9E4D6"), (-.34, 40, "#FBF9F2"), (.34, 40, "#EEE9DC"), (0, 38, "#FDFCF8")):
        _petal(c, 50 + a * 16, 90, a, l, 9.5, f)
    # 바깥으로 젖힌 잎, 입구 그림자
    for a, l, f in ((-1.2, 30, "#FBF9F2"), (1.2, 30, "#E5E0D1")):
        _petal(c, 50 + a * 14, 90, a, l, 7.5, f)
    c.p("M41 90Q50 74 59 90z", "#6F8894", s=1.1)
    c.p("M45 90Q50 80 55 90M50 80V90", s=.5)
    c.people(14, 96, 2)


@d
def hallgrim(c):
    a, b, ln = "#E4E4DF", "#BFC0BA", "#8D8F8B"
    c.cloud(74, 16, .8)
    c.shadow(50, 88)
    # 주상절리처럼 내려오는 계단 기둥(좌우 대칭)
    for i, (dx, y) in enumerate(((42, 86), (36, 78), (30, 69), (24, 59), (18, 48), (13, 36))):
        w = 7 if i else 8
        c.p(f"M{50 - dx - w / 2} 104V{y + 2}L{50 - dx} {y - 1}L{50 - dx + w / 2} {y + 2}V104z", a, s=1.4)
        c.p(f"M{50 + dx - w / 2} 104V{y + 2}L{50 + dx} {y - 1}L{50 + dx + w / 2} {y + 2}V104z", b, s=1.4)
        c.p(f"M{50 - dx} {y + 1}V104M{50 + dx} {y + 1}V104", s=.5, col=ln)
    # 중앙 탑
    c.p("M42 104V24L46 16H54L58 24V104z", a, s=0)
    c.p("M50 16H54L58 24V104H50z", b, s=0)
    c.p("M42 104V24L46 16H54L58 24V104z", s=1.8)
    c.p("M46 26V100M54 26V100", s=.5, col=ln)
    # 종탑 창·시계·첨탑·문
    c.p("M45 30h10v5h-10zM45 38h10v2h-10z", "#6C7E8A", s=.6)
    c.c(50, 47, 3.4, "#F3F2EC", s=1)
    c.p("M50 47V45M50 47h1.6", s=.6)
    c.p("M47 16L50 5L53 16z", "#9DA09C", s=1.3)
    c.p("M50 5V1.5M48.8 3h2.4", s=.9)
    c.p("M48 60h4v22h-4z", "#6C7E8A", s=.6)
    c.arch(50, 104, 9, 15, "#5B6F7B", s=1.2)
    # 레이프 에릭손 동상
    c.r(16, 97, 6, 7, "#8F918C", s=1)
    c.p("M19 97V90M17 92h4M19 88.6h.01", s=1.5, col="#5F7F7A")


@d
def peace_gate(c):
    c.shadow(50, 86)
    c.sun(92, 16, 4)
    # 네 무리의 굵은 콘크리트 기둥
    for x in (16, 26, 66, 76):
        c.p(f"M{x} 104L{x + 1} 60H{x + 7}L{x + 8} 104z", "#D9D8D2", s=1.5)
        c.l(x + 5.4, 62, x + 5.8, 103, s=.5)
    # 기둥 사이 보
    c.r(14, 60, 72, 5, "#BDBCB6", s=1.2)
    # 날개 지붕의 사신도 천장(단청)
    c.p("M4 34Q24 60 47 52V60H12Q6 48 4 34z", "#3E7F92", s=1.4)
    c.p("M96 34Q76 60 53 52V60H88Q94 48 96 34z", "#B8473C", s=1.4)
    c.p("M14 57q5-5 10-1t10-1q4-2 9 0M86 57q-5-5-10-1t-10-1q-4-2-9 0", s=1.1, col="#F2D36B")
    c.p("M10 49q4 2 8 1M90 49q-4 2-8 1M26 50l2 3 3-2M74 50l-2 3-3-2", s=.8, col="#F6EFD8")
    # 위로 치켜든 콘크리트 날개
    c.p("M3 30Q24 54 47 44V54Q24 62 4 36z", "#EFEEE8", s=1.8)
    c.p("M97 30Q76 54 53 44V54Q76 62 96 36z", "#E0DFD8", s=1.8)
    c.p("M7 37Q26 54 46 47M93 37Q74 54 54 47", s=.6)
    # 가운데 꺼지지 않는 불과 열주 받침
    c.r(46, 88, 8, 16, "#CBB99A", s=1.3)
    c.p("M50 88C44 80 48 74 50 66C52 74 56 80 50 88z", "#F0A63C", s=1.2)
    c.p("M50 86C48 82 49 78 50 75C51 78 52 82 50 86z", "#F7DA6E", s=0)
    c.r(8, 100, 84, 4, "#C9C6BB", s=1.2)
    c.birds(40, 20)


@d
def louvre(c):
    # 뒤쪽 궁전: 사암 벽, 슬레이트 망사르 지붕
    c.p("M6 58L10 48H90L94 58z", "#6E7C8E", s=1.4)
    c.p("M18 48v-5h6v5M46 48v-5h6v5M74 48v-5h6v5", "#D8C7A2", s=1)
    c.r(6, 58, 88, 40, "#E7D8B6", s=1.6)
    c.r(66, 58, 28, 40, "#D2C096", s=0)
    c.arches(7, 74, 86, 11, 17, "#6B7682", fill=.5)
    c.arches(7, 96, 86, 15, 17, "#6B7682", fill=.56)
    c.p("M6 62h88M6 76h88", s=.5)
    c.r(6, 58, 88, 40, "none", s=1.5)
    # 광장과 삼각 분수
    c.p("M4 104L8 96H92L96 104z", "#CFC6B2", s=1.2)
    # 유리 피라미드
    x0, x1, ax, ay = 14, 78, 46, 34
    c.poly([(x0, 100), (ax, ay), (x1, 100)], "#BFE3EE", s=0)
    c.poly([(ax, ay), (x1, 100), (58, 100)], "#8FC2D4", s=0)
    k, d_ = 8, ""
    for i in range(1, k):
        t = i / k
        d_ += f"M{n(x0 + (ax - x0) * t)} {n(100 + (ay - 100) * t)}L{n(x0 + (x1 - x0) * t)} 100"
        d_ += f"M{n(x1 + (ax - x1) * t)} {n(100 + (ay - 100) * t)}L{n(x0 + (x1 - x0) * (1 - t))} 100"
    c.p(d_, s=.55, col="#EEF8FA")
    c.poly([(x0, 100), (ax, ay), (x1, 100)], "none", s=1.9)
    # 작은 피라미드와 물
    c.poly([(4, 104), (11, 92), (18, 104)], "#BFE3EE", s=1.2)
    c.water(22, 100.5, 46, 4, "#8FD0E6")
    c.r(40, 92, 12, 8, "#6F8EA0", s=.9)
    c.people(84, 104, 2)


@d
def bank_china(c):
    a, b, w = "#7FB1CF", "#578BAD", "#F3F7F8"
    c.cloud(74, 20, .8)
    c.shadow(50, 58)
    # 화강암 포디움
    c.r(24, 92, 52, 12, "#CFC6B8", s=1.5)
    c.blocks(24, 92, 52, 12, 3, 7, s=.45, col="#8E8676")
    # 네 삼각 기둥이 서로 다른 높이에서 비스듬히 끝난다
    c.r(34, 56, 32, 36, a, s=0)
    c.r(50, 56, 16, 36, b, s=0)
    c.p("M34 56V38H50V56z", a, s=0)
    c.p("M34 38L50 10V38z", "#A9D2E7", s=0)
    c.p("M50 38L66 56H50z", "#3F7295", s=0)
    # 얇은 층선
    c.p("".join(f"M34 {y}H66" for y in range(60, 92, 4)) + "".join(f"M34 {y}H50" for y in range(42, 56, 4)), s=.3, col="#3F7295")
    # 큰 X자 흰 프레임
    c.p("M34 92L66 74M66 92L34 74M34 74L66 56M66 74L34 56M34 56L50 47L34 38M50 56L34 47M34 38L50 24", s=1.4, col=w)
    c.p("M50 38V92M34 74H66M34 56H66", s=1.4, col=w)
    c.p("M34 92V38L50 10V38L66 56V92z", s=1.9)
    # 쌍둥이 안테나
    c.p("M47.5 15V3M50 10V5", s=1.4)
    c.r(44, 96, 12, 8, "#5C7788", s=1)
    c.p("M30 104v-5h4v5M66 104v-5h4v5", s=.7)


@d
def hassan_ii(c):
    z, z2 = "#2F9C8C", "#1F7C72"
    c.birds(58, 24)
    # 파도치는 대서양
    c.water(4, 106, 90, 7, "#6FBEDC")
    # 기도실: 초록 기와 지붕, 말발굽 아치
    c.p("M36 104V74H92V104z", "#F0E5CC", s=1.6)
    c.p("M34 74L42 64H86L94 74z", z, s=1.6)
    c.p("M42 74v-10M50 74v-10M58 74v-10M66 74v-10M74 74v-10M82 74v-10", s=.5)
    c.r(36, 74, 56, 3, "#E2BD65", s=.9)
    for x in (42, 52, 62, 72, 82):
        c.p(f"M{x - 3.4} 104V92A4.2 4.2 0 1 1 {x + 3.4} 92V104z", "#4D7286", s=1)
    c.p("M36 82h56", s=.5, col="#B39F76")
    # 쌍 미나렛 대신 하나의 거대한 사각 미나렛
    c.r(17, 22, 19, 82, "#F0E5CC", s=0)
    c.r(31, 22, 5, 82, "#D9CBA9", s=0)
    # 젤리주 무늬 패널
    c.r(20, 26, 13, 28, z, s=1)
    d_ = "".join(f"M{20 + i * 3.25:.1f} {26 + j * 4 + (i % 2) * 2}l1.6 2-1.6 2-1.6-2z" for i in range(1, 4) for j in range(0, 6))
    c.p(d_, "#E8DDBB", s=0)
    c.r(20, 60, 13, 24, "#E9DCC0", s=.8)
    c.windows(20, 61, 13, 22, 3, 3, "#2F7F76", fill=.5)
    c.arch(26.5, 94, 9, 8, z, s=.9)
    c.p("M17 56h19M17 86h19", s=.7, col="#B39F76")
    c.r(17, 22, 19, 82, "none", s=1.9)
    # 총안 띠와 등불 탑
    c.r(15.5, 19, 22, 3.4, "#E2BD65", s=1.2)
    c.r(21, 8, 11, 11, z, s=1.4)
    c.arch(26.5, 18, 5, 8, "#E8DDBB", s=.6)
    c.p("M20 8L26.5 3.6L33 8z", z2, s=1.2)
    c.l(26.5, 3.6, 26.5, 1.6, s=1, col=GOLD2)
    c.p("M24.9 2.8a1.1 1.1 0 1 0 2.2 0a1.1 1.1 0 1 0-2.2 0z", GOLD, s=.5)


def _ball(c, x, y, r, f="#D9668F", f2="#B14A72"):
    """구슬 하나: 그늘, 위도선, 하이라이트."""
    c.c(x, y, r, f, s=1.8)
    c.p(f"M{n(x + r * .15)} {n(y - r * .96)}A{n(r)} {n(r)} 0 0 1 {n(x + r * .15)} {n(y + r * .96)}Q{n(x + r * .7)} {n(y)} {n(x + r * .15)} {n(y - r * .96)}z", f2, s=0)
    c.p(f"M{n(x - r * .94)} {n(y - r * .3)}Q{n(x)} {n(y - r * .1)} {n(x + r * .94)} {n(y - r * .3)}M{n(x - r * .94)} {n(y + r * .3)}Q{n(x)} {n(y + r * .55)} {n(x + r * .94)} {n(y + r * .3)}", s=.6)
    c.p(f"M{n(x - r * .55)} {n(y - r * .55)}q{n(r * .2)}-{n(r * .25)} {n(r * .5)}-{n(r * .25)}", s=1, col="#F8D0DF")
    c.c(x, y, r, "none", s=1.8)


@d
def pearl(c):
    s_, s2 = "#E7E6E2", "#BEBEBA"
    c.shadow(50, 56)
    c.cloud(72, 26, .7)
    c.cloud(12, 44, .6)
    # 세 갈래 경사 다리와 세 수직 기둥
    c.p("M22 104L44 80H48L32 104zM78 104L56 80H52L68 104z", s2, s=1.5)
    c.r(24, 100, 10, 4, "#CDBFA8", s=1.1)
    c.r(66, 100, 10, 4, "#CDBFA8", s=1.1)
    for x in (42, 47.5, 53):
        c.r(x, 28, 5, 62, s_, s=1.3)
    c.p("M36 100h28v4h-28z", "#CDBFA8", s=1.1)
    c.p("M43 86h14v14h-14z", s_, s=1.2)
    c.p("M40 100L46 88M60 100L54 88", s=.8)
    # 기둥 사이 작은 구슬들
    for y in (52, 58):
        c.c(50, y, 3, "#D9668F", s=1)
    # 큰 구슬 둘, 작은 구슬, 첨탑
    _ball(c, 50, 74, 14)
    _ball(c, 50, 40, 10)
    c.p("M45 29h10v-6h-10z", s_, s=1.2)
    c.p("M47.8 23V11h4.4v12z", s_, s=1.2)
    c.c(50, 13, 3.8, "#D9668F", s=1.3)
    c.p("M50 9.5V1.5", s=1.4)
    c.p("M48.8 6h2.4M49.2 3.6h1.6", s=.8)
    c.p("M36.2 74h27.6", s=.8, col="#F8D0DF")


@d
def dancing(c):
    # 왼쪽 프라하 이웃집(붉은 지붕)
    c.p("M6 104V58H22V104z", "#EBD9B4", s=1.5)
    c.p("M5 58L9 48H22V58z", "#BE6147", s=1.4)
    c.windows(8, 62, 13, 38, 2, 5, "#5D7080")
    c.p("M79 104V62H94V104z", "#E6C9A2", s=1.5)
    c.p("M78 62L83 53H94V62z", "#A85A44", s=1.4)
    c.windows(81, 65, 11, 34, 2, 5, "#5D7080")
    c.shadow(50, 58)
    # 프레드: 물결 창 띠의 콘크리트 탑
    c.p("M46 104V26Q62 21 78 26V104z", "#EDE3CE", s=1.8)
    c.r(70, 27, 8, 77, "#D4C6A9", s=0)
    for i, y in enumerate((34, 44, 54, 64, 74, 84)):
        o = 2.2 if i % 2 else -2.2
        c.p("".join(f"M{x + o} {y}h5.6v5.4h-5.6z" for x in (49, 57, 65)), "#5D7080", s=.6)
        c.p(f"M47 {y + 8}Q55 {y + 5} 62 {y + 8}T78 {y + 8}", s=.6, col="#A7977A")
    c.p("M46 104V26Q62 21 78 26V104z", s=1.8)
    # 메두사(금속 그물 돔)
    c.p("M52 25C50 14 56 10 62 10C69 10 74 15 72 25Q62 21 52 25z", "#C8CDD0", s=1.5)
    c.p("M54 15L68 23M58 11.5L72 19M70 13L55 23M64 10.5L52 19M62 10V22", s=.5)
    # 진저: 허리가 잘록한 유리 탑, 기둥 위에 올라앉는다
    glass = "M24 16C34 12 44 12 50 18C47 34 43 44 42 52C42 60 47 72 50 86H24C27 72 31 60 31 52C31 42 26 30 24 16z"
    c.p(glass, GLASS, s=0)
    c.p("M41 14C45 14 48 16 50 18C47 34 43 44 42 52C42 60 47 72 50 86H41C38 72 36 60 36 52C36 40 40 26 41 14z", GLASS2, s=0)
    c.p("M26 26Q37 23 48 26M29 36Q37 34 46 36M30.5 46Q37 45 43 46M31 56Q37 57 42.5 56M29.5 66Q37 68 45 66M27 76Q37 78 48 76M34 13V86M28 25C32 40 35 46 35 52C35 60 31 74 28 86", s=.5, col="#EAF6F8")
    c.p(glass, s=1.8)
    c.p("M27 86V104M35 86V104M43 86L47 104", s=1.8)
    c.r(24, 85, 26, 2, "#EDE3CE", s=1)


@d
def bilbao(c):
    t, t2, t3 = "#C9CFD3", "#A3ACB3", "#E6E9EA"
    c.water(4, 106, 90, 6.5, "#7FBEDD")
    # 라임스톤 기단과 살베 다리 쪽 낮은 동
    c.r(8, 92, 84, 12, "#DEC998", s=1.5)
    c.blocks(8, 92, 84, 12, 3, 12, s=.45, col="#A98F5F")
    # 티타늄 곡면 덩어리(뒤에서 앞으로)
    c.p("M58 92C58 72 62 58 72 54C82 58 90 72 90 92z", t2, s=1.6)
    c.p("M64 92Q66 72 72 58M78 92Q78 72 72 58M60 76Q72 70 88 78M62 66Q72 60 84 66", s=.5, col="#6F7B83")
    # 꼭대기로 터져 오르는 금속 꽃잎
    c.p("M40 44C44 30 52 16 66 12C64 22 66 30 72 38C64 40 60 46 58 54z", t3, s=1.6)
    c.p("M45 40Q52 26 63 16M50 44Q56 32 66 24M54 48Q60 38 69 36", s=.5, col="#6F7B83")
    c.p("M36 92C34 70 40 44 58 30C60 42 68 58 72 92z", t, s=1.7)
    c.p("M43 92C42 70 48 50 57 38M52 92C52 72 55 55 60 42M62 92C62 76 62 62 63 52M38 72Q54 66 68 74M40 58Q52 52 64 58M37 84Q54 78 70 84", s=.5, col="#6F7B83")
    c.p("M10 92C10 74 12 56 26 42C20 38 18 32 20 24C32 26 42 34 46 46C50 60 50 78 50 92z", t3, s=1.8)
    c.p("M26 42C34 46 40 54 42 64C44 74 44 84 44 92H50C50 78 50 60 46 46C42 34 32 26 20 24C18 32 20 38 26 42z", t2, s=0)
    # 물고기 비늘 패널
    c.p("M12 82Q28 76 49 82M12 72Q28 66 48 72M15 62Q28 56 47 62M20 52Q30 46 44 50M22 42Q32 37 41 40M21 32Q29 29 36 31M18 92Q18 72 26 52M28 92Q28 74 33 54M38 92Q38 74 39 56", s=.5, col="#7F8A92")
    c.p("M10 92C10 74 12 56 26 42C20 38 18 32 20 24C32 26 42 34 46 46C50 60 50 78 50 92z", s=1.8)
    # 유리 커튼
    c.p("M50 92V70L60 62C62 72 64 82 64 92z", GLASS, s=1.2)
    c.p("M55 92V66M60 92V62M50 80H64", s=.5, col="#EAF6F8")
    c.r(14, 96, 10, 8, "#5B7686", s=.9)
    c.people(28, 104, 2)


@d
def rong_khun(c):
    w, m, g = "#FBFBF8", "#C8DCEA", "#8FB2CB"
    c.water(4, 106, 90, 7, "#A9DCEB")
    c.shadow(50, 84)
    # 기단과 다리
    c.p("M14 104V94H86V104z", w, s=1.5)
    c.p("M20 94v10M30 94v10M40 94v10M60 94v10M70 94v10M80 94v10", s=.5, col=g)
    # 벽, 금박 대신 거울 조각
    c.r(24, 68, 52, 26, w, s=1.7)
    c.r(60, 68, 16, 26, "#E6ECF0", s=0)
    for x in (30, 70):
        c.arch(x, 92, 6, 16, m, s=1.1)
        c.p(f"M{x} 92V80", s=.5)
    c.r(24, 68, 52, 26, "none", s=1.7)
    # 층층 지붕: 차파(뿔) 끝이 하늘로 치켜든다
    for w_, y, h in ((68, 68, 16), (50, 54, 14), (34, 42, 12)):
        a, b = 50 - w_ / 2, 50 + w_ / 2
        c.p(f"M{n(a)} {y}Q{n(a + 2)} {y - 2} {n(a - 1)} {y - 7}Q{n(a + 7)} {y - 2} {n(a + 8)} {y - 3}L50 {y - h}L{n(b - 8)} {y - 3}Q{n(b - 7)} {y - 2} {n(b + 1)} {y - 7}Q{n(b - 2)} {y - 2} {n(b)} {y}z", w, s=1.6)
        c.p(f"M{n(a + 5)} {y - 2}L50 {y - h + 3}L{n(b - 5)} {y - 2}", s=.9, col=g)
        c.p(f"M{n(a + 10)} {y - 2}L50 {y - h + 6}L{n(b - 10)} {y - 2}", s=.5, col=g)
        c.p(f"M{n(a + 2)} {y - .6}H{n(b - 2)}", s=1, col=m)
    # 가운데 박공 불꽃과 프라상 첨탑
    c.p("M40 68Q50 50 60 68z", m, s=1.1)
    c.p("M50 56Q46 62 50 67Q54 62 50 56zM44 66q2-4 4-5M56 66q-2-4-4-5", s=.6)
    c.p("M42 30h16l-2-6h-12z", w, s=1.3)
    c.p("M45 24C45 16 48 10 50 3C52 10 55 16 55 24z", w, s=1.5)
    c.p("M46 20h8M47 15h6M48 10h4", s=.7, col=g)
    # 문과 곡선 다리
    c.arch(50, 94, 10, 18, "#6C8BA1", s=1.2)
    c.p("M30 106Q50 92 70 106H64Q50 98 36 106z", w, s=1.3)
    c.p("M32 104l-1-4M41 99v-3M50 97v-3M59 99v-3M68 104l1-4", s=.8, col=g)


@d
def petronas(c):
    a, b, ln = "#D5DADD", "#A9B2B7", "#7F8B91"
    c.shadow(50, 66)
    c.r(14, 94, 72, 10, "#C9C3B3", s=1.5)
    c.r(16, 97, 68, 4, "#6F93A6", s=.7)
    c.vlines(16, 97, 68, 4, 13, s=.4)
    def tower(x):
        # 팔각별 평면이 계단처럼 좁아진다
        y = 94
        for w, y2 in ((22, 54), (19, 42), (16, 32), (12, 24), (8, 17), (5, 12)):
            c.r(x - w / 2, y2, w, y - y2, a, s=1.4)
            c.r(x + w * .16, y2 + .6, w * .34, y - y2 - 1, b, s=0)
            c.r(x - w / 2, y2, w, y - y2, "none", s=1.4)
            y = y2
        c.p(f"M{x} 12V2", s=1.5)
        c.p(f"M{x - 1.5} 9h3M{x - 1} 6h2", s=.8)
        d_ = "".join(f"M{x + o} 54V93" for o in (-7, -3.5, 0, 3.5, 7))
        d_ += "".join(f"M{x + o} 42V53" for o in (-5, 0, 5))
        d_ += "".join(f"M{x - 11} {yy}h22" for yy in range(58, 94, 6))
        c.p(d_, s=.4, col=ln)
    tower(29)
    tower(69)
    # 스카이브리지와 V자 받침
    c.p("M40 58h18v5h-18z", "#E7EBED", s=1.4)
    c.p("M40 63h18", s=.5)
    c.p("M45 63L38 76M53 63L60 76", s=1.1)
    c.p("M44 59v3M49 59v3M54 59v3", s=.5)


@d
def burj_arab(c):
    c.sun(84, 16, 4.5)
    # 바다와 인공섬, 둑길
    c.water(4, 105, 90, 8, "#62BBDB")
    c.p("M14 104L18 97H82L86 104z", "#EAD9A8", s=1.4)
    # 돛: 왼쪽 곧은 돛대, 오른쪽으로 부푼 하얀 천
    sail = "M30 97L38 6C50 16 72 48 76 80C76 86 76 92 74 97z"
    c.p(sail, "#FCFBF6", s=0)
    c.p("M56 28C68 44 75 62 76 80C76 86 76 92 74 97H62C66 76 64 50 56 28z", "#D9E5EA", s=0)
    # 돛 재봉선
    c.p("M36 26Q54 28 60 34M35 38Q58 40 67 46M34 50Q60 52 72 58M33 62Q62 64 75 72M32 76Q62 78 76 84M31 88Q60 89 75 92", s=.6, col="#A7B6BD")
    c.p(sail, s=1.9)
    # 뒤쪽 X자 외골격(돛대)
    c.p("M30 97L38 6L28 12L20 97z", "#F0F0EA", s=1.7)
    c.p("M29 20L37 20M28 34L36.6 34M26 48L35 48M25 62L34 62M23 76L33 76M22 90L31 90", s=.7)
    c.p("M29 20L36.6 34L26 48L34 62L23 76L31 90M37 20L28 34L35 48L25 62L33 76L22 90", s=.9, col="#7C8B93")
    # 헬기장
    c.e(16, 25, 12, 2.6, "#7FBB6A", s=1.3)
    c.p("M12 27.4L28 32", s=1.1)
    c.p("M14 25h4M16 24v2", s=.6, col="#fff")
    c.p("M28 26L30 30", s=.9)
    # 낮은 층 유리 로비
    c.r(36, 90, 26, 7, "#6F9FB4", s=1)
    c.vlines(36, 90, 26, 7, 5, s=.5, col="#fff")
    c.birds(52, 12)


@d
def london_eye(c):
    cx, cy, R = 47, 46, 38
    # 템스강
    c.water(4, 106, 88, 7, "#7DB6CC")
    c.r(6, 100, 80, 4, "#BFB4A0", s=1.2)
    # 뒤쪽 받침 다리
    c.p("M47 46L72 100H64L45 50z", "#E7E8E7", s=1.4)
    c.p("M47 46L78 100H72", s=1.1)
    # 스포크
    d_ = "".join(f"M{cx} {cy}L{n(cx + R * math.cos(i * math.pi / 16))} {n(cy + R * math.sin(i * math.pi / 16))}" for i in range(32))
    c.p(d_, s=.3, col="#7E8B92")
    # 이중 테와 트러스
    c.c(cx, cy, R, "none", s=2)
    c.c(cx, cy, R - 3.5, "none", s=1)
    d_ = ""
    for i in range(48):
        a, a2 = i * math.pi / 24, (i + 1) * math.pi / 24
        d_ += f"M{n(cx + R * math.cos(a))} {n(cy + R * math.sin(a))}L{n(cx + (R - 3.5) * math.cos(a2))} {n(cy + (R - 3.5) * math.sin(a2))}"
    c.p(d_, s=.4)
    # 캡슐 32개
    d_ = ""
    for i in range(32):
        a = i * math.pi / 16
        x, y = cx + (R + 2) * math.cos(a), cy + (R + 2) * math.sin(a)
        d_ += f"M{n(x - 2)} {n(y)}a2 1.5 0 1 0 4 0a2 1.5 0 1 0-4 0z"
    c.p(d_, "#BFE3EE", s=.7)
    # 허브와 앞쪽 경사 다리
    c.p("M47 46L21 100H29L49 50z", "#F2F2F0", s=1.6)
    c.p("M33 75h12", s=.8)
    c.c(cx, cy, 4.5, "#C9CCCD", s=1.5)
    c.c(cx, cy, 1.4, O, s=0)
    c.people(8, 100, 3)


@d
def gherkin(c):
    li, da = "#C6E2EA", "#3F6F8C"
    # 런던 시티의 낮은 석조 이웃
    c.p("M6 104V76H24V104z", "#DCCFB5", s=1.4)
    c.windows(8, 79, 14, 22, 3, 4, "#6B7C88")
    c.p("M76 104V82H92V104z", "#CFC2A8", s=1.4)
    c.windows(78, 85, 12, 16, 3, 3, "#6B7C88")
    c.cloud(76, 24, .8)
    c.shadow(50, 54)
    body = "M28 104C24 74 26 40 40 18C44 11 47 7 50 5C53 7 56 11 60 18C74 40 76 74 72 104z"
    c.p(body, li, s=0)
    c.p("M63 23C72 40 74 74 72 104H66C68 74 67 44 63 23z", "#A4C8D5", s=0)
    # 윤곽 반폭표(베지어 표본)
    def W(y):
        if y < 18:
            return max(.5, (y - 5) * 10 / 13)
        t = (y - 18) / 86
        return 10 + 13.2 * math.sin(min(1, t * 1.25) * math.pi / 2) - 1.2 * t
    # 나선 유리 띠
    d_ = ""
    for o in range(6):
        run = []
        for y in range(104, 7, -4):
            ph = o * math.pi / 3 + (104 - y) * .055
            a, b = ph, ph + .42
            a = (a + math.pi) % (2 * math.pi) - math.pi
            b = a + .42
            if -math.pi / 2 - .42 < a < math.pi / 2:
                w = W(y) - .4
                run.append((50 + w * math.sin(max(a, -math.pi / 2)), 50 + w * math.sin(min(b, math.pi / 2)), y))
            elif run:
                break
        if len(run) > 1:
            d_ += "M" + "L".join(f"{n(x)} {y}" for x, _, y in run) + "L" + "L".join(f"{n(x)} {y}" for _, x, y in reversed(run)) + "z"
    c.p(d_, da, s=0)
    # 마름모 격자
    d_ = "".join(f"M{n(50 - W(y))} {y}Q50 {y + 1.6} {n(50 + W(y))} {y}" for y in range(14, 104, 9))
    d_ += "M50 5C44 30 37 70 37 104M50 5C56 30 63 70 63 104M50 5V104"
    c.p(d_, s=.4, col="#EEF8FA")
    c.p(body, s=1.9)
    c.c(50, 7.6, 1.1, "#E5F3F6", s=.5)
    c.r(40, 98, 20, 6, "#5F7A8A", s=1)
    c.vlines(40, 98, 20, 6, 4, s=.4, col="#fff")


@d
def disney_hall(c):
    m, m2, m3 = "#E8ECEF", "#BEC6CC", "#F7F8F9"
    c.sun(86, 18, 4.5)
    c.shadow(50, 84)
    # 석회암 기단과 계단
    c.p("M6 104V90H90V104z", "#E3D5B8", s=1.5)
    c.p("M8 104h18l-3-3H11zM8 101l3-3h12l3 3", "#CFBF9E", s=.9)
    # 돛처럼 치솟는 스테인리스 판
    c.p("M58 90C60 74 66 62 86 52C84 66 84 80 88 90z", m2, s=1.6)
    c.p("M68 90Q70 72 80 58M76 90Q76 76 83 62", s=.5)
    c.p("M36 90C36 64 46 40 72 28C66 48 66 72 70 90z", m, s=1.8)
    c.p("M44 90C46 66 54 46 67 34M54 90C54 70 60 52 67 44M40 74L66 80M44 58L65 64", s=.5)
    c.p("M14 90C14 66 18 42 32 22C40 38 46 60 46 90z", m3, s=1.8)
    c.p("M32 22C40 38 46 60 46 90H38C38 66 36 42 32 22z", m2, s=0)
    c.p("M20 90C20 70 24 50 31 34M28 90C29 70 30 50 32 36M16 76Q30 72 45 76M19 58Q30 54 42 58M25 40Q30 38 37 40", s=.5)
    c.p("M14 90C14 66 18 42 32 22C40 38 46 60 46 90z", s=1.8)
    # 앞 곡면 + 유리 로비
    c.p("M4 90C10 76 16 68 26 64C30 72 32 80 32 90z", m, s=1.5)
    c.p("M10 90Q14 78 24 68M18 90Q20 80 26 72", s=.5)
    c.p("M46 90V74Q52 72 58 76V90z", GLASS, s=1.1)
    c.p("M52 90V73M46 82H58", s=.5, col="#EAF6F8")
    c.r(36, 94, 40, 10, "#5D7584", s=1)
    c.vlines(36, 94, 40, 10, 7, s=.5, col="#E8ECEF")
    # 자카란다 나무
    c.c(84, 80, 6, "#7FB765", s=1.2)
    c.r(83.2, 85, 1.6, 6, WOOD, s=.6)


@d
def taipei101(c):
    a, b, ln = "#6FB7AC", "#4A9389", "#2F6C66"
    c.shadow(50, 66)
    # 저층 쇼핑몰
    c.p("M14 104V92L32 86H68L86 92V104z", "#C9DAD6", s=1.5)
    c.p("M18 104V95h10v9zM72 104V95h10v9z", "#5F8E8A", s=.8)
    c.hlines(14, 92, 72, 4, 1, s=.5)
    # 사다리꼴 받침(스물다섯 층)과 여의 장식
    c.p("M32 90L36 58H64L68 90z", a, s=1.7)
    c.p("M57 58H64L68 90H60z", b, s=0)
    c.p("M36 66H64M35 74H65M34 82H66M43 58L41 90M50 58V90M57 58L59 90", s=.45, col=ln)
    for x in (41, 59):
        c.c(x, 63, 3, "#F3E3A6", s=1)
        c.p(f"M{x - 1.4} 63a1.4 1.4 0 1 1 2.8 0", s=.6)
    c.p("M32 90L36 58H64L68 90z", s=1.7)
    # 위로 벌어지는 여덟 마디(대나무·탑)
    y = 58
    for i in range(8):
        h = 5.4
        t = y - h
        c.p(f"M41 {n(y)}L37.6 {n(t)}H62.4L59 {n(y)}z", a, s=1.4)
        c.p(f"M55 {n(y)}L56.5 {n(t)}H62.4L59 {n(y)}z", b, s=0)
        c.p(f"M44 {n(y)}L42.8 {n(t)}M50 {n(y)}V{n(t)}M56 {n(y)}L57.2 {n(t)}M39.5 {n(t + 2.6)}H60.5", s=.4, col=ln)
        c.p(f"M41 {n(y)}L37.6 {n(t)}H62.4L59 {n(y)}z", s=1.4)
        y = t
    # 꼭대기층과 첨탑
    c.p(f"M43 {n(y)}V{n(y - 3)}H57V{n(y)}z", a, s=1.2)
    y -= 3
    c.p(f"M45.5 {n(y)}V{n(y - 3)}H54.5V{n(y)}z", "#D6E6E2", s=1.1)
    y -= 3
    c.p(f"M48 {n(y)}L49.2 2H50.8L52 {n(y)}z", "#A9B8B5", s=1.1)


@d
def crooked(c):
    w, w2, r, r2 = "#F4E2B6", "#E0C48C", "#3F8F92", "#2F7176"
    c.shadow(50, 84)
    # 사람 키에 맞춘 두 층의 일그러진 상가
    wall = "M7 104C11 94 5 82 9 70C12 62 8 54 13 48C36 44 62 42 84 46C87 54 93 62 90 74C88 86 93 96 91 104z"
    c.p(wall, w, s=0)
    c.p("M74 44L84 46C87 54 93 62 90 74C88 86 93 96 91 104H78C82 92 78 82 80 70C81 60 78 52 74 44z", w2, s=0)
    c.p("M8 76Q28 70 48 75T90 72", s=.9, col="#B8945E")
    c.p(wall, s=1.9)
    # 창: 어느 것도 곧지 않다
    def win(x, y, sk, wd=9, h=11):
        c.p(f"M{x} {y}Q{x + wd / 2} {y - 3} {x + wd} {y + sk}Q{x + wd + 2} {y + h / 2 + sk} {x + wd - 1} {y + h}Q{x + wd / 2} {y + h + 2} {x + 1} {y + h - sk}Q{x - 1} {y + h / 2} {x} {y}z", "#5D7C8E", s=1.2)
        c.p(f"M{x + wd / 2} {y - 1}Q{x + wd / 2 + 2} {y + h / 2} {x + wd / 2} {y + h}M{x} {y + h / 2}Q{x + wd / 2} {y + h / 2 + 2} {x + wd + 1} {y + h / 2}", s=.6, col="#F7EED8")
    for x, y, sk in ((14, 55, 2), (31, 53, -1), (49, 52, 2), (66, 54, -1)):
        win(x, y, sk)
    win(12, 81, -1, 10, 12)
    win(55, 80, 2, 9, 12)
    win(71, 82, 1, 9, 11)
    # 쇼윈도와 굽은 문
    c.p("M30 104C28 92 30 84 37 80C46 80 49 92 47 104z", "#B5693F", s=1.4)
    c.p("M38 81C37 88 38 96 37 104M31 92Q38 89 47 93", s=.6)
    c.c(43, 95, 1, GOLD, s=.5)
    # 물결치는 청록 비늘 지붕
    roof = "M4 49C10 38 12 28 22 22C30 12 42 20 50 14C60 8 70 18 78 21C86 30 90 42 95 47C82 51 72 45 58 47C40 41 24 53 4 49z"
    c.p(roof, r, s=0)
    c.p("M66 13C72 15 75 19 78 21C86 30 90 42 95 47C88 49 80 48 72 47C76 36 74 24 66 13z", r2, s=0)
    d_ = ""
    for y, xs in ((43, range(10, 88, 7)), (36, range(16, 82, 7)), (29, range(20, 76, 7)), (22, range(30, 70, 7))):
        for i, x in enumerate(xs):
            yy = y + 1.6 * math.sin(x * .28)
            d_ += f"M{x} {n(yy)}q3-3 6 0"
    c.p(d_, s=.5, col="#D6EEE9")
    c.p(roof, s=1.9)
    # 지붕창과 구불구불한 굴뚝
    c.p("M30 34Q30 25 38 24Q46 25 46 34Q38 32 30 34z", w, s=1.3)
    c.p("M34 32Q34 28 38 27.6Q42 28 42 32z", "#5D7C8E", s=.8)
    c.p("M58 15C56 10 62 8 60 2H68C70 8 64 10 66 14z", "#C96B4E", s=1.4)
    c.p("M59.6 6h8.6M60 10h6", s=.5)


@d
def turning(c):
    c.water(4, 106, 88, 6.5, "#8AC7DE")
    c.birds(72, 22)
    c.shadow(50, 50)
    # 저층 기단
    c.r(30, 96, 40, 8, "#E4E6E6", s=1.4)
    c.r(32, 99, 36, 3, "#5F8496", s=.6)
    # 아홉 큐브: 평면을 90도 돌려 쌓는다
    R, cx = 21, 50
    k, top, bot = 9, 6, 96
    h = (bot - top) / k
    wn = ""
    for i in range(k):
        y0 = bot - i * h
        y1 = y0 - h + 1.2
        th = math.radians(i / (k - 1) * 90)
        xs = [cx + R * math.cos(th + math.pi / 4 + j * math.pi / 2) for j in range(4)]
        ds = [math.sin(th + math.pi / 4 + j * math.pi / 2) for j in range(4)]
        front = sorted(range(4), key=lambda j: ds[j])[:3]
        f = sorted(front, key=lambda j: xs[j])
        a, m, b = xs[f[0]], xs[f[1]], xs[f[2]]
        c.p(f"M{n(a)} {n(y0)}V{n(y1)}H{n(m)}V{n(y0)}z", "#F7F8F7", s=1.3)
        c.p(f"M{n(m)} {n(y0)}V{n(y1)}H{n(b)}V{n(y0)}z", "#CFD7DA", s=1.3)
        # 층 창
        for yy in (y0 - h * .3, y0 - h * .62):
            if m - a > 3:
                wn += f"M{n(a + 1)} {n(yy)}H{n(m - 1)}"
            if b - m > 3:
                wn += f"M{n(m + 1)} {n(yy)}H{n(b - 1)}"
    c.p(wn, s=1, col="#5F8496")
    # 등뼈 같은 강철 외골격
    mid = []
    for i in range(k + 1):
        y = bot - i * h
        th = math.radians(min(1, i / k) * 90)
        mid.append((cx + (R + 5) * math.sin(th - .75), y, cx + (R - 4) * math.sin(th - .75)))
    d_ = "M" + "L".join(f"{n(a)} {n(y)}" for a, y, _ in mid)
    c.p(d_, s=1.3, col="#6B7880")
    z = ""
    for j, (a, y, b) in enumerate(mid):
        z += f"M{n(a)} {n(y)}L{n(b)} {n(y - (h if j < k else 0))}"
    c.p(z, s=.6, col="#6B7880")


@d
def akshardham(c):
    p, p2, wh, wh2 = "#E2A07F", "#C7825F", "#F7EFE0", "#E2D5BE"
    c.water(4, 106, 90, 7, "#8FD0E0")
    c.shadow(50, 86)
    # 코끼리 기단(가젠드라 피트)
    c.r(8, 92, 84, 12, p, s=1.6)
    c.r(8, 92, 84, 2.4, p2, s=.8)
    d_ = "".join(f"M{x} 103v-4q0-3 3-3h3q3 0 3 3v4h-1.6v-2.6h-5v2.6zM{x + 9} 99q1.6 1 1 4" for x in range(11, 86, 12))
    c.p(d_, wh2, s=.5)
    # 본당: 분홍 사암 + 흰 대리석
    c.r(20, 68, 60, 24, p, s=1.6)
    c.r(62, 68, 18, 24, p2, s=0)
    # 정면 기둥 문
    c.columns(23, 72, 54, 19, 10, wh, wh2, cw=2.6)
    c.r(20, 68, 60, 4, wh, s=1.2)
    c.vlines(20, 68, 60, 4, 19, s=.4)
    c.arch(50, 91, 10, 15, "#7A5745", s=1)
    c.r(20, 68, 60, 24, "none", s=1.6)
    # 지붕의 작은 돔 + 난간
    c.r(16, 64, 68, 4, wh2, s=1.2)
    for x in (22, 34, 66, 78):
        c.r(x - 4, 56, 8, 8, p, s=1)
        c.dome(x, 56, 4.4, wh, h=5)
        c.l(x, 50, x, 47, s=.9, col=GOLD2)
    # 큰 돔 둘과 중앙 돔
    c.r(38, 44, 24, 20, p, s=1.4)
    c.r(55, 44, 7, 20, p2, s=0)
    c.arches(39, 62, 22, 12, 4, "#7A5745", fill=.5)
    c.r(38, 44, 24, 20, "none", s=1.4)
    c.p("M40 44h20M39 50h22", s=.5)
    c.dome(50, 44, 14, wh, wh2, ribs=4, h=16)
    c.p("M36 44H64", s=1.5)
    c.p("M46.5 28h7l-1.6-4h-3.8z", GOLD, s=1)
    c.p("M50 24q-2.4-3 0-7q2.4 4 0 7z", GOLD, s=.9)
    c.l(50, 17, 50, 10, s=1.1, col=GOLD2)
    # 양쪽 시카라 탑(옥수수 모양)
    for x in (10, 90):
        c.p(f"M{x - 4} 92V70C{x - 4} 62 {x - 1} 58 {x} 54C{x + 1} 58 {x + 4} 62 {x + 4} 70V92z", "#F0DCC3" if x < 50 else "#DBBE9F", s=1.3)
        c.p(f"M{x - 4} 76h8M{x - 4} 70h8M{x - 3} 65h6M{x} 66V90", s=.45)


@d
def sheikh_zayed(c):
    w, w2, g = "#FDFCF7", "#E3E3DA", "#E4B949"
    c.water(4, 106, 90, 7, "#7FC4DE")
    c.shadow(50, 90)
    # 네 미나렛(가늘고 돔보다 높다)
    def mina(x, t, wd):
        c.r(x - wd / 2, t, wd, G - t, w, s=1.3)
        c.p(f"M{n(x - wd / 2 - 1)} {t + 16}h{n(wd + 2)}M{n(x - wd / 2 - 1)} {t + 34}h{n(wd + 2)}", s=1.2)
        c.r(x - wd / 2 - .8, t - 2, wd + 1.6, 2, g, s=.8)
        c.dome(x, t - 2, wd / 2, w, h=3.6)
        c.l(x, t - 5.6, x, t - 9, s=1, col=g)
    mina(25, 26, 3.6)
    mina(75, 26, 3.6)
    # 뒤쪽 돔 무리
    for x, r in ((33, 7), (67, 7), (42, 8), (58, 8)):
        c.dome(x, 60, r, w2, h=10)
        c.l(x, 50, x, 46, s=.9, col=g)
    # 드럼과 큰 돔
    c.r(35, 48, 30, 12, w, s=1.4)
    c.arches(36, 59, 28, 8, 8, "#7E9CAF", fill=.55)
    c.dome(50, 48, 17, w, w2, h=22)
    c.p("M33 48H67", s=1.5)
    c.l(50, 26, 50, 16, s=1.3, col=g)
    c.c(50, 18, 1.3, g, s=.6)
    # 본 건물과 뾰족 아치 회랑(금빛 기둥)
    c.r(16, 60, 68, 32, w, s=1.7)
    c.r(66, 60, 18, 32, w2, s=0)
    d_ = "".join(f"M{x} 91V77Q{x} 73 {x + 3} 70.5Q{x + 6} 73 {x + 6} 77V91z" for x in range(18, 80, 8))
    c.p(d_, "#7E9CAF", s=.9)
    c.p("".join(f"M{x + 7} 91V76" for x in range(18, 74, 8)), s=1.1, col=g)
    c.p("M16 64h68M16 67h68", s=.5)
    c.r(16, 60, 68, 32, "none", s=1.7)
    for x in (20, 80):
        c.dome(x, 60, 5, w, h=6)
    # 앞 회랑과 모서리 탑
    c.r(8, 92, 84, 12, w2, s=1.5)
    c.arches(9, 103, 82, 9, 14, "#7E9CAF", fill=.55)
    mina(8, 30, 4.4)
    mina(92, 30, 4.4)


@d
def birds_nest(c):
    st, st2, re_ = "#B9BEBE", "#7E8688", "#C9483B"
    c.cloud(14, 24, .8)
    c.shadow(50, 90)
    def top(x):
        t = (x - 50) / 44
        return 77 - 29 * (1 - t * t) ** .5 + 5 * (1 - t * t) ** 2
    def bot(x):
        t = (x - 50) / 44
        return min(104, 77 + 34 * (1 - t * t) ** .5)
    xs = [6 + i * 4 for i in range(23)]
    body = "M" + "L".join(f"{x} {n(top(x))}" for x in xs) + "L" + "L".join(f"{x} {n(bot(x))}" for x in reversed(xs)) + "z"
    c.p(body, "#6D7476", s=0)
    # 안쪽 붉은 벽, 위쪽 관중석 틈
    c.p("M16 92C18 72 30 68 50 68C70 68 82 72 84 92Q50 100 16 92z", re_, s=0)
    c.e(50, 58, 25, 5, "#D9DCDC", s=1.1)
    c.e(50, 58, 18, 2.8, "#83B774", s=.8)
    # 얽힌 강철 띠
    def clip(x0, y0, x1, y1):
        o, s_, e = None, "", None
        for t in [i / 40 for i in range(41)]:
            x, y = x0 + (x1 - x0) * t, y0 + (y1 - y0) * t
            ok = 7 < x < 93 and top(x) + .6 < y < bot(x) - .4
            if ok and not (34 < x < 66 and 54 < y < 62):
                o = o or (x, y)
                e = (x, y)
            elif o:
                s_ += f"M{n(o[0])} {n(o[1])}L{n(e[0])} {n(e[1])}"
                o = None
        if o:
            s_ += f"M{n(o[0])} {n(o[1])}L{n(e[0])} {n(e[1])}"
        return s_
    a_ = "".join(clip(x, 106, x + 42, 48) for x in range(-36, 94, 12))
    b_ = "".join(clip(x + 42, 106, x, 48) for x in range(-32, 96, 12))
    e_ = "".join(clip(x, 106, x + 14, 48) for x in range(-4, 102, 16)) + "".join(clip(0, y, 100, y + 4) for y in (68, 82, 94))
    c.p(a_ + b_, s=2, col=st2)
    c.p(a_ + b_, s=1.2, col=st)
    c.p(e_, s=1.5, col="#D3D6D6")
    c.p(body, s=1.9)
    c.r(40, 98, 20, 6, "#4F5659", s=1)
    c.p("M44 104v-6M50 104v-6M56 104v-6", s=.5, col="#fff")


@d
def oslo_opera(c):
    m, m2, m3 = "#FBFAF5", "#E2E3DC", "#BFD6DF"
    c.cloud(12, 22, .7)
    c.water(4, 106, 90, 7, "#6DB5CF")
    # 알루미늄 무대탑
    c.r(50, 28, 28, 34, "#EEF0EE", s=0)
    c.r(70, 28, 8, 34, "#CDD3D3", s=0)
    c.vlines(50, 29, 28, 33, 13, s=.45, col="#8E9896")
    c.r(50, 28, 28, 34, "none", s=1.7)
    # 비스듬한 유리 로비
    c.p("M26 104L58 66H93V104z", m3, s=1.3)
    c.p("M64 67V96M71 67V96M78 67V96M85 67V96M52 74H93M45 82H93M39 90H93", s=.5, col="#EDF7FA")
    # 물에서 올라와 지붕이 되는 대리석 면(걸어 오른다)
    c.p("M4 104L44 60H94V66H58L26 104z", m, s=1.9)
    c.p("M16 91H38M26 80H48M36 69H56M24 79L34 104M34 68L44 66M46 60L49 66M60 60V66M72 60V66M84 60V66", s=.4, col="#A9ABA2")
    c.p("M44 60L58 66", s=.8)
    c.p("M26 104L58 66V72L34 104z", m2, s=1.1)
    # 물가 턱
    c.r(34, 97, 60, 7, m, s=1.4)
    c.vlines(34, 97, 60, 7, 9, s=.45, col="#A9ABA2")
    # 지붕 위를 걷는 사람들
    c.p("M18 88v-3M18 83.6h.01M30 75v-3M30 70.6h.01M40 64v-3M40 59.6h.01", s=1)
    # 물 위 유리 조각
    c.p("M64 106L72 99L77 103L80 106z", "#E8F1F2", s=.8)


@d
def incheon(c):
    co, co2 = "#DEDFDB", "#B8BAB6"
    c.birds(40, 12)
    c.cloud(74, 18, .7)
    c.water(4, 104, 90, 9, "#7FBFD8")
    # 송도 스카이라인
    c.p("M80 70V58h4v-6h4v6h4v12z", "#C5D5DC", s=.8)
    # 역Y자 주탑: 앞은 크게, 뒤는 작게
    def pylon(x, top, w, deck, base, f):
        ya, yb = top + (deck - top) * .45, top + (deck - top) * .62
        c.p(f"M{n(x - w)} {base}L{n(x - 1.6)} {n(ya)}H{n(x + 1.6)}L{n(x + w)} {base}H{n(x + w - 3.4)}L{n(x)} {n(yb)}L{n(x - w + 3.4)} {base}z", f, s=1.5)
        c.p(f"M{n(x - 2)} {n(ya + .6)}L{n(x - 1.5)} {top}H{n(x + 1.5)}L{n(x + 2)} {n(ya + .6)}z", f, s=1.5)
        c.r(x + .3, top + .6, 1, (deck - top) * .44, co2, s=0)
    pylon(66, 30, 9, 72, 104, "#D2D3CF")
    pylon(30, 8, 14, 72, 104, co)
    # 부챗살 케이블
    d_ = ""
    for i in range(1, 9):
        y = 11 + i * 2.6
        d_ += f"M30 {n(y)}L{n(30 - i * 3.1)} 70M30 {n(y)}L{n(30 + i * 2.5)} 70"
    for i in range(1, 7):
        y = 32 + i * 2
        d_ += f"M66 {n(y)}L{n(66 - i * 2.7)} 70M66 {n(y)}L{n(66 + i * 3.3)} 70"
    c.p(d_, s=.45, col="#6B7C86")
    # 상판과 교각, 난간
    c.p("M5 70H94V75H5z", "#EFEEE9", s=1.5)
    c.p("M5 72.5H94", s=.5)
    c.p("M9 75V104H13V75M86 75V104H90V75", "#CFCFCA", s=1.3)
    c.p("M8 70v-1.5M20 70v-1.5M42 70v-1.5M54 70v-1.5M78 70v-1.5", s=.8)
    # 작은 배
    c.p("M44 106L46 110H54L56 106z", "#D65A45", s=.9)
    c.p("M50 106V101L54 105", s=.7)


@d
def marina_bay(c):
    a, b, ln = "#C8D8E0", "#9CB4C2", "#6E8A99"
    c.water(4, 106, 90, 7, "#6FB5D3")
    c.shadow(46, 80)
    # 세 동: 두 다리가 위에서 합쳐지는 A자
    for x in (10, 34, 58):
        leg = f"M{x} 100L{x + 6} 24H{x + 20}L{x + 26} 100H{x + 17}L{x + 13} 46L{x + 9} 100z"
        c.p(leg, a, s=0)
        c.p(f"M{x + 15} 24H{x + 20}L{x + 26} 100H{x + 20}z", b, s=0)
        d_ = ""
        for y in range(30, 100, 6):
            t = (100 - y) * 6 / 76
            if y >= 48:
                k = (y - 46) * 4 / 54
                d_ += f"M{n(x + t)} {y}H{n(x + 13 - k)}M{n(x + 13 + k)} {y}H{n(x + 26 - t)}"
            else:
                d_ += f"M{n(x + t)} {y}H{n(x + 26 - t)}"
        c.p(d_, s=.4, col=ln)
        c.p(leg, s=1.7)
    # 스카이파크: 오른쪽 뱃머리가 길게 튀어나온 배
    c.p("M6 18L10 24H82Q92 24 95 18z", "#EEF1F0", s=1.8)
    c.p("M8 20.4H93", s=.6)
    for x, r in ((16, 2.6), (30, 3.4), (70, 3.4), (82, 2.6)):
        c.c(x, 18 - r * .7, r, LEAF, s=.9)
    c.p("M42 17.6h18", s=1.4, col="#6FC7E2")
    # 저층 쇼핑몰, 아트사이언스 연꽃
    c.r(6, 96, 80, 8, "#DDE3E2", s=1.3)
    c.vlines(6, 96, 80, 8, 15, s=.45)
    c.p("M8 105C4 100 5 93 8 89Q11 92 12.5 97Q13 89 17 84Q20 89 20.5 97Q23 90 28 88Q30 94 28 98Q33 97 35 99Q33 103 28 105z", "#FAF7EE", s=1.1)
    c.p("M12.5 97V104M20.5 97V104M28 98L26 104", s=.5)


@d
def capital_gate(c):
    a, b, ln = "#BBDAE8", "#8DBAD0", "#F2FAFC"
    c.sun(84, 22, 4.5)
    c.shadow(48, 62)
    # 전시장 낮은 지붕
    c.p("M6 104V94Q36 88 62 94V104z", "#DAD8CC", s=1.4)
    c.vlines(6, 94, 56, 10, 9, s=.45)
    # 왼쪽으로 18도 기운 유리 몸통
    body = "M48 104C46 88 34 70 28 44C25 28 24 20 28 12C34 6 50 6 56 12C62 24 62 40 68 62C72 78 72 92 72 104z"
    c.p(body, a, s=0)
    c.p("M50 8C53 9 55 10 56 12C62 24 62 40 68 62C72 78 72 92 72 104H62C64 80 58 60 54 40C52 28 50 18 50 8z", b, s=0)
    # 마름모 다이아그리드: 격자점을 줄마다 반 칸 어긋낸다
    def row(y):
        t = (y - 12) / 92
        return 26 + t ** 1.7 * 23.5, 56.5 + t * 15
    d_ = ""
    for i, y0 in enumerate(range(13, 97, 8)):
        y1 = y0 + 8
        l0, r0 = row(y0)
        l1, r1 = row(y1)
        for k in range(6):
            u = k / 5 if i % 2 else (k + .5) / 5
            for du in (-.1, .1):
                v = u + du
                if 0 <= u <= 1 and 0 <= v <= 1:
                    d_ += f"M{n(l0 + (r0 - l0) * u)} {y0}L{n(l1 + (r1 - l1) * v)} {y1}"
    c.p(d_, s=.5, col=ln)
    c.p(body, s=1.9)
    # 건물을 휘감아 오르는 강철 띠
    sw = "M4 94C22 92 40 88 56 74C64 66 66 58 62 46C60 38 58 24 58 14"
    c.p(sw, s=2.6, col="#7C8D96")
    c.p(sw, s=1.1, col="#E9EEF0")
    c.p("M30 22Q40 18 54 22", s=1, col=ln)


@d
def gardens_bay(c):
    c.birds(74, 12)
    c.shadow(50, 84)
    def tree(x, top, w, base):
        """보랏빛 슈퍼트리: 수직 정원 줄기 + 깔때기 강철 우산."""
        y = top + w * .7
        c.p(f"M{n(x - 4)} {base}L{n(x - 2.4)} {n(y)}H{n(x + 2.4)}L{n(x + 4)} {base}z", "#A0568E", s=1.5)
        c.p(f"M{n(x + 1)} {n(y)}H{n(x + 2.4)}L{n(x + 4)} {base}H{n(x + 1.5)}z", "#7F3F73", s=0)
        h = base - y
        c.p("".join(f"M{n(x - 2.4 + (i % 3))} {n(y + h * (i + .5) / 9)}h.01M{n(x + (i % 2) * 1.8)} {n(y + h * (i + .9) / 9)}h.01" for i in range(9)), s=1.5, col="#8FCF72")
        c.p(f"M{n(x - w)} {top}Q{n(x - w * .5)} {n(top + w * .22)} {n(x - 2.4)} {n(y)}H{n(x + 2.4)}Q{n(x + w * .5)} {n(top + w * .22)} {n(x + w)} {top}z", "#C271A4", s=1.5)
        d_ = "".join(f"M{n(x + w * t)} {n(top + 1)}Q{n(x + w * t * .5)} {n(top + w * .3)} {n(x + t * 2.2)} {n(y)}" for t in (-.72, -.42, -.14, .14, .42, .72))
        c.p(d_, s=.6)
        c.e(x, top, w, w * .17, "#D991BE", s=1.5)
        c.e(x, top, w * .68, w * .1, "#7FB765", s=.7)
    tree(72, 42, 13, 104)
    tree(52, 28, 16, 104)
    # OCBC 스카이웨이
    c.p("M26 54Q40 62 50 60", s=2.6)
    c.p("M26 54Q40 62 50 60", s=1.2, col="#F3EDE0")
    tree(24, 14, 19, 104)
    # 꽃 돔(유리 온실)과 수풀
    c.p("M4 104C6 88 20 84 30 90V104z", "#BCE0EA", s=1.3)
    c.p("M10 104Q12 92 20 87M18 104Q20 94 26 89M6 97Q16 94 30 96", s=.5, col="#fff")
    for x, r in ((36, 4), (44, 5), (60, 4.4), (88, 4.4)):
        c.c(x, 102, r, LEAF, s=1.1)
    c.p("M34 101h.01M43 100h.01M47 102h.01M60 101h.01M88 101h.01", s=1.6, col="#E68AB0")


@d
def skytree(c):
    a, b, ln = "#ECF4F7", "#C3D5DD", "#6C8795"
    c.cloud(70, 20, .9)
    c.cloud(12, 36, .7)
    # 스미다 강, 옛 동네, 벚나무
    c.water(4, 106, 90, 6.5, "#8FCBE2")
    c.p("M6 104V96L12 92L18 96V104z", "#E2CFA8", s=1.1)
    c.p("M5 96.6L12 91L19 96.6", "#6B7B86", s=1.2)
    c.p("M18 104V98L24 94L30 98V104z", "#D9C39A", s=1.1)
    c.p("M17 98.6L24 93L31 98.6", "#6B7B86", s=1.2)
    c.r(83, 94, 2, 10, WOOD, s=.9)
    c.c(84, 91, 7.4, "#F3B9CD", s=1.2)
    c.p("M80 90h.01M86 88h.01M88 93h.01M83 94h.01", s=1.4, col="#E48EAF")
    c.shadow(50, 40)
    # 삼각 밑둥이 둥근 기둥으로 좁아지는 격자 탑
    body = "M36 104C42 84 44 60 45 40H55C56 60 58 84 64 104z"
    c.p(body, a, s=0)
    c.p("M50 40H55C56 60 58 84 64 104H52z", b, s=0)
    def W(y):
        return 5 + (y - 40) ** 2.3 / 64 ** 2.3 * 9
    d_ = ""
    ys = list(range(104, 40, -6))
    for i in range(len(ys) - 1):
        y0, y1 = ys[i], ys[i + 1]
        w0, w1 = W(y0), W(y1)
        d_ += f"M{n(50 - w0)} {y0}L{n(50 + w1)} {y1}M{n(50 + w0)} {y0}L{n(50 - w1)} {y1}M{n(50 - w1)} {y1}H{n(50 + w1)}M50 {y0}L{n(50 - w1)} {y1}M50 {y0}L{n(50 + w1)} {y1}"
    c.p(d_, s=.5, col=ln)
    c.p(body, s=1.8)
    c.c(50, 100, 2, "#5B7686", s=.8)
    # 전망대 둘, 안테나
    c.p("M41 42Q50 46 59 42L60 36H40z", "#F7FAFB", s=1.5)
    c.p("M40.5 39.5H59.5", s=1.2, col="#6F9FB4")
    c.r(45.5, 28, 9, 8, a, s=1.3)
    c.p("M43.6 28.6Q50 31 56.4 28.6L56 25H44z", "#F7FAFB", s=1.3)
    c.p("M44 27H56", s=.9, col="#6F9FB4")
    c.p("M48 25L49 8H51L52 25z", b, s=1.2)
    c.p("M50 8V1.6", s=1.2)
    c.p("M48.6 14h2.8M48.8 19h2.4", s=.5)


@d
def shard(c):
    a, b, e, ln = "#CDE4EE", "#9CC3D6", "#E7F3F7", "#F4FBFC"
    c.birds(14, 26)
    c.shadow(50, 58)
    # 런던 브리지 역 벽돌 고가와 이웃
    c.p("M6 104V90H94V104z", "#B4674A", s=1.5)
    c.arches(7, 104, 86, 10, 11, "#5F4A40", fill=.62)
    c.p("M6 93H94", s=.5)
    # 여덟 장의 유리 파편: 서로 어긋난 면
    c.poly([(26, 92), (47, 6), (50, 92)], e, s=1.5)
    c.poly([(50, 92), (47, 6), (50, 2), (58, 92)], a, s=1.5)
    c.poly([(58, 92), (53, 7), (74, 92)], b, s=1.5)
    c.poly([(36, 92), (45, 40), (50, 92)], "#BBD9E6", s=.9)
    c.poly([(50, 92), (56, 44), (64, 92)], "#86B0C6", s=.9)
    # 층선(폭이 위로 좁아진다)
    d_ = ""
    for y in range(14, 92, 5):
        t = (y - 4) / 88
        d_ += f"M{n(49 - 22 * t)} {y}H{n(49 + 24 * t)}"
    c.p(d_, s=.32, col=ln)
    c.p("M26 92L47 6M47 6L50 2L53 7L74 92M50 2L50 92M58 92L53 7", s=1)
    # 꼭대기의 벌어진 틈과 전망층 띠
    c.p("M46 24L54 24", s=.8, col="#fff")
    c.p("M41.5 30H56.8", s=1.3, col="#6F9FB4")
    c.poly([(26, 92), (47, 6), (50, 2), (53, 7), (74, 92)], "none", s=1.9)
    c.r(40, 86, 20, 6, "#5B7686", s=1)


@d
def cctv(c):
    f1, f2, f3, ln = "#C5CBD0", "#9AA2A9", "#E0E4E7", "#5F6A72"
    c.cloud(10, 18, .7)
    c.shadow(52, 80)
    # 뒤 오른쪽 탑
    c.p("M58 96L62 44H76L80 92z", f2, s=1.7)
    c.p("M64 94L66 46M70 93L70 46M75 92L73 46M60 80L79 79M61 66L78 65M61 54L77 54", s=.45, col=ln)
    # 바닥 L자 기단
    c.p("M18 96L44 104L84 92L84 84L44 94L18 86z", f1, s=1.7)
    c.p("M44 94V104", s=1)
    c.p("M22 92L40 97M50 96L80 88", s=.8, col=ln)
    # 앞 왼쪽 탑(안으로 기운다)
    c.p("M16 90L30 26L46 32L42 98z", f1, s=1.8)
    c.p("M46 32L54 30L50 94L42 98z", f2, s=1.8)
    d_ = "M17 82L44 88M19 72L45 74M21 62L45 60M24 52L45 46M26 42L46 36"
    d_ += "M20 90L34 28M34 94L39 30M16 90L46 60M42 98L24 52M44 72L27 34M21 62L45 36"
    c.p(d_, s=.55, col=ln)
    c.p("M48 40L53 44M47 60L52 54M46 76L51 70", s=.5, col=ln)
    # 공중에 내민 L자 윗부분
    c.p("M26 14L54 6L92 20L64 30z", f3, s=1.8)
    c.p("M26 14L64 30V48L26 30z", f1, s=1.8)
    c.p("M64 30L92 20V36L64 48z", f2, s=1.8)
    c.p("M30 19L30 32M38 22V36M46 26V40M56 29V44M26 22L64 39M38 22L64 44M46 26L30 32M64 34L46 40", s=.5, col=ln)
    c.p("M70 28V43M78 25V40M86 22V36M64 41L92 28M72 28L64 34M72 28L86 36", s=.5, col=ln)
    c.p("M36 16L60 9M50 20L76 12", s=.5, col="#9AA2A9")
    c.r(52, 94, 10, 5, "#5B7686", s=0)
    c.people(8, 104, 2)


@d
def heydar(c):
    w, w2, w3 = "#FDFDFB", "#DDE3E6", "#B9C4CA"
    c.shadow(52, 82)
    # 뒤쪽 낮은 물결
    c.p("M44 104C48 76 60 60 70 58C80 58 88 76 94 104z", w2, s=1.7)
    c.p("M52 104Q58 80 70 64M62 104Q66 84 74 66M74 104Q76 84 78 68", s=.45, col="#8E9CA4")
    # 어두운 유리 입구(접힌 틈)
    c.p("M22 104C28 88 36 76 50 70C54 80 58 92 60 104z", "#5A7588", s=1.4)
    c.p("M30 104Q36 88 46 74M40 104Q44 88 50 76M50 104Q51 92 53 82M28 94H58M36 82H54", s=.45, col="#D8E8EE")
    # 땅에서 솟아 접히는 흰 표면
    c.p("M5 104C10 88 8 60 18 38C22 28 28 20 40 22C52 24 58 42 68 46C60 54 52 58 50 70C36 76 28 88 22 104z", w, s=1.9)
    c.p("M40 22C52 24 58 42 68 46C60 54 52 58 50 70C50 56 46 36 40 22z", w3, s=0)
    # 표면을 따라 흐르는 패널 선
    c.p("M10 92C14 70 16 48 28 30M15 96C20 76 24 52 34 34M19 96C26 80 32 58 40 40M23 92C32 78 40 66 46 56M9 66C20 62 30 58 42 44M8 80C20 76 30 70 42 58", s=.4, col="#9AA7AE")
    c.p("M5 104C10 88 8 60 18 38C22 28 28 20 40 22C52 24 58 42 68 46C60 54 52 58 50 70C36 76 28 88 22 104z", s=1.9)
    # 잔디 비탈과 연못
    c.p("M66 104Q78 96 94 104z", "#8FC066", s=1)
    c.water(6, 106, 42, 5, "#9CD8E8")
    c.cypress(90, 90, 12, 6)


@d
def abraj(c):
    s_, s2, g, gr = "#E9DCC0", "#CBB995", "#E7B94A", "#2F8C63"
    c.shadow(50, 82)
    # 호텔 탑들이 양쪽에서 층층이 받친다
    for x, w, t in ((10, 14, 70), (24, 14, 58), (62, 14, 58), (76, 14, 70)):
        c.r(x, t, w, G - t, s_, s=1.5)
        c.r(x + w * .68, t, w * .32, G - t, s2, s=0)
        c.windows(x + 1, t + 2, w - 2, G - t - 3, 3, max(2, (G - t) // 7), "#7A8B8E", fill=.5)
        c.r(x, t, w, G - t, "none", s=1.5)
        c.p(f"M{x + 2} {t}L{x + w / 2} {t - 4}L{x + w - 2} {t}", s_, s=1.1)
    # 중앙 탑
    c.r(38, 52, 24, 52, s_, s=1.7)
    c.r(55, 52, 7, 52, s2, s=0)
    c.windows(40, 56, 20, 40, 5, 7, "#7A8B8E", fill=.5)
    c.arch(50, 104, 11, 12, "#6B7D7F", s=1.1)
    c.r(38, 52, 24, 52, "none", s=1.7)
    # 네모난 시계탑
    c.r(35, 28, 30, 24, s_, s=1.8)
    c.c(50, 40, 10.5, gr, s=1.5)
    c.c(50, 40, 8, "#FBF7EA", s=.8)
    d_ = "".join(f"M{n(50 + 6.6 * math.cos(i * math.pi / 6))} {n(40 + 6.6 * math.sin(i * math.pi / 6))}L{n(50 + 7.8 * math.cos(i * math.pi / 6))} {n(40 + 7.8 * math.sin(i * math.pi / 6))}" for i in range(12))
    c.p(d_, s=.6)
    c.p("M50 40V34.6M50 40L54 42", s=1)
    c.r(33.5, 50, 33, 3, g, s=1.1)
    c.r(33.5, 26, 33, 3, g, s=1.1)
    # 초록·금 첨탑과 초승달
    c.p("M38 26L44 12H56L62 26z", gr, s=1.5)
    c.p("M41 26L46 12M50 26V12M59 26L54 12", s=.6, col=g)
    c.p("M45 12L48 6H52L55 12z", g, s=1.2)
    c.r(49.2, 4, 1.6, 2.4, g, s=.6)
    c.p("M53 1.6A3.2 3.2 0 1 1 53 6.6A2.6 2.6 0 1 0 53 1.6z", g, s=.6)


@d
def ddp(c):
    a, b, ln = "#D8DCDF", "#AEB6BB", "#7E888E"
    # 뒤쪽 흥인지문: 돌 축대 + 붉은 문루
    c.r(10, 54, 26, 20, "#C9C2B2", s=1.3)
    c.blocks(10, 54, 26, 20, 4, 4, s=.4, col="#8E8676")
    c.r(14, 44, 18, 10, "#C4634E", s=1.1)
    c.p("M19 44v10M27 44v10", s=.6)
    c.eave(23, 44, 26, 7, "#5F6F78")
    c.eave(23, 37.6, 18, 5, "#5F6F78")
    c.shadow(50, 88)
    # 물결치는 은빛 덩어리
    body = "M4 104C2 84 14 66 36 60C58 54 84 60 93 80C95 90 95 98 93 104z"
    c.p(body, a, s=0)
    c.p("M70 60C82 64 90 72 93 80C95 90 95 98 93 104H78C82 88 80 72 70 60z", b, s=0)
    # 잔디 지붕
    c.p("M10 76C16 66 26 62 38 60C50 58 58 58 64 60C50 66 34 68 10 76z", "#8FC466", s=1.1)
    c.c(44, 57, 3.6, LEAF, s=.8)
    c.c(52, 57, 2.6, LEAF, s=.8)
    # 패널 곡선과 점 타공 띠
    c.p("M6 88C20 74 44 66 90 74M5 96C22 84 48 76 94 84M4 102C26 94 52 88 94 94M26 104C26 88 32 76 42 66M50 104C50 88 56 74 62 62M70 104C72 86 72 74 74 64", s=.45, col=ln)
    d_ = "".join(f"M{x} {n(79 - (x - 20) * .08 + ((x - 50) / 30) ** 2 * 2)}h.01" for x in range(18, 88, 3))
    c.p(d_, s=1, col="#5F6A70")
    # 깔때기 입구
    c.p("M24 104C24 94 30 88 38 86C46 88 52 94 52 104z", "#4F6878", s=1.4)
    c.p("M30 104Q32 94 38 90Q44 94 46 104M38 90V104", s=.5, col="#DCE8EE")
    c.p(body, s=1.9)
    # LED 장미 정원
    c.p("M16 109h.01M21 111h.01M26 109h.01M31 111h.01M36 109h.01M41 111h.01M46 109h.01M51 111h.01M56 109h.01", s=1.8, col="#FDFBF2")
    c.people(60, 104, 3)


@d
def one_wtc(c):
    a, b, e, ln = "#BDDCEB", "#8CBBD3", "#DCEFF6", "#F4FBFD"
    c.cloud(74, 24, .8)
    c.cloud(12, 40, .6)
    c.shadow(50, 54)
    # 은빛 지느러미 기단
    c.r(34, 84, 32, 20, "#E3E7E8", s=1.7)
    c.vlines(34, 85, 32, 18, 15, s=.5, col="#8D979B")
    c.r(44, 96, 12, 8, "#5B7686", s=1)
    # 모서리를 깎아 올린 팔면체: 가운데 삼각형 + 양쪽 역삼각형
    tl, tr = (43, 18), (57, 18)
    bl, br = (36, 84), (64, 84)
    c.poly([bl, tl, (50, 84)], "#CFE7F1", s=1.2)
    c.poly([(50, 84), tr, br], b, s=1.2)
    c.poly([bl, br, (57, 18), tl], "none", s=0)
    c.poly([bl, tl, tr, br], a, s=0)
    c.poly([bl, tl, (50, 40)], e, s=0)
    c.poly([br, tr, (50, 40)], b, s=0)
    c.poly([tl, tr, (50, 64)], "#D2E8F2", s=0)
    # 층선
    c.hlines(37, 18, 26, 66, 16, s=.3, col=ln)
    c.p("M36 84L57 18M64 84L43 18", s=.9)
    c.poly([bl, tl, tr, br], "none", s=1.9)
    # 꼭대기 난간과 안테나
    c.r(42, 15.6, 16, 2.4, "#E3E7E8", s=1.1)
    c.p("M45 15.6V12.6H55V15.6z", "#CDD3D5", s=1)
    c.p("M49 12.6L49.6 2H50.4L51 12.6z", "#F4F6F6", s=1)
    c.p("M48 9.6h4M48.4 6.6h3.2", s=.6)
    c.c(76, 98, 5, LEAF, s=1.1)
    c.c(22, 98, 5, LEAF, s=1.1)
    c.p("M22 103V104M76 103V104", s=1.2)


@d
def shanghai_tower(c):
    a, b, ln = "#B3DBDC", "#7CB2B9", "#EDF8F8"
    # 푸둥의 이웃: 진마오 탑과 병따개 SWFC
    c.p("M8 104V70L10 66V58L12 54V46L15 40L18 46V54L20 58V66L22 70V104z", "#BFC9BE", s=1.1)
    c.p("M8 76H22M10 62h10M12 50h6", s=.5)
    c.p("M72 104L74 38H90L92 104z", "#C6D2D8", s=1.1)
    c.p("M77 42H87L85 50H79z", "#fff", s=.8)
    c.p("M72 60H92M72 74H92M72 88H92", s=.4)
    c.shadow(50, 52)
    # 120도 비틀려 오르는 유리 몸통
    body = "M33 104C32 76 37 40 44 16C46 8 54 3 60 7C62 22 66 66 68 104z"
    c.p(body, a, s=0)
    c.p("M55 4.8C58 4.6 59.4 5.6 60 7C62 22 66 66 68 104H56C58 66 57 30 55 4.8z", b, s=0)
    # 수평 존 띠와 층선
    d_ = ""
    for y in range(16, 104, 11):
        t = (y - 8) / 96
        d_ += f"M{n(43 - 10 * t)} {y}Q50 {n(y + 2)} {n(60 + 8 * t)} {y}"
    c.p(d_, s=.8, col="#5C8F96")
    d2 = ""
    for y in range(13, 104, 4):
        t = (y - 8) / 96
        d2 += f"M{n(43.5 - 10 * t)} {y}H{n(60 + 8 * t)}"
    c.p(d2, s=.25, col=ln)
    # 꼭대기까지 도는 나선 틈(바람 홈)
    c.p("M61 104C50 84 36 72 38 56C40 40 56 34 58 8", s=2.1)
    c.p("M61 104C50 84 36 72 38 56C40 40 56 34 58 8", s=.9, col="#E5F5F5")
    c.p(body, s=1.9)
    c.r(40, 98, 22, 6, "#5F8590", s=.9)


@d
def elbphil(c):
    br, br2, g = "#A85A42", "#8C4733", "#CFE6EE"
    c.water(4, 106, 90, 6.5, "#6FB4CE")
    c.birds(72, 12)
    # 파도처럼 치솟는 흰 지붕과 유리 곡면
    glass = "M8 62V34Q14 34 22 24Q28 30 34 26Q42 16 52 6Q60 20 66 22Q74 28 80 26Q86 32 92 38V62z"
    c.p(glass, g, s=0)
    c.p("M70 25Q74 28 80 26Q86 32 92 38V62H70z", "#A9CFDC", s=0)
    # 층선과 볼록한 유리 조각
    c.p("M8 42H92M8 50H92M8 56H92", s=.45, col="#fff")
    d_ = ""
    for y, xs in ((36, (16, 28, 40, 52, 64, 76)), (44, (12, 22, 34, 46, 58, 70, 82)), (52, (16, 28, 40, 52, 64, 76, 86))):
        for x in xs:
            d_ += f"M{x} {y}a3 2.2 0 1 0 6 0a3 2.2 0 1 0-6 0z"
    c.p(d_, "#EAF5F8", s=.5)
    # 돌출 발코니(U자 구멍)
    c.p("M24 44v3a3 3 0 0 0 6 0v-3zM60 36v3a3 3 0 0 0 6 0v-3z", "#4F6878", s=.7)
    c.p(glass, s=1.9)
    # 지붕 윗면 흰 띠
    c.p("M8 34Q14 34 22 24Q28 30 34 26Q42 16 52 6Q60 20 66 22Q74 28 80 26Q86 32 92 38L90 40Q84 34 80 29Q74 31 66 25Q58 23 52 11Q42 21 35 29Q28 33 22 27Q14 37 8 37z", "#FBFBF7", s=1.2)
    # 광장 틈
    c.r(8, 62, 84, 5, "#3F5764", s=1.3)
    c.p("M18 67Q22 62 26 67M44 67Q50 62 56 67M72 67Q76 62 80 67", "#EEF3F5", s=.6)
    # 옛 카이슈파이허 벽돌
    c.r(8, 67, 84, 37, br, s=1.8)
    c.r(70, 67, 22, 37, br2, s=0)
    c.blocks(8, 67, 84, 37, 8, 10, s=.35, col="#7A3E2C")
    c.windows(10, 70, 80, 32, 11, 4, "#4A3A33", fill=.42)
    c.r(8, 67, 84, 37, "none", s=1.8)
    c.arch(50, 104, 12, 11, "#5B7686", s=1.1)


@d
def louvre_ad(c):
    a, b, ln = "#D7DDE0", "#AFB9BE", "#6F7C84"
    c.sun(86, 14, 4)
    c.water(4, 105, 90, 8, "#6DC1D8")
    # 흰 메디나 상자들(돔 그늘 안으로 들어간다)
    for x, y, w, f in ((12, 80, 16, "#FAF8F2"), (26, 72, 14, "#F0EDE5"), (38, 76, 18, "#FAF8F2"), (54, 70, 12, "#E9E6DD"), (64, 76, 16, "#F7F5EE"), (78, 82, 12, "#EAE7DE")):
        c.r(x, y, w, 104 - y, f, s=1.3)
        c.p(f"M{x + 2} {y + 10}h{w * .3:.1f}v5h-{w * .3:.1f}z", "#7F99A7", s=0)
    c.r(44, 94, 8, 10, "#5F7C8E", s=.8)
    # 납작한 은빛 격자 돔
    body = "M5 78C10 52 28 36 50 36C72 36 90 52 95 78C70 72 30 72 5 78z"
    c.p(body, a, s=0)
    c.p("M70 41C84 48 92 62 95 78C88 76 80 75 72 74C76 62 74 50 70 41z", b, s=0)
    d_ = ""
    for u in (.52, .68, .8, .91):
        v = 1 - u
        x = v ** 3 * 50 + 3 * v * v * u * 28 + 3 * v * u * u * 10 + u ** 3 * 5
        y = v ** 3 * 36 + 3 * v * v * u * 36 + 3 * v * u * u * 52 + u ** 3 * 78
        d_ += f"M{n(x)} {n(y)}Q50 {n(y - 4)} {n(100 - x)} {n(y)}"
    for x in (-36, -24, -12, 0, 12, 24, 36):
        d_ += f"M50 36Q{n(50 + x * 1.1)} 44 {n(50 + x)} 73"
    c.p(d_, s=.45, col=ln)
    # 겹친 별 무늬
    d_ = ""
    for i in range(-3, 3):
        x0, x1 = 50 + i * 12, 50 + (i + 1) * 12
        d_ += f"M{x0} 73L{n(50 + (i + 1) * 12 * .78)} 56L{n(50 + (i + 2) * 12 * .5)} 44M{x1} 73L{n(50 + i * 12 * .78)} 56L{n(50 + (i - 1) * 12 * .5)} 44"
    c.p(d_, s=.35, col="#FBFCFC")
    c.p(body, s=1.9)
    c.p("M5 78C30 72 70 72 95 78", s=1.2)
    # 가장자리 받침 기둥
    c.p("M14 76V88M86 76V90", s=2)


@d
def dubai_frame(c):
    g, g2, gl = "#EDC25A", "#CC9B35", "#BCE2EE"
    c.shadow(50, 74)
    # 액자 속 먼 도시
    c.p("M32 104V80h5v-8h5v8h4v-14h4V48h1V30h1v18h1v18h4v14h5v-6h5V104z", "#D4E4EA", s=.7)
    c.p("M32 94H66", s=.4, col="#A9BFC8")
    # 금빛 다리(왼쪽), 유리 전망대가 이어 준다
    for x, f, f2_ in ((20, g, g2), (66, "#DDB048", g2)):
        c.r(x, 20, 12, 84, f, s=1.8)
        d_ = ""
        for y in range(28, 100, 8):
            d_ += f"M{x + 6} {y - 3}l3 3l-3 3l-3-3z"
        c.p(d_, "#FAE7AE", s=.5)
        c.p(f"M{x + 2} 20V104M{x + 10} 20V104", s=.45, col="#9B7420")
        c.r(x, 20, 12, 84, "none", s=1.8)
    # 윗부분: 금 띠 + 유리 다리
    c.r(18, 4, 62, 18, g, s=1.9)
    c.r(32, 9, 34, 8, gl, s=1.1)
    c.vlines(32, 9, 34, 8, 7, s=.5, col="#fff")
    c.p("M18 7h62M18 19h62", s=.5, col="#9B7420")
    d_ = "".join(f"M{x} 12l2 2l-2 2l-2-2z" for x in (22, 28, 70, 76))
    c.p(d_, "#FAE7AE", s=.5)
    # 받침과 야자수
    c.r(14, 100, 70, 4, "#E9DFC8", s=1.3)
    c.palm(10, 104, 16)


@d
def unity(c):
    br, br2, ln = "#A58E5E", "#7F6C44", "#5F5033"
    # 비디아 언덕과 나르마다 강
    c.p("M4 104C10 84 18 78 30 84C40 70 60 70 72 84C82 76 90 84 95 104z", "#A9C98A", s=1.2)
    c.water(4, 106, 90, 7, "#7FBFD5")
    # 층층 받침
    c.p("M22 104V98H78V104z", "#C9B79A", s=1.5)
    c.p("M32 98V92H68V98z", "#B9A688", s=1.4)
    c.p("M26 104v-6M36 104v-6M64 104v-6M74 104v-6", s=.45)
    # 두 다리와 발
    c.p("M38 92L40 62H60L62 92H52L50 72L48 92z", br, s=1.8)
    c.p("M50 72L52 92H62L60 62H54z", br2, s=0)
    c.p("M36 92h13v-2.6q-6-2-13 0zM51 92h13v-2.6q-6-2-13 0z", "#8C7848", s=1.2)
    c.p("M43 66L41 88M47 66L46 86M55 66L57 88M50 62V70", s=.5, col=ln)
    # 숄을 두른 상체와 늘어진 팔
    c.p("M36 28Q42 22 50 22Q58 22 64 28L66 50L66 66H34L34 50z", br, s=1.8)
    c.p("M54 23Q60 24 64 28L66 50L66 66H56C58 50 58 34 54 23z", br2, s=0)
    c.p("M36 28C42 38 52 46 64 52M38 26C46 36 54 42 65 46M42 66C44 56 48 50 54 46", s=.6, col=ln)
    c.p("M36 30L30 60Q30 66 33 68L38 66L39 42", br, s=1.6)
    c.p("M64 30L70 60Q70 66 67 68L62 66L61 42", br2, s=1.6)
    c.c(32.6, 69, 2.4, br, s=1.1)
    c.c(67.4, 69, 2.4, br2, s=1.1)
    # 머리는 단순한 덩어리로 둔다
    c.r(46.4, 17, 7.2, 7, br2, s=1.2)
    c.e(50, 12, 6.2, 7.2, br, s=1.7)
    c.p("M43.9 10.6C44.6 5.4 55.4 5.4 56.1 10.6C52 8.4 48 8.4 43.9 10.6z", "#8C7848", s=.9)


@d
def vessel(c):
    cu, cu2, da, st = "#D2875A", "#B06A40", "#7A4630", "#F6E7D3"
    # 허드슨 야드 유리탑
    c.p("M8 104V30L24 24V104z", "#C5DCE6", s=1.2)
    c.hlines(8, 34, 16, 70, 6, s=.4, col="#fff")
    c.p("M76 104V18H92V104z", "#D5E4E9", s=1.2)
    c.vlines(76, 20, 16, 84, 3, s=.4, col="#fff")
    c.shadow(50, 52)
    # 위로 벌어지는 벌집 그릇
    def W(y):
        return 16 + (max(0, 104 - y) / 78) ** 1.2 * 20
    ys = list(range(104, 24, -8)) + [26]
    s_ = "M" + "L".join(f"{n(50 - W(y))} {y}" for y in ys) + "L" + "L".join(f"{n(50 + W(y))} {y}" for y in reversed(ys)) + "z"
    c.p(s_, cu, s=0)
    c.p("M" + "L".join(f"{n(50 + W(y) * .55)} {y}" for y in ys) + "L" + "L".join(f"{n(50 + W(y))} {y}" for y in reversed(ys)) + "z", cu2, s=0)
    # 원통을 감싼 마름모 칸: 가운데는 넓고 가장자리는 좁다
    holes, steps_ = "", ""
    rows = list(range(103, 30, -11))
    for i in range(len(rows) - 1):
        y0, y1 = rows[i], rows[i + 1]
        ym = (y0 + y1) / 2
        for k in range(-4, 5):
            ph = (k + (.5 if i % 2 else 0)) * .36
            if abs(ph) > 1.3:
                continue
            xm = 50 + W(ym) * .96 * math.sin(ph)
            hw = .8 + 3.6 * math.cos(ph)
            holes += f"M{n(xm)} {n(ym - 4.4)}L{n(xm + hw)} {n(ym)}L{n(xm)} {n(ym + 4.4)}L{n(xm - hw)} {n(ym)}z"
            steps_ += f"M{n(xm - hw * .5)} {n(ym + 2.4)}L{n(xm + hw * .5)} {n(ym + 2.4)}M{n(xm - hw * .75)} {n(ym + 1)}L{n(xm + hw * .75)} {n(ym + 1)}"
    c.p(holes, da, s=.7)
    c.p(steps_, s=.6, col=st)
    c.p(s_, s=1.8)
    c.e(50, 26, W(26), 3.4, "#C47C4F", s=1.5)
    c.e(50, 26, W(26) - 5, 1.9, da, s=.7)
    c.people(50, 104, 3)


@d
def merdeka(c):
    pal = ("#D5ECF1", "#A9D2DD", "#7FB6C8", "#4C8399")
    c.cloud(76, 30, .7)
    c.birds(8, 22)
    # 저층 몰과 옛 메르데카 경기장
    c.p("M12 104V94Q50 86 88 94V104z", "#D9E2E2", s=1.4)
    c.p("M12 99Q50 92 88 99", s=.5)
    c.p("M4 104C6 96 16 94 22 104z", "#E8E2CE", s=1.1)
    c.shadow(50, 52)
    # 송켓 무늬처럼 어긋난 삼각 면(왼쪽은 밝고 오른쪽은 어둡다)
    rows = [(96, 18), (76, 16.4), (58, 13.6), (42, 9.6), (30, 5)]
    k = 4
    for j in range(len(rows) - 1):
        y0, w0 = rows[j]
        y1, w1 = rows[j + 1]
        o = .5 if j % 2 else 0
        for i in range(-k // 2, k // 2 + 1):
            u0, u1 = (i - o) / (k / 2), (i + 1 - o) / (k / 2)
            v = (i + .5 - o) / (k / 2)
            u0, u1 = max(-1, u0), min(1, u1)
            if u0 >= u1:
                continue
            shade = min(3, int((v + 1) * 2))
            c.poly([(50 + w0 * u0, y0), (50 + w0 * u1, y0), (50 + w1 * max(-1, min(1, v)), y1)], pal[shade], s=0)
            if -1 <= v + 1 / (k / 2) <= 1 and u1 < 1:
                c.poly([(50 + w0 * u1, y0), (50 + w1 * v, y1), (50 + w1 * (v + 1 / (k / 2)), y1)], pal[max(0, shade - 1)], s=0)
    # 층선
    d_ = ""
    for y in range(34, 96, 5):
        t = next(i for i in range(4) if rows[i + 1][0] <= y)
        y0, w0 = rows[t]
        y1, w1 = rows[t + 1]
        w = w1 + (w0 - w1) * (y - y1) / (y0 - y1)
        d_ += f"M{n(50 - w)} {y}H{n(50 + w)}"
    c.p(d_, s=.25, col="#F2FAFB")
    c.p("M32 96L33.6 76L36.4 58L40.4 42L45 30H55L59.6 42L63.6 58L66.4 76L68 96z", s=1.9)
    # 칼처럼 얇은 첨탑(높이의 1/4)
    c.p("M45 30L50 2L55 30z", "#DCEEF3", s=1.5)
    c.p("M50 2V30", s=.5)
    c.p("M50 2L55 30H50z", "#A9D2DD", s=0)
    c.p("M45 30L50 2L55 30", s=1.5)
    c.r(43, 90, 14, 6, "#4F7486", s=.9)
