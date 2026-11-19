"""크리스마스 팩 그림 (SEA1119A01). `season_art.Art`로 그린다."""
import math
import random

from PIL import Image

from season_art import Art, ball, bulb, drooping_tier, rounded_star, snow_clump, star_points

RED = ((236, 82, 78), (172, 28, 40))
GOLD = ((255, 232, 140), (214, 156, 40))
BULB_COLORS = [(255, 90, 80), (255, 206, 90), (110, 190, 255), (130, 220, 140), (255, 160, 210)]

# (중심 x, 중심 y, 반지름, 색) — 가지층 안쪽에 걸리는 장식
ORNAMENTS = [
    (232, 150, 9, (RED[0], RED[1])), (284, 188, 8, ((255, 236, 150), (206, 150, 40))),
    (214, 232, 10, ((140, 190, 255), (50, 100, 200))), (296, 252, 9, (RED[0], RED[1])),
    (176, 296, 11, ((255, 236, 150), (206, 150, 40))), (252, 292, 10, ((235, 240, 250), (150, 165, 190))),
    (332, 306, 10, ((140, 190, 255), (50, 100, 200))), (150, 366, 11, (RED[0], RED[1])),
    (230, 372, 11, ((235, 240, 250), (150, 165, 190))), (310, 366, 12, ((255, 236, 150), (206, 150, 40))),
    (380, 392, 11, (RED[0], RED[1])), (190, 410, 10, ((140, 190, 255), (50, 100, 200))),
]

# 가지층: (꼭대기 y, 밑단 y, 반폭, 물결 수)
TIERS = [(250, 416, 208, 8), (178, 334, 172, 7), (112, 252, 134, 6), (58, 174, 98, 4)]


def _swag(art, x0, x1, y, sag, lit, rng):
    """가지 층을 가로지르는 구슬 줄(낮) / 전구 줄(점등)."""
    n = 11
    pts = [(x0 + (x1 - x0) * i / n, y + sag * math.sin(math.pi * i / n)) for i in range(n + 1)]
    art.stroke(pts, (255, 236, 190, 255) if not lit else (255, 226, 150, 255), 2.2)
    for i, (px, py) in enumerate(pts[1:-1], 1):
        color = BULB_COLORS[(i + int(y)) % len(BULB_COLORS)]
        if lit:
            bulb(art, px, py + 4, color, True)
        else:
            art.ellipse((px - 3.2, py - 3.2, px + 3.2, py + 3.2), ("r", px - 1, py - 1, 5, (255, 244, 200), (214, 160, 50)))


def _gift(art, x, y, w, h, body, ribbon, lit):
    art.shadow(lambda d, s: d.rounded_rectangle([s(x), s(y + h - 4), s(x + w), s(y + h + 5)], radius=s(4), fill=255), color=(30, 50, 90), alpha=0.35, blur=3, dy=2)
    art.rrect((x, y, x + w, y + h), ("v", body[0], body[1], y, y + h), radius=4)
    art.rrect((x - 3, y - 2, x + w + 3, y + h * 0.28), ("v", tuple(min(255, c + 22) for c in body[0]), body[0], y, y + h * 0.3), radius=3)
    art.rrect((x + w / 2 - 4, y - 2, x + w / 2 + 4, y + h), ("v", ribbon[0], ribbon[1], y, y + h), radius=1)
    cx, cy = x + w / 2, y - 3
    for sign in (-1, 1):
        art.ellipse((cx + sign * 12 - 9, cy - 9, cx + sign * 12 + 9, cy + 3), ("v", ribbon[0], ribbon[1], cy - 9, cy + 3))
    art.ellipse((cx - 4, cy - 4, cx + 4, cy + 4), ("v", ribbon[0], ribbon[1], cy - 4, cy + 4))
    if lit:
        art.glow(cx, cy, 16, (255, 220, 150), 0.18)


