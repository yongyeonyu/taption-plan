#!/usr/bin/env python3
"""시즌 팩 시드 자산 생성기 (SEA1119A01).

`Packages/SeasonPackKit/Sources/SeasonPackKit/Resources/` 아래에 표본 팩(`seed-debug/sample/1`)과
크리스마스 팩(`seed/christmas/1`)의 PNG·소리·manifest.json을 만든다. 같은 입력이면 같은 파일이 나온다.

- 그림: Pillow로 4배로 그린 뒤 줄여 PNG로 저장(SVG는 다운로드 자산으로 쓸 수 없다).
- 소리: 「Jingle Bells」(1857, 퍼블릭 도메인 멜로디)를 오르골 음색으로 코드 합성해 afconvert로 AAC 96kbps 모노 m4a로 만든다.
  가사 큐 시각은 합성한 음표 시각에서 그대로 계산한다(별도 녹음 없음).

실행: python3 tools/season-pack/generate_season_packs.py
"""
import hashlib
import json
import math
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
RES = ROOT / "Packages/SeasonPackKit/Sources/SeasonPackKit/Resources"
SS = 4  # 슈퍼샘플


def canvas(w, h):
    return Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))


def finish(img, w, h):
    return img.resize((w, h), Image.LANCZOS)


def s(v):
    return int(round(v * SS))


def poly(d, pts, fill, outline=None, width=0):
    d.polygon([(s(x), s(y)) for x, y in pts], fill=fill, outline=outline, width=s(width) if width else 0)


def ell(d, box, fill, outline=None, width=0):
    d.ellipse([s(box[0]), s(box[1]), s(box[2]), s(box[3])], fill=fill, outline=outline, width=s(width) if width else 0)


def rect(d, box, fill, radius=0):
    if radius:
        d.rounded_rectangle([s(box[0]), s(box[1]), s(box[2]), s(box[3])], radius=s(radius), fill=fill)
    else:
        d.rectangle([s(box[0]), s(box[1]), s(box[2]), s(box[3])], fill=fill)


def star(d, cx, cy, r, fill, inner=0.45):
    pts = []
    for i in range(10):
        a = -math.pi / 2 + i * math.pi / 5
        rr = r if i % 2 == 0 else r * inner
        pts.append((cx + rr * math.cos(a), cy + rr * math.sin(a)))
    poly(d, pts, fill)


ORN = [(214, 48, 49), (240, 180, 41), (64, 120, 210), (214, 48, 49), (240, 180, 41), (64, 120, 210), (214, 48, 49)]
ORN_POS = [(256, 168), (214, 222), (300, 238), (178, 300), (260, 306), (338, 318), (210, 392), (310, 396)]


def tree(lit):
    img = canvas(512, 512)
    d = ImageDraw.Draw(img)
    ell(d, (40, 410, 472, 500), (238, 244, 252, 255))  # 눈 쌓인 땅
    ell(d, (90, 428, 422, 496), (255, 255, 255, 255))
    rect(d, (232, 400, 280, 450), (120, 80, 52, 255), 6)  # 줄기
    greens = [(46, 125, 72), (36, 110, 62), (28, 96, 54)]
    tiers = [(256, 70, 150, 190), (256, 150, 190, 290), (256, 240, 225, 410)]
    for (cx, top, half, bottom), g in zip(tiers, reversed(greens)):
        poly(d, [(cx, top), (cx - half, bottom), (cx + half, bottom)], g + (255,))
        poly(d, [(cx, top), (cx - half * 0.15, bottom), (cx - half, bottom)], tuple(max(0, c - 14) for c in g) + (255,))
    # 갈란드(별 모양 줄)
    for y, half in ((180, 78), (270, 120), (372, 160)):
        d.line([(s(256 - half), s(y + 26)), (s(256), s(y)), (s(256 + half), s(y + 26))], fill=(250, 236, 200, 255), width=s(5))
    # 전구/장식
    for i, (x, y) in enumerate(ORN_POS):
        base = ORN[i % len(ORN)]
        if lit:
            glow = Image.new("RGBA", img.size, (0, 0, 0, 0))
            gd = ImageDraw.Draw(glow)
            ell(gd, (x - 22, y - 22, x + 22, y + 22), (255, 226, 120, 190))
            glow = glow.filter(ImageFilter.GaussianBlur(s(9)))
            img = Image.alpha_composite(img, glow)
            d = ImageDraw.Draw(img)
            ell(d, (x - 10, y - 10, x + 10, y + 10), (255, 244, 190, 255))
            ell(d, (x - 5, y - 6, x, y - 1), (255, 255, 255, 230))
        else:
            ell(d, (x - 10, y - 10, x + 10, y + 10), base + (255,))
            ell(d, (x - 5, y - 6, x - 1, y - 2), (255, 255, 255, 170))
    if lit:
        star(d, 256, 62, 44, (255, 236, 120, 255))
    else:
        star(d, 256, 62, 40, (232, 188, 60, 255))
    return finish(img, 512, 512)


