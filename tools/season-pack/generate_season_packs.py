#!/usr/bin/env python3
"""시즌 팩 시드 자산 생성기 (SEA1119A01).

`Packages/SeasonPackKit/Sources/SeasonPackKit/Resources/` 아래에 표본 팩(`seed-debug/sample/1`)과
크리스마스 팩(`seed/christmas/1`)의 PNG·소리·manifest.json을 만든다. 같은 입력이면 같은 파일이 나온다.

- 그림: `season_art.py`·`season_images.py`가 Pillow로 4배로 그려(그라데이션·그림자·질감) 줄여 PNG로 저장한다(SVG는 다운로드 자산으로 쓸 수 없다).
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

from season_images import (BULB_POINTS, antlers, bell_icon, coat, gift, santa_actor, santa_hat, scarf, star_glow, star_icon, tree)

import os

ROOT = Path(__file__).resolve().parents[2]
RES = Path(os.environ["SEASON_PACK_OUT"]) if os.environ.get("SEASON_PACK_OUT") else ROOT / "Packages/SeasonPackKit/Sources/SeasonPackKit/Resources"
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
    img("gift.a", "gift-a.png", gift("a"))
    img("gift.b", "gift-b.png", gift("b"))
    img("gift.c", "gift-c.png", gift("c"))
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
                      "lights": {"on": "sunset", "off": "sunrise", "blink": {"periodMs": 1400, "fastPeriodMs": 220}},
                      "bulbs": {"points": list(BULB_POINTS), "groups": 4, "stepMs": 300}},
            # 산타 복장은 그림 파일 대신 화랑이 리그가 모든 동작에 직접 그린다(모자만 그림 파일).
            "accessory": {
                "hat": {"asset": "accessory.santaHat", "anchor": "head", "scale": 0.42, "offset": [0.02, -0.1], "z": 3},
            },
            "costume": {
                "redNose": True,
                "antlers": "8A5A36",
                "scarf": {"base": "D63A3A", "shade": "AD2A2D", "accent": "FFF6EC", "trim": "FFF6EC", "pattern": "bands"},
                "ribbon": {"base": "2F9E58", "shade": "1F7A41", "accent": "FFF6EC", "trim": "D63A3A", "pattern": "dots"},
            },
            # 트리가 나와 있는 동안 날씨와 무관하게 눈꽃송이가 사르르 내린다.
            "effects": {"snow": {"count": 34, "minSize": 7, "maxSize": 17, "minSpeed": 14, "maxSpeed": 30}},
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