def tree(lit):
    art = Art(512, 512)
    rng = random.Random(7)
    day_green = ((92, 176, 108), (34, 112, 70))
    night_green = ((52, 108, 122), (16, 54, 66))
    greens = night_green if lit else day_green
    snow_a, snow_b = ((205, 220, 245), (150, 175, 220)) if lit else ((255, 255, 255), (214, 228, 248))

    # 눈 쌓인 땅
    art.shadow(lambda d, s: d.ellipse([s(40), s(430), s(472), s(500)], fill=255), color=(30, 50, 100), alpha=0.25, blur=5, dy=3)
    art.ellipse((36, 424, 476, 504), ("v", snow_a, snow_b, 424, 504))
    art.ellipse((90, 440, 420, 500), ("v", (255, 255, 255, 120) if not lit else (230, 240, 255, 110), snow_b, 440, 500), alpha=0.7)

    if lit:
        art.glow(256, 400, 84, (255, 214, 140), 0.3, blur=28)
    # 나무 그림자와 줄기
    art.shadow(lambda d, s: d.ellipse([s(110), s(412), s(402), s(458)], fill=255), color=(20, 40, 60), alpha=0.3, blur=8, dy=2)
    art.rrect((232, 392, 282, 446), ("h", (150, 104, 66), (92, 58, 38), 232, 282), radius=5)
    art.texture(lambda d: d.rectangle([232 * 4, 392 * 4, 282 * 4, 446 * 4], fill=255), 40, 3, (176, 128, 86), (64, 40, 28), length=(6, 12), alpha=0.5)

    # 가지층(아래에서 위로)
    for index, (apex, base, half, bumps) in enumerate(TIERS):
        pts = drooping_tier(apex, base, half, bumps)
        art.shadow(lambda d, s, pts=pts: d.polygon([(s(x), s(y + 4)) for x, y in pts], fill=255), color=(8, 30, 20), alpha=0.35, blur=5, dy=3)
        art.poly(pts, ("v", greens[0], greens[1], apex, base + 12))
        # 왼쪽은 빛, 오른쪽은 그늘
        art.poly([(256, apex), (256 - half * 0.1, base), (256 - half, base)], (255, 255, 255, 34 if not lit else 12))
        art.poly([(256, apex), (256 + half, base), (256 + half * 0.1, base + 6)], (0, 20, 10, 60))
        art.texture(lambda d, pts=pts: d.polygon([(x * 4, y * 4) for x, y in pts], fill=255), 520 - index * 60, 11 + index,
                    (150, 214, 150) if not lit else (110, 170, 190), (14, 70, 44) if not lit else (8, 36, 50), length=(6, 13), alpha=0.5)
        # 가지 끝과 비탈에 쌓인 눈덩이
        snow_lo, snow_hi = ((196, 212, 240), (140, 166, 214)) if lit else ((255, 255, 255), (206, 222, 246))
        for k in range(bumps):
            t = (k + 0.5) / bumps
            px = 256 + half - 2 * half * t
            snow_clump(art, px, base + 4, 2 * half / bumps * 0.9, snow_lo, snow_hi)
        for side in (-1, 1):
            for frac in (0.3, 0.55, 0.8):
                sx = 256 + side * half * frac * 0.92
                sy = apex + (base - apex) * frac - 4
                snow_clump(art, sx, sy, 20 + 12 * frac, snow_lo, snow_hi, alpha=0.9)
        # 구슬/전구 줄
        _swag(art, 256 - half * 0.82, 256 + half * 0.82, base - 36 - index * 2, 20 + index * 2, lit, rng)

    # 장식 구슬
    for x, y, r, (c0, c1) in ORNAMENTS:
        if lit:
            c0 = tuple(int(c * 0.82) for c in c0); c1 = tuple(int(c * 0.7) for c in c1)
        ball(art, x, y, r, c0, c1)

    # 꼭대기 별
    if lit:
        art.glow(256, 54, 40, (255, 230, 140), 0.6)
    rounded_star(art, 256, 54, 38 if lit else 36, (255, 246, 170) if lit else (255, 232, 130), (232, 160, 30), outline=(190, 120, 20, 90))

    # 나무 앞 선물 (연도 글자 칸을 가리지 않게 양옆에)
    _gift(art, 64, 440, 58, 46, ((224, 66, 66), (160, 30, 44)), GOLD, lit)
    _gift(art, 394, 446, 52, 40, ((70, 124, 214), (36, 76, 160)), ((255, 255, 255), (218, 226, 240)), lit)
    _gift(art, 128, 462, 34, 28, ((70, 160, 100), (34, 110, 66)), ((255, 226, 130), (214, 160, 50)), lit)
    return art.out()