def star_glow():
    img = canvas(512, 512)
    halo = Image.new("RGBA", img.size, (0, 0, 0, 0))
    gd = ImageDraw.Draw(halo)
    ell(gd, (256 - 70, 62 - 70, 256 + 70, 62 + 70), (255, 238, 150, 200))
    halo = halo.filter(ImageFilter.GaussianBlur(s(22)))
    img = Image.alpha_composite(img, halo)
    d = ImageDraw.Draw(img)
    star(d, 256, 62, 50, (255, 244, 170, 255))
    for dx, dy, r in ((-60, 14, 9), (62, 4, 7), (-30, -34, 6), (40, -40, 8)):
        star(d, 256 + dx, 62 + dy, r, (255, 255, 255, 235), 0.3)
    return finish(img, 512, 512)


def bell_icon():
    img = canvas(96, 96)
    d = ImageDraw.Draw(img)
    poly(d, [(48, 14), (26, 56), (70, 56)], (240, 186, 48, 255))
    ell(d, (26, 24, 70, 64), (240, 186, 48, 255))
    rect(d, (20, 54, 76, 66), (222, 160, 30, 255), 6)
    ell(d, (42, 62, 54, 76), (170, 110, 24, 255))
    ell(d, (42, 8, 54, 20), (214, 48, 49, 255))
    poly(d, [(48, 16), (28, 8), (30, 24)], (214, 48, 49, 255))
    poly(d, [(48, 16), (68, 8), (66, 24)], (214, 48, 49, 255))
    return finish(img, 96, 96)


def gift(color):
    img = canvas(96, 96)
    d = ImageDraw.Draw(img)
    rect(d, (14, 34, 82, 84), color + (255,), 6)
    rect(d, (10, 26, 86, 42), tuple(min(255, c + 24) for c in color) + (255,), 4)
    rect(d, (42, 26, 54, 84), (250, 236, 200, 255))
    ell(d, (28, 8, 50, 30), (250, 236, 200, 255))
    ell(d, (46, 8, 68, 30), (250, 236, 200, 255))
    ell(d, (40, 20, 56, 34), (230, 214, 170, 255))
    return finish(img, 96, 96)


def santa_hat():
    w, h = 360, 300
    img = canvas(w, h)
    d = ImageDraw.Draw(img)
    poly(d, [(60, 230), (180, 40), (300, 230)], (214, 48, 49, 255))
    poly(d, [(110, 230), (180, 40), (150, 230)], (186, 36, 40, 255))
    ell(d, (150, 10, 214, 70), (255, 255, 255, 255))
    rect(d, (36, 216, 324, 284), (255, 255, 255, 255), 30)
    return finish(img, w, h)


def scarf():
    w, h = 360, 150
    img = canvas(w, h)
    d = ImageDraw.Draw(img)
    rect(d, (10, 20, 350, 90), (214, 48, 49, 255), 34)
    for x in range(40, 330, 56):
        rect(d, (x, 22, x + 20, 88), (255, 255, 255, 255))
    rect(d, (60, 70, 130, 146), (214, 48, 49, 255), 14)
    for y in (96, 118):
        rect(d, (60, y, 130, y + 10), (255, 255, 255, 255))
    return finish(img, w, h)