def star_glow():
    """점등 때 꼭대기에 얹는 별빛(투명 배경)."""
    art = Art(512, 512)
    art.glow(256, 54, 70, (255, 238, 150), 0.85, blur=26)
    art.glow(256, 54, 34, (255, 252, 220), 0.9, blur=10)
    # 빛살
    for i in range(8):
        a = i * math.pi / 4 + math.pi / 8
        length = 74 if i % 2 == 0 else 52
        art.poly([(256 + 6 * math.cos(a + 1.5708), 54 + 6 * math.sin(a + 1.5708)),
                  (256 + length * math.cos(a), 54 + length * math.sin(a)),
                  (256 + 6 * math.cos(a - 1.5708), 54 + 6 * math.sin(a - 1.5708))], (255, 248, 200, 110))
    rounded_star(art, 256, 54, 40, (255, 252, 214), (255, 214, 90))
    for dx, dy, r in ((-72, 18, 9), (74, 6, 7), (-34, -40, 6), (46, -46, 8), (-92, -10, 5), (90, 34, 5)):
        art.poly(star_points(256 + dx, 54 + dy, r, 0.28), (255, 255, 255, 235))
    return art.out()


def bell_icon():
    art = Art(96, 96)
    art.shadow(lambda d, s: d.ellipse([s(24), s(70), s(72), s(80)], fill=255), color=(60, 40, 10), alpha=0.3, blur=2.5, dy=1)
    # 호랑가시 잎
    for sign in (-1, 1):
        art.poly([(48, 62), (48 + sign * 34, 52), (48 + sign * 22, 70)], ("v", (72, 150, 84), (30, 96, 56), 52, 70))
    # 종 몸통
    body = [(48, 14), (36, 20), (31, 38), (26, 58), (20, 64), (20, 69), (76, 69), (76, 64), (70, 58), (65, 38), (60, 20)]
    art.poly(body, ("h", (255, 236, 140), (200, 140, 30), 22, 74))
    art.poly([(44, 20), (36, 24), (33, 40), (28, 60), (35, 60), (39, 40), (43, 28)], (255, 255, 255, 140))
    art.rrect((18, 62, 78, 72), ("v", (255, 214, 90), (190, 130, 26), 62, 72), radius=5)
    art.ellipse((41, 68, 55, 82), ("r", 46, 72, 9, (255, 226, 120), (176, 116, 22)))
    # 리본 매듭
    for sign in (-1, 1):
        art.poly([(48, 14), (48 + sign * 20, 5), (48 + sign * 22, 22)], ("v", RED[0], RED[1], 5, 22))
    art.ellipse((42, 8, 54, 20), ("r", 46, 12, 8, (255, 110, 100), (176, 30, 44)))
    # 호랑가시 열매
    for x, y in ((38, 66), (46, 71), (54, 66)):
        art.ellipse((x - 4, y - 4, x + 4, y + 4), ("r", x - 1, y - 1, 6, (255, 120, 110), (176, 28, 40)))
        art.ellipse((x - 2.4, y - 2.8, x - 0.6, y - 1), (255, 255, 255, 200))
    return art.out()


def gift(kind):
    palette = {
        "a": (((236, 90, 84), (166, 30, 44)), GOLD),
        "b": (((92, 182, 120), (34, 112, 70)), ((255, 244, 214), (222, 196, 140))),
        "c": (((96, 150, 236), (44, 84, 176)), ((255, 255, 255), (214, 224, 244))),
    }[kind]
    art = Art(96, 96)
    _gift(art, 16, 38, 64, 46, palette[0], palette[1], False)
    # 뚜껑 위 반짝이
    art.poly(star_points(78, 22, 7, 0.3), (255, 255, 255, 220))
    art.poly(star_points(18, 30, 5, 0.3), (255, 255, 255, 180))
    return art.out()


def santa_hat():
    art = Art(360, 318)
    art.shadow(lambda d, s: d.polygon([(s(70), s(260)), (s(190), s(60)), (s(300), s(260))], fill=255), color=(60, 10, 20), alpha=0.25, blur=6, dy=4)
    # 휘어진 몸통
    body = [(52, 258), (92, 150), (150, 80), (214, 56), (262, 78), (288, 128), (312, 258)]
    art.poly(body, ("h", (240, 74, 74), (160, 26, 40), 52, 312))
    art.poly([(70, 250), (100, 156), (150, 92), (176, 80), (140, 130), (122, 250)], (255, 150, 140, 90))
    art.poly([(262, 86), (288, 132), (312, 258), (260, 258), (262, 150)], (90, 8, 24, 110))
    # 접힌 끝과 방울
    art.stroke([(214, 56), (262, 78), (300, 150)], ("h", (240, 74, 74), (150, 22, 36), 214, 300), 40)
    art.ellipse((254, 112, 326, 184), ("r", 286, 142, 40, (255, 255, 255), (214, 224, 238)))
    art.glow(290, 146, 36, (255, 255, 255), 0.4, blur=10)
    # 털 챙(둥근 덩어리 여럿)
    art.rrect((22, 236, 338, 312), ("v", (255, 255, 255), (206, 218, 236), 236, 312), radius=36)
    for i in range(9):
        x = 40 + i * 34
        art.ellipse((x - 20, 226, x + 20, 262), ("v", (255, 255, 255), (230, 238, 250), 226, 262))
    art.texture(lambda d: d.rounded_rectangle([22 * 4, 236 * 4, 338 * 4, 312 * 4], radius=36 * 4, fill=255), 140, 9, (255, 255, 255), (186, 200, 224), length=(5, 10), alpha=0.6)
    return art.out()


def scarf():
    art = Art(360, 150)
    art.shadow(lambda d, s: d.rounded_rectangle([s(10), s(26), s(350), s(96)], radius=s(34), fill=255), color=(60, 10, 20), alpha=0.25, blur=5, dy=4)
    art.rrect((8, 20, 352, 92), ("v", (236, 84, 84), (166, 30, 44), 20, 92), radius=34)
    stripes = [x for x in range(30, 340, 54)]
    for x in stripes:
        art.rrect((x, 22, x + 22, 90), ("v", (255, 255, 255), (222, 230, 244), 22, 90), radius=3)
    # 뜨개 무늬
    art.texture(lambda d: d.rounded_rectangle([8 * 4, 20 * 4, 352 * 4, 92 * 4], radius=34 * 4, fill=255), 260, 5, (255, 190, 190), (110, 10, 28), length=(3, 6), width=1.1, alpha=0.45)
    art.rrect((56, 70, 138, 146), ("v", (236, 84, 84), (166, 30, 44), 70, 146), radius=12)
    for y in (96, 118):
        art.rrect((56, y, 138, y + 11), (255, 255, 255), radius=2)
    for x in range(62, 136, 10):  # 술
        art.stroke([(x, 140), (x - 1, 152)], (236, 84, 84), 4, round_ends=True)
    art.poly([(14, 26), (160, 20), (200, 32), (30, 46)], (255, 255, 255, 60))
    return art.out()