def antlers():
    w, h = 420, 260
    img = canvas(w, h)
    d = ImageDraw.Draw(img)
    brown = (140, 92, 58, 255)
    for sign in (-1, 1):
        cx = 210 + sign * 118
        d.line([(s(210 + sign * 70), s(250)), (s(cx), s(130)), (s(cx + sign * 18), s(30))], fill=brown, width=s(18), joint="curve")
        d.line([(s(cx), s(130)), (s(cx + sign * 60), s(90))], fill=brown, width=s(14))
        d.line([(s(cx + sign * 8), s(80)), (s(cx - sign * 40), s(50))], fill=brown, width=s(12))
        ell(d, (cx + sign * 18 - 12, 18, cx + sign * 18 + 12, 42), brown)
    return finish(img, w, h)


def coat():
    w, h = 400, 300
    img = canvas(w, h)
    d = ImageDraw.Draw(img)
    ell(d, (20, 10, 380, 330), (214, 48, 49, 255))
    rect(d, (176, 10, 224, 300), (255, 255, 255, 255))
    for y in (80, 160, 240):
        ell(d, (190, y, 210, y + 20), (40, 40, 40, 255))
    rect(d, (30, 236, 370, 292), (255, 255, 255, 255), 24)
    return finish(img, w, h)


def santa_actor():
    w, h = 768, 480
    img = canvas(w, h)
    d = ImageDraw.Draw(img)
    brown = (140, 92, 58, 255)
    # 루돌프 두 마리
    for ox in (0, 150):
        ell(d, (60 + ox, 210, 190 + ox, 290), brown)
        for lx in (80, 110, 150, 170):
            d.line([(s(lx + ox), s(280)), (s(lx + ox - 6), s(350))], fill=brown, width=s(11))
        d.line([(s(172 + ox), s(222)), (s(206 + ox), s(172))], fill=brown, width=s(18))
        ell(d, (190 + ox, 150, 244 + ox, 196), brown)
        ell(d, (236 + ox, 168, 254 + ox, 186), (214, 48, 49, 255) if ox == 0 else (60, 40, 30, 255))
        d.line([(s(206 + ox), s(152)), (s(196 + ox), s(110)), (s(214 + ox), s(84))], fill=(110, 72, 44, 255), width=s(9))
        d.line([(s(222 + ox), s(152)), (s(236 + ox), s(110)), (s(222 + ox), s(84))], fill=(110, 72, 44, 255), width=s(9))
    d.line([(s(250), s(250)), (s(380), s(290))], fill=(90, 60, 40, 255), width=s(6))
    # 썰매
    poly(d, [(380, 250), (700, 250), (680, 340), (420, 340)], (176, 38, 44, 255))
    rect(d, (380, 330, 740, 346), (232, 200, 90, 255), 8)
    d.arc([s(350), s(300), s(430), s(400)], 180, 300, fill=(232, 200, 90, 255), width=s(10))
    # 산타
    ell(d, (470, 140, 640, 290), (214, 48, 49, 255))
    ell(d, (500, 90, 600, 190), (250, 220, 190, 255))
    poly(d, [(488, 110), (550, 20), (616, 110)], (214, 48, 49, 255))
    ell(d, (536, 4, 566, 34), (255, 255, 255, 255))
    rect(d, (484, 100, 620, 122), (255, 255, 255, 255), 10)
    ell(d, (500, 140, 600, 220), (255, 255, 255, 255))
    ell(d, (526, 130, 538, 142), (40, 40, 40, 255))
    ell(d, (562, 130, 574, 142), (40, 40, 40, 255))
    # 선물 자루
    ell(d, (640, 170, 740, 290), (120, 80, 52, 255))
    return finish(img, w, h)


def star_icon():
    img = canvas(96, 96)
    d = ImageDraw.Draw(img)
    star(d, 48, 50, 38, (240, 186, 48, 255))
    return finish(img, 96, 96)