def antlers():
    art = Art(420, 260)
    brown = ((176, 126, 84), (104, 66, 42))
    for sign in (-1, 1):
        def branch(pts, width):
            art.stroke(pts, ("v", brown[0], brown[1], 20, 250), width)
        base = (210 + sign * 62, 252)
        main = [base, (210 + sign * 112, 190), (210 + sign * 126, 120), (210 + sign * 138, 44)]
        art.shadow(lambda d, s, main=main: d.line([(s(x), s(y)) for x, y in main], fill=255, width=s(20)), color=(40, 20, 10), alpha=0.3, blur=3, dy=3)
        branch(main, 22)
        branch([(210 + sign * 118, 168), (210 + sign * 164, 138), (210 + sign * 176, 92)], 15)
        branch([(210 + sign * 128, 102), (210 + sign * 92, 70), (210 + sign * 84, 36)], 13)
        art.stroke([(210 + sign * 114, 200), (210 + sign * 130, 130)], (255, 220, 180, 90), 5)
        # 방울
        art.ellipse((210 + sign * 138 - 13, 28, 210 + sign * 138 + 13, 56), ("r", 210 + sign * 136, 38, 18, (255, 236, 150), (190, 130, 26)))
        art.rrect((210 + sign * 112 - 11, 232, 210 + sign * 112 + 11, 250), RED[0], radius=3)
    return art.out()


def coat():
    art = Art(400, 300)
    art.shadow(lambda d, s: d.ellipse([s(24), s(14), s(376), s(320)], fill=255), color=(60, 10, 20), alpha=0.22, blur=6, dy=4)
    art.ellipse((20, 8, 380, 330), ("h", (240, 80, 78), (160, 26, 40), 20, 380))
    art.ellipse((46, 16, 190, 200), (255, 160, 150, 70))
    art.texture(lambda d: d.ellipse([20 * 4, 8 * 4, 380 * 4, 330 * 4], fill=255), 300, 4, (255, 170, 160), (110, 10, 30), length=(5, 9), alpha=0.35)
    # 앞 털 단
    art.rrect((172, 8, 228, 300), ("v", (255, 255, 255), (214, 224, 240), 8, 300), radius=22)
    # 벨트와 버클
    art.rrect((26, 168, 374, 206), ("v", (60, 52, 58), (24, 20, 26), 168, 206), radius=6)
    art.rrect((168, 160, 232, 214), ("v", (255, 230, 130), (190, 130, 28), 160, 214), radius=8)
    art.rrect((180, 172, 220, 202), (48, 40, 46), radius=4)
    # 단추
    for y in (60, 120):
        art.ellipse((186, y, 214, y + 28), ("r", 198, y + 10, 18, (255, 236, 150), (176, 116, 22)))
    # 아랫단 털
    art.rrect((28, 244, 372, 296), ("v", (255, 255, 255), (206, 218, 236), 244, 296), radius=26)
    art.texture(lambda d: d.rounded_rectangle([28 * 4, 244 * 4, 372 * 4, 296 * 4], radius=26 * 4, fill=255), 140, 8, (255, 255, 255), (178, 194, 220), length=(5, 9), alpha=0.6)
    return art.out()


def _reindeer(art, ox, nose_red):
    body = ("v", (176, 124, 84), (112, 72, 46), 196, 300)
    # 다리(뒤쪽 어둡게)
    for lx, shade in ((86, 0.8), (118, 1.0), (170, 0.85), (196, 1.0)):
        c = (int(150 * shade), int(100 * shade), int(66 * shade))
        art.stroke([(ox + lx, 276), (ox + lx - 7, 352)], c, 13)
        art.rrect((ox + lx - 17, 346, ox + lx + 3, 360), (54, 38, 30), radius=4)
    art.shadow(lambda d, s: d.ellipse([s(ox + 50), s(206), s(ox + 214), s(300)], fill=255), color=(40, 20, 10), alpha=0.25, blur=4, dy=4)
    art.ellipse((ox + 50, 204, ox + 214, 296), body)
    art.ellipse((ox + 74, 260, ox + 190, 296), (238, 214, 180, 255), alpha=0.8)  # 배 쪽 밝은 털
    art.poly([(ox + 54, 232), (ox + 30, 214), (ox + 40, 244)], (140, 96, 64))  # 꼬리
    # 목과 머리
    art.poly([(ox + 176, 232), (ox + 214, 170), (ox + 238, 186), (ox + 206, 252)], ("v", (190, 138, 94), (130, 86, 56), 170, 252))
    art.ellipse((ox + 206, 150, ox + 270, 204), ("r", ox + 232, 168, 44, (200, 150, 104), (126, 82, 54)))
    art.ellipse((ox + 246, 176, ox + 286, 206), (238, 214, 180))  # 주둥이
    art.ellipse((ox + 270, 176, ox + 288, 194), (255, 90, 80) if nose_red else (60, 40, 34))
    if nose_red:
        art.glow(ox + 279, 185, 24, (255, 90, 80), 0.55)
        art.ellipse((ox + 274, 178, ox + 279, 183), (255, 255, 255, 220))
    art.ellipse((ox + 236, 166, ox + 248, 178), (30, 22, 20))
    art.ellipse((ox + 238, 168, ox + 242, 172), (255, 255, 255, 230))
    art.poly([(ox + 214, 160), (ox + 200, 138), (ox + 224, 150)], (150, 100, 66))  # 귀
    for sign_x, h in ((0, 1.0), (22, 0.85)):
        pts = [(ox + 216 + sign_x, 154), (ox + 208 + sign_x, 114 * 1.0), (ox + 220 + sign_x, 76 * h + 20), (ox + 238 + sign_x, 62 * h + 14)]
        art.stroke(pts, ("v", (176, 130, 90), (112, 74, 48), 60, 154), 8)
        art.stroke([(ox + 210 + sign_x, 112), (ox + 192 + sign_x, 96)], (150, 106, 70), 6)
    # 멍에 끈과 방울
    art.stroke([(ox + 196, 236), (ox + 230, 222)], (190, 36, 46), 8)
    art.ellipse((ox + 220, 214, ox + 240, 236), ("r", ox + 228, 222, 12, (255, 236, 150), (190, 130, 26)))