# ---- 소리 ---------------------------------------------------------------------------------
NOTE = {"C": 261.63, "D": 293.66, "E": 329.63, "F": 349.23, "G": 392.00}
BPM = 120
BEAT = 60 / BPM
LEAD = 0.4
# (음, 박)  ('R' = 쉼)
CHORUS = [
    ("E", 1), ("E", 1), ("E", 2),
    ("E", 1), ("E", 1), ("E", 2),
    ("E", 1), ("G", 1), ("C", 1.5), ("D", 0.5),
    ("E", 4),
    ("F", 1), ("F", 1), ("F", 1.5), ("F", 0.5),
    ("F", 1), ("E", 1), ("E", 1), ("E", 0.5), ("E", 0.5),
    ("E", 1), ("D", 1), ("D", 1), ("E", 1),
    ("D", 2), ("G", 2),
]
MEASURE_BEATS = 4
PASS_BEATS = 32


def synth(path_wav):
    sr = 44100
    total = LEAD + 2 * PASS_BEATS * BEAT + 2.2
    buf = np.zeros(int(sr * total))
    t_note = LEAD
    for _ in range(2):
        for name, beats in CHORUS:
            f = NOTE[name] * 2  # 오르골은 높게
            n = int(sr * 1.6)
            t = np.arange(n) / sr
            env = np.exp(-t / 0.42)
            env[: int(sr * 0.003)] *= np.linspace(0, 1, int(sr * 0.003))
            tone = sum(a * np.sin(2 * np.pi * f * m * t) * np.exp(-t * k) for m, a, k in ((1, 1.0, 0.0), (2.0, 0.35, 1.5), (3.01, 0.18, 3.0), (4.17, 0.08, 5.0)))
            start = int(sr * t_note)
            seg = (tone * env)[: len(buf) - start]
            buf[start : start + len(seg)] += seg * 0.3
            t_note += beats * BEAT
    # 마지막 길게 울리는 끝음(C)
    f = NOTE["C"] * 2
    n = int(sr * 2.2)
    t = np.arange(n) / sr
    tone = (np.sin(2 * np.pi * f * t) + 0.35 * np.sin(2 * np.pi * f * 2 * t)) * np.exp(-t / 0.8)
    start = int(sr * t_note)
    seg = tone[: len(buf) - start]
    buf[start : start + len(seg)] += seg * 0.3
    # 가벼운 잔향
    for delay, gain in ((0.045, 0.28), (0.083, 0.18), (0.131, 0.1)):
        d = int(sr * delay)
        buf[d:] += buf[:-d] * gain
    buf = np.tanh(buf * 1.2)
    buf = buf / np.max(np.abs(buf)) * 0.85
    fade = int(sr * 0.05)
    buf[-fade:] *= np.linspace(1, 0, fade)
    with wave.open(str(path_wav), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes((buf * 32767).astype(np.int16).tobytes())
    return total, t_note


def encode(wav, out):
    out.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["afconvert", str(wav), str(out), "-f", "m4af", "-d", "aac", "-b", "96000", "-c", "1"], check=True)
    info = subprocess.run(["afinfo", str(out)], capture_output=True, text=True, check=True).stdout
    for line in info.splitlines():
        if "estimated duration" in line:
            return int(float(line.split(":")[1].split()[0]) * 1000)
    return 0


# ---- 매니페스트 -------------------------------------------------------------------------------
def sha(data):
    return hashlib.sha256(data).hexdigest()


def write_png(img, folder, name):
    path = folder / name
    img.save(path, optimize=True)
    return path.read_bytes()


def asset(asset_id, path, data, kind):
    return {"id": asset_id, "path": path, "sha256": sha(data), "bytes": len(data), "kind": kind}


def christmas(folder):
    folder.mkdir(parents=True, exist_ok=True)
    assets = []

    def img(asset_id, name, image):
        assets.append(asset(asset_id, name, write_png(image, folder, name), "image"))

    img("house.tree", "house-tree.png", tree(False))
    img("house.tree.lit", "house-tree-lit.png", tree(True))
    img("house.tree.star", "house-tree-star.png", star_glow())
    img("icon.bell", "icon-bell.png", bell_icon())
    img("actor.santa", "actor-santa.png", santa_actor())
    img("gift.a", "gift-a.png", gift((214, 48, 49)))
    img("gift.b", "gift-b.png", gift((46, 125, 72)))
    img("gift.c", "gift-c.png", gift((64, 120, 210)))
    img("accessory.santaHat", "accessory-santa-hat.png", santa_hat())
    img("accessory.scarf", "accessory-scarf.png", scarf())
    img("accessory.antlers", "accessory-antlers.png", antlers())
    img("outfit.coat", "outfit-coat.png", coat())

    with tempfile.TemporaryDirectory() as tmp:
        wav = Path(tmp) / "jingle.wav"
        total, _ = synth(wav)
        m4a = folder / "audio" / "jingle-bells.m4a"
        duration = encode(wav, m4a)
    data = m4a.read_bytes()
    assets.append(asset("carol.jingle", "audio/jingle-bells.m4a", data, "audio"))

    def cue(pass_index, measure, en, ko):
        at = LEAD + (pass_index * PASS_BEATS + measure * MEASURE_BEATS) * BEAT
        return {"atMs": int(round(at * 1000)), "ko": ko, "en": en}

    lines = [
        (0, "Jingle bells, jingle bells,", "딸랑딸랑, 종이 울려요"),
        (2, "Jingle all the way!", "눈길을 신나게 달려요!"),
        (4, "Oh, what fun it is to ride", "썰매를 타면 얼마나 신나는지"),
        (6, "In a one-horse open sleigh!", "말 한 마리 썰매를 타고!"),
    ]
    cues = [cue(p, m, en, ko) for p in range(2) for m, en, ko in lines]
    cues.append({"atMs": int(round((LEAD + 2 * PASS_BEATS * BEAT) * 1000)), "ko": "메리 크리스마스!", "en": "Merry Christmas!"})

    pool = [
        ("트리 불 켜 볼까요? 🎄", "Shall we light the tree? 🎄"),
        ("메리 크리스마스! 🎄", "Merry Christmas! 🎄"),
        ("산타가 지나갔어요!", "Santa just flew by!"),
        ("오늘 하루도 수고했어요", "You did great today"),
        ("트리가 반짝반짝해요 ✨", "The tree is sparkling ✨"),
        ("눈이 오면 좋겠다", "I hope it snows"),
        ("따뜻한 코코아 한 잔 어때요?", "How about some hot cocoa?"),
        ("선물은 마음이 제일이에요", "The best gift is the thought"),
        ("밤하늘에 썰매 소리가 나요", "I hear sleigh bells tonight"),
        ("집이 포근해요", "Home feels so cozy"),
        ("오늘 하루를 기록해 둘까요?", "Shall we jot down today?"),
        ("산타 모자 어울리죠?", "Doesn't the Santa hat suit me?"),
        ("눈사람 만들러 갈까요?", "Want to build a snowman?"),
        ("연말까지 조금만 더 힘내요", "Just a little more until year's end"),
    ]
    manifest = {
        "format": "bokki-season-pack", "schema": 1, "id": "christmas", "version": 1, "requiresAppBuild": 1, "priority": 10,
        "event": {
            "id": "christmas", "kind": "holiday", "announcementId": "christmas-2026",
            "title": {"ko": "크리스마스", "en": "Christmas"},
            "windows": [{"from": {"month": 12, "day": 19}, "to": {"month": 12, "day": 30}, "fromTime": "00:00", "toTime": "23:59"}],
        },
        "assets": assets,
        "slots": {
            "house": {"base": "house.tree", "lit": "house.tree.lit", "glow": "house.tree.star",
                      "lights": {"on": "sunset", "off": "sunrise", "blink": {"periodMs": 1400, "fastPeriodMs": 220}}},
            "outfit": {c: [{"asset": "outfit.coat", "anchor": "body", "scale": 0.62, "offset": [0, 0.02], "z": 0}] for c in ("white", "calico", "mackerel")},
            "accessory": {
                "hat": {"asset": "accessory.santaHat", "anchor": "head", "scale": 0.42, "offset": [0.02, -0.1], "z": 3},
                "scarf": {"asset": "accessory.scarf", "anchor": "head", "scale": 0.5, "offset": [0, 0.13], "z": 2},
                "ribbon": {"asset": "accessory.antlers", "anchor": "head", "scale": 0.62, "offset": [0, -0.1], "z": 1},
            },
            "bubbles": {"pool": [{"ko": ko, "en": en} for ko, en in pool]},
            "shareCard": {"house": "house.tree", "outfit": True},
        },
        "textSlots": [{"id": "year", "rect": [0.3, 0.86, 0.4, 0.1], "align": "center",
                       "font": {"size": 11, "weight": "bold", "design": "rounded"}, "color": "#C23B3B", "content": "year", "transition": "roll"}],
        "menuIcons": [{
            "id": "christmas.info", "icon": "icon.bell", "label": {"ko": "크리스마스 안내", "en": "Christmas info"},
            "anchor": {"dx": 46, "dy": -30}, "priority": 10,
            "visibleFrom": "2026-12-19T00:00", "visibleTo": "2026-12-30T23:59",
            "menu": {"title": {"ko": "크리스마스", "en": "Christmas"}, "sections": [
                {"title": {"ko": "이벤트 소개", "en": "About this event"},
                 "items": [{"id": "intro", "kind": "text",
                            "text": {"ko": "12월 19일부터 30일까지 집이 트리로 바뀌어요. 해가 지면 불이 켜지고, 트리를 누르면 캐럴이 나와요.",
                                     "en": "From Dec 19 to 30 your home becomes a tree. It lights up at sunset, and tapping it plays a carol."}}]},
                {"title": {"ko": "음원 출처", "en": "Music credits"}, "items": [{"id": "credits", "kind": "credits"}]},
            ]},
        }],
        "audio": [{"id": "carol", "asset": "carol.jingle", "durationMs": duration, "loop": False,
                   "license": {"title": "Jingle Bells (music box rendition)", "creator": "BOKKI Plan (synthesized)",
                               "license": "Public-domain melody (J. Pierpont, 1857); original synthesis",
                               "source": "https://en.wikipedia.org/wiki/Jingle_Bells"}}],
        "lyrics": [{"audio": "carol", "cues": cues}],
        "actors": [{"id": "santa", "image": "actor.santa", "flight": {"seconds": 9, "start": [-0.2, 0.3], "end": [1.2, 0.18]},
                    "intervalSeconds": [180, 300], "tap": {"burst": {"images": ["gift.a", "gift.b", "gift.c"], "count": 18}}}],
        "interactions": [{"id": "tree.tap", "target": "house", "on": "tap",
                          "actions": [{"kind": "blink", "seconds": 6}, {"kind": "playAudio", "audio": "carol"}, {"kind": "lyrics", "audio": "carol"}]}],
        "credits": [{"ko": "음원: 「Jingle Bells」 오르골 편곡(멜로디 1857, 퍼블릭 도메인) · 앱에서 합성",
                     "en": "Music: Jingle Bells, music-box rendition (melody 1857, public domain), synthesized for the app"}],
    }
    (folder / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return manifest


def sample(folder):
    folder.mkdir(parents=True, exist_ok=True)
    data = write_png(star_icon(), folder, "icon-star.png")
    manifest = {
        "format": "bokki-season-pack", "schema": 1, "id": "sample", "version": 1, "priority": 0,
        "event": {"id": "sample", "kind": "sample", "title": {"ko": "표본", "en": "Sample"},
                  "windows": [{"from": {"month": 1, "day": 1}, "to": {"month": 1, "day": 1}, "year": 1970}]},
        "assets": [asset("icon.star", "icon-star.png", data, "image")],
        "menuIcons": [{
            "id": "sample.icon", "icon": "icon.star", "label": {"ko": "표본 아이콘", "en": "Sample icon"},
            "anchor": {"dx": 46, "dy": -30}, "priority": 1,
            "menu": {"title": {"ko": "표본 메뉴", "en": "Sample menu"}, "sections": [
                {"title": {"ko": "안내", "en": "Info"}, "items": [{"id": "hello", "kind": "text",
                                                                   "text": {"ko": "매니페스트에 항목만 넣어도 아이콘과 메뉴가 붙습니다.", "en": "Adding a manifest entry is enough to get an icon and a menu."}},
                                                                  {"id": "note", "kind": "memo", "label": {"ko": "메모", "en": "Note"}, "maxLength": 100}]}]},
        }],
    }
    (folder / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    christmas(RES / "seed/christmas/1")
    sample(RES / "seed-debug/sample/1")
    print("done")