def santa_actor():
    art = Art(768, 480)
    # 날아가는 반짝임(뒤쪽 왼쪽)
    for x, y, r in ((18, 120, 10), (54, 70, 7), (30, 210, 8), (80, 160, 6), (12, 300, 6)):
        art.poly(star_points(x, y, r, 0.3), (255, 246, 190, 220))
        art.glow(x, y, r * 1.8, (255, 238, 160), 0.35)
    _reindeer(art, 130, False)
    _reindeer(art, -12, True)
    art.stroke([(210, 250), (330, 270), (414, 282)], (176, 36, 46), 7)
    art.stroke([(222, 244), (330, 262), (418, 276)], (255, 214, 120, 255), 2.5)
    # 썰매 몸체
    art.shadow(lambda d, s: d.polygon([(s(400), s(246)), (s(706), s(246)), (s(688), s(350)), (s(430), s(350))], fill=255), color=(40, 10, 20), alpha=0.28, blur=6, dy=6)
    art.poly([(396, 236), (712, 236), (736, 262), (700, 350), (430, 350)], ("v", (232, 66, 70), (150, 24, 38), 236, 350))
    art.poly([(404, 244), (704, 244), (710, 262), (412, 268)], (255, 160, 150, 80))
    art.stroke([(410, 300), (700, 300)], (255, 214, 120), 5)
    art.stroke([(420, 330), (692, 330)], (255, 214, 120, 255), 3)
    art.poly([(396, 236), (396, 200), (428, 214), (440, 246)], ("v", (232, 66, 70), (170, 30, 42), 200, 246))  # 앞 곡선
    # 활주
    art.stroke([(380, 394), (470, 394), (700, 394), (748, 372), (758, 340)], ("h", (255, 232, 150), (190, 130, 28), 380, 758), 9)
    art.stroke([(450, 350), (450, 394)], (214, 160, 48), 6)
    art.stroke([(650, 350), (650, 394)], (214, 160, 48), 6)
    # 선물 자루
    art.ellipse((636, 150, 760, 290), ("r", 676, 190, 90, (190, 140, 96), (110, 70, 46)))
    art.poly([(676, 160), (700, 128), (722, 164)], (96, 60, 40))
    art.stroke([(676, 162), (714, 162)], (255, 214, 120), 5)
    for x, y, r in ((700, 200, 9), (730, 236, 7)):
        art.poly(star_points(x, y, r, 0.3), (255, 250, 220, 230))
    # 산타
    art.shadow(lambda d, s: d.ellipse([s(470), s(150), s(646), s(300)], fill=255), color=(60, 10, 20), alpha=0.2, blur=5, dy=4)
    art.ellipse((466, 150, 644, 296), ("h", (240, 80, 78), (160, 26, 40), 466, 644))  # 몸
    art.rrect((466, 238, 644, 262), (46, 38, 44), radius=6)
    art.rrect((534, 232, 574, 268), ("v", (255, 230, 130), (190, 130, 28), 232, 268), radius=6)
    art.rrect((516, 160, 556, 296), ("v", (255, 255, 255), (214, 224, 240), 160, 296), radius=12)
    art.ellipse((498, 100, 612, 206), ("r", 548, 140, 70, (255, 226, 200), (232, 176, 140)))  # 얼굴
    art.ellipse((508, 148, 534, 170), (255, 150, 140, 120))
    art.ellipse((580, 148, 606, 170), (255, 150, 140, 120))
    # 수염
    art.poly([(500, 150), (510, 220), (548, 244), (588, 222), (610, 150), (586, 170), (548, 182), (516, 170)], ("v", (255, 255, 255), (206, 218, 238), 150, 244))
    art.ellipse((520, 168, 580, 196), ("v", (255, 255, 255), (222, 230, 244), 168, 196))
    art.ellipse((532, 152, 546, 166), (255, 190, 170))  # 코
    for ex in (520, 574):
        art.ellipse((ex, 126, ex + 14, 140), (34, 28, 30))
        art.ellipse((ex + 3, 128, ex + 7, 132), (255, 255, 255, 230))
        art.stroke([(ex - 4, 118), (ex + 18, 116)], (236, 240, 248), 5)
    # 모자
    art.poly([(496, 112), (516, 52), (560, 22), (606, 44), (622, 112)], ("h", (240, 80, 78), (160, 26, 40), 496, 622))
    art.stroke([(560, 22), (606, 44), (630, 96)], ("h", (240, 80, 78), (160, 26, 40), 560, 630), 22)
    art.ellipse((612, 82, 648, 118), ("r", 628, 98, 22, (255, 255, 255), (214, 224, 238)))
    art.rrect((488, 98, 630, 128), ("v", (255, 255, 255), (214, 224, 240), 98, 128), radius=15)
    # 손 흔들기
    art.ellipse((610, 186, 652, 224), ("r", 628, 200, 26, (255, 230, 210), (232, 176, 140)))
    art.ellipse((600, 214, 650, 250), ("v", (240, 80, 78), (160, 26, 40), 214, 250))
    return art.out()


def star_icon():
    art = Art(96, 96)
    art.glow(48, 50, 36, (255, 220, 120), 0.4)
    rounded_star(art, 48, 50, 36, (255, 240, 150), (228, 150, 30), outline=(170, 110, 20, 90))
    return art.out()
