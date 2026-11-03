#!/usr/bin/env python3
"""화랑이 장식 52개(모자 17·스카프 17·꼬리 리본 18)를 SVG 이미지 세트와 Swift 색 표로 만든다(ACC1101A01, ACC1102A01)."""
import json, math, os, shutil, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "TaptionPlan/Assets.xcassets")
STYLES = os.path.join(ROOT, "TaptionPlan/UI/HwarangRigAccessoryStyles.swift")
O = "#3B2A1F"

def S(body):
    return f'<g stroke="{O}" stroke-width="3" stroke-linejoin="round" stroke-linecap="round">{body}</g>'

def brim(fill, y=45, rx=29, ry=7):
    return f'<ellipse cx="32" cy="{y}" rx="{rx}" ry="{ry}" fill="{fill}"/>'

def wide(crown, rim, band, motif="", top=14):
    """둥근 챙 모자."""
    return S(brim(rim) + f'<path d="M15 41C15 {top+6} 22 {top} 32 {top}s17 {top+6-top} 17 27c-10-3-24-3-34 0z" fill="{crown}"/>'
             f'<path d="M15 41c10-4 24-4 34 0l-.6-7c-10-3-23-3-33 0z" fill="{band}"/>' + motif)

def beanie(color, cuff, motif="", pom="#FFFFFF"):
    p = f'<circle cx="32" cy="7" r="5" fill="{pom}"/>' if pom else ""
    return S(p + f'<path d="M10 42c0-20 9-30 22-30s22 10 22 30z" fill="{color}"/>' + motif +
             f'<rect x="7" y="40" width="50" height="12" rx="5" fill="{cuff}"/>'
             '<path d="M16 42v8M26 42v8M38 42v8M48 42v8" fill="none" stroke-width="2"/>')

def cone(color, rim=None, motif="", tip=6):
    return S(f'<path d="M32 {tip}L60 48c-14 6-42 6-56 0z" fill="{color}"/>' + motif)

def cap(color, bill, motif="", top=""):
    return S(top + f'<path d="M12 44c0-20 9-30 20-30s20 10 20 30z" fill="{color}"/>'
             f'<path d="M30 42c12-4 24-3 32 2-1 6-10 7-16 6-6-1-12-3-16-8z" fill="{bill}"/>' + motif)

def helmet(color, crest="", motif="", trim=None):
    return S(crest + f'<path d="M9 52V36c0-12 10-20 23-20s23 8 23 20v16l-8-3v-8c-9-3-21-3-30 0v8z" fill="{color}"/>'
             '<path d="M16 32c10-4 22-4 32 0" fill="none" stroke-width="2.5"/>' + motif)

def crown(color, band, gems="#E2502F"):
    return S(f'<path d="M8 40 6 14l13 12 13-20 13 20 13-12-2 26z" fill="{color}"/>'
             f'<path d="M8 38c15-5 33-5 48 0v13c-15-4-33-4-48 0z" fill="{band}"/>'
             f'<circle cx="20" cy="44" r="2.5" fill="{gems}" stroke-width="1.5"/><circle cx="32" cy="43" r="2.5" fill="{gems}" stroke-width="1.5"/><circle cx="44" cy="44" r="2.5" fill="{gems}" stroke-width="1.5"/>')

SUN = '<circle cx="32" cy="27" r="5" fill="#F2B632" stroke-width="2"/>'
WAVE = '<path d="M22 37c2-2 4-2 6 0s4 2 6 0 4-2 6 0" fill="none" stroke="#FFFFFF" stroke-width="2"/>'

HATS = {
    "kr.gyeongbokgung": S('<path d="M22 40V14c0-5 20-5 20 0v26z" fill="#37322E"/><path d="M22 34c6 2 14 2 20 0v6H22z" fill="#C8473A"/><ellipse cx="32" cy="43" rx="29" ry="7" fill="#4A433D"/><path d="M26 50v4M38 50v4" fill="none" stroke="#E7BE4F" stroke-width="3"/>'),
    "kr.bulguksa": cone("#C9A66B", motif='<path d="M27 40h10M28 34h8M29 28h6M32 22v18" fill="none" stroke-width="2.4"/>'),
    "kr.seongsan": wide("#6DAA6B", "#5A9458", "#3F7F52", SUN + WAVE),
    "kr.haeundae": wide("#F7DD93", "#F0D07C", "#3BA6DC", WAVE),
    "kr.hahoe": S('<path d="M10 44c-2-22 10-34 22-34s24 12 22 34c-13-5-31-5-44 0z" fill="#2F4C86"/><ellipse cx="32" cy="32" rx="11" ry="10" fill="#F2DDB0"/><path d="M24 30q3-3 6 0M34 30q3-3 6 0M25 36q7 6 14 0" fill="none" stroke-width="2"/>'),
    # 모자 위에 N서울타워: 기둥, 전망대, 첨탑(HAT1103A01). 타워 자리를 위해 모자 높이를 낮췄다.
    "kr.namsan": S('<path d="M32 9V-1" fill="none" stroke-width="2"/><path d="M32 3V-1" fill="none" stroke="#E2502F" stroke-width="2"/>'
                   '<path d="M29.5 26L30.7 14h2.6L34.5 26z" fill="#EFEBE1" stroke-width="1.8"/>'
                   '<ellipse cx="32" cy="14.5" rx="7" ry="2.2" fill="#F7F4EC" stroke-width="1.8"/>'
                   '<path d="M26.5 14V10.5c2-1.2 9-1.2 11 0V14c-2 1.2-9 1.2-11 0z" fill="#7FA9C9" stroke-width="1.8"/>'
                   '<ellipse cx="32" cy="10" rx="5.6" ry="1.8" fill="#F7F4EC" stroke-width="1.8"/>'
                   '<path d="M12 44c0-14 9-20 20-20s20 6 20 20z" fill="#C8473A"/>'
                   '<path d="M30 42c12-4 24-3 32 2-1 6-10 7-16 6-6-1-12-3-16-8z" fill="#8E2F27"/>'
                   '<path d="M27 38V29l10 9V29" fill="none" stroke="#FFFFFF" stroke-width="2.6"/>'),
    "kr.hallasan": beanie("#F0992C", "#D97F17", "", None) .replace('<g stroke', '<g stroke', 1) + S('<path d="M32 12c-2-6 2-9 8-9 0 6-3 9-8 9z" fill="#5F9E4F" stroke-width="2"/>'),
    "jp.fuji": beanie("#5E78C4", "#E8EEF9", '<path d="M22 18c6-4 14-4 20 0l5 12-6-3-5 5-4-5-4 5-5-5-6 3z" fill="#FFF" stroke-width="2.5"/>'),
    "jp.himeji": helmet("#F2F0E8", '<path d="M32 16 20 2M32 16 44 2" fill="none" stroke="#D9B45F" stroke-width="5"/>', '<circle cx="32" cy="24" r="3.5" fill="#D9B45F" stroke-width="2"/>'),
    "jp.fushimi": S('<path d="M10 36 6 8l18 18zM54 36l4-28-18 18z" fill="#FFF"/><path d="M11 28 9 15l10 10zM53 28l2-13-10 10z" fill="#F3A3A0" stroke-width="0"/><path d="M8 44c0-12 10-20 24-20s24 8 24 20c-15-6-33-6-48 0z" fill="#E2502F"/><path d="M6 44c15-6 37-6 52 0l-2 8c-14-5-34-5-48 0z" fill="#B93A20"/><path d="M23 29h18M26 33h12M27 29v10M37 29v10" fill="none" stroke="#FFF" stroke-width="2.5"/>'),
    "jp.itsukushima": cone("#D9553A", motif='<path d="M22 38h20M24 42h16M26 38v9M38 38v9" fill="none" stroke="#FFFFFF" stroke-width="2.6"/>'),
    "jp.arashiyama": cone("#7FA650", motif='<path d="M24 26 18 47M32 14v35M40 26l6 21" fill="none" stroke-width="2"/>'),
    "us.liberty": S('<path d="M10 38 6 16l11 12 4-20 7 18 4-22 4 22 7-18 4 20 11-12-4 22z" fill="#62BFA5"/><path d="M8 38c15-5 33-5 48 0v13c-15-4-33-4-48 0z" fill="#3F9A83"/><path d="M20 44v0M32 42.5v0M44 44v0" stroke="#FFE27A" stroke-width="5"/>'),
    "us.grandcanyon": S(brim("#9A5B33", 42, 30, 8) + '<path d="M2 38c4 2 8 3 10 3M62 38c-4 2-8 3-10 3" fill="none"/><path d="M17 38C17 18 24 12 28 15c2 2 6 2 8 0 4-3 11 3 11 23-10-3-20-3-30 0z" fill="#B46F3F"/><path d="M17 38c10-4 20-4 30 0v-6c-10-3-20-3-30 0z" fill="#D9553A"/>'),
    "us.golden_gate": S('<path d="M10 42c0-18 10-28 22-28s22 10 22 28z" fill="#D9553A"/><rect x="28" y="10" width="8" height="30" rx="3" fill="#B93A20"/>' + brim("#C8473A", 45, 28, 5) + '<path d="M14 36q18-14 36 0" fill="none" stroke="#FFFFFF" stroke-width="2.2"/>'),
    "us.yosemite": S(brim("#6B7F4A", 44, 30, 6) + '<path d="M18 40 26 14c2-3 10-3 12 0l8 26c-9-3-19-3-28 0z" fill="#7F945A"/><path d="M18 40c9-3 19-3 28 0l-1-6c-8-3-18-3-26 0z" fill="#3F5230"/><circle cx="32" cy="26" r="5" fill="#BFE3F2" stroke-width="2"/><path d="M32 22v8" stroke="#3BA6DC" stroke-width="2"/>'),
    "us.mount_rushmore": S('<rect x="17" y="6" width="30" height="38" rx="3" fill="#8D8F92"/><path d="M17 34h30v9H17z" fill="#5E6063"/><ellipse cx="32" cy="46" rx="27" ry="6" fill="#74777A"/><path d="M24 14l4 8M36 12l-3 9M42 22l-5 3" fill="none" stroke-width="2"/>'),
    "gb.bigben": S('<rect x="17" y="6" width="30" height="38" rx="3" fill="#2F2B33"/><path d="M17 34h30v9H17z" fill="#D9B45F"/><ellipse cx="32" cy="46" rx="27" ry="6" fill="#3F3A44"/><circle cx="32" cy="20" r="9" fill="#FFF" stroke-width="2.5"/><path d="M32 15v5l4 2" fill="none" stroke-width="2.2"/>'),
    "gb.stonehenge": S('<path d="M6 52C4 24 18 8 32 8s28 16 26 44c-6-14-14-20-26-20S12 38 6 52z" fill="#6E7F6A"/><path d="M18 22h6v9h-6zM29 16h6v8h-6zM40 22h6v9h-6z" fill="#C7C4BA" stroke-width="2"/>'),
    "gb.edinburgh": S('<circle cx="40" cy="7" r="5" fill="#2F4C86"/><path d="M4 36C4 20 20 11 36 12c15 1 24 11 23 21-1 7-9 8-14 6-9-3-24-3-33 1-5 2-8 1-8-4z" fill="#C8473A"/><path d="M14 18l26 24M28 12l24 22M6 30l14 12M36 14 12 40M50 18 26 40" fill="none" stroke="#1F3D2C" stroke-width="2"/><path d="M12 42c11-4 29-4 40 0v9c-11-3-29-3-40 0z" fill="#1F3D2C"/>'),
    "gb.lake_district": S('<path d="M10 42C8 24 20 14 34 14c12 0 20 8 20 24-14-6-30-4-44 4z" fill="#8A7A5C"/><path d="M28 34c12-3 24-1 34 6-10 8-24 6-34-6z" fill="#6E6048"/><path d="M18 26c3-3 6-3 9 0s6 3 9 0" fill="none" stroke="#BFE3F2" stroke-width="2.4"/>'),
    "gb.tower_bridge": S('<path d="M14 42C10 18 20 3 32 3s22 15 18 39z" fill="#25211F"/><path d="M15 26l3 4M26 12l3 4M40 16l3 4M44 30l3 4M28 28l3 4" fill="none" stroke="#5A524D" stroke-width="2"/><path d="M12 40c12-3 28-3 40 0v8c-12-3-28-3-40 0z" fill="#C8473A"/><path d="M12 44c6 6 34 6 40 0" fill="none" stroke="#D9B45F" stroke-width="2.4"/>'),
    "fr.eiffel": S('<path d="M5 36C5 21 20 12 36 13c15 1 24 11 23 21-1 7-9 8-14 6-9-3-24-3-33 1-5 2-7-1-7-5z" fill="#2F4C86"/><path d="M36 13c0-3 1-5 3-6" fill="none"/><path d="M12 42c11-4 29-4 40 0v9c-11-3-29-3-40 0z" fill="#C8473A"/><path d="M36 19l1 8 4 8h-3l-2-3-2 3h-3l4-8z" fill="#F4DFA8" stroke-width="1.6"/>'),
    "fr.mont_saint_michel": helmet("#B9C0C8", '<path d="M32 16V2" stroke="#7A8590" stroke-width="5"/>', '<path d="M22 28h20M22 34h20" fill="none" stroke-width="2.4"/>'),
    "fr.louvre": S('<path d="M32 4 60 50H4z" fill="#BFE0F2"/><path d="M22 20h20M15 32h34M9 42h46M32 4 18 50M32 4l14 46" fill="none" stroke-width="1.8"/>'),
    "fr.versailles": crown("#E7BE4F", "#6A3E9A", "#FFFFFF"),
    "fr.alps": beanie("#FFFFFF", "#C8473A", '<path d="M13 30h38M18 21h28" fill="none" stroke="#C8473A" stroke-width="5"/>', "#C8473A"),
    "it.colosseum": helmet("#E2B64E", '<path d="M12 18c8-10 32-10 40 0" fill="none" stroke="#C8473A" stroke-width="9"/>'),
    "it.venice": S(brim("#F0D07C", 44, 30, 6) + '<path d="M16 42V24c8-4 24-4 32 0v18c-10-3-22-3-32 0z" fill="#F7DD93"/><path d="M16 42c10-3 22-3 32 0v-8c-10-3-22-3-32 0z" fill="#C8473A"/><path d="M48 36l10 10M48 40l6 10" fill="none" stroke="#C8473A" stroke-width="3"/>'),
    "it.pisa": S('<g transform="rotate(10 32 52)"><path d="M18 40c-8-2-9-16 1-18 1-8 9-12 15-8 8-3 15 3 13 9 8 3 6 15-2 17z" fill="#FFF"/><path d="M26 40V30M38 40V30" fill="none" stroke-width="2"/><rect x="17" y="38" width="30" height="13" rx="3" fill="#FBF3E2"/><path d="M17 44h30" fill="none" stroke="#7FB069" stroke-width="3"/></g>'),
    "it.dolomites": S(brim("#4F6B3C", 44, 28, 6) + '<path d="M16 42c-1-16 6-26 16-26s17 10 16 26c-10-3-22-3-32 0z" fill="#5F7F48"/><path d="M16 42c10-3 22-3 32 0v-6c-10-3-22-3-32 0z" fill="#C8473A"/><path d="M46 34c6-10 12-18 14-28-8 4-14 14-16 26z" fill="#F2F0E8" stroke-width="2"/>'),
    "it.amalfi": wide("#FFF3B0", "#FBE680", "#3BA6DC", '<ellipse cx="32" cy="26" rx="7" ry="5.5" fill="#F7D21E" stroke-width="2"/><path d="M38 22c3-3 6-3 8-1-2 3-5 4-8 1z" fill="#5F9E4F" stroke-width="1.6"/>'),
    "cn.great_wall": helmet("#6E7F90", '<path d="M32 16V6" stroke-width="3"/><path d="M26 8c2-6 10-6 12 0-4 2-8 2-12 0z" fill="#C8473A"/>', '<path d="M18 28h5v-4h6v4h6v-4h6v4h5" fill="none" stroke-width="2.2"/>'),
    "cn.forbidden_city": S(brim("#E7BE4F", 44, 28, 7) + '<path d="M14 42c0-14 8-22 18-22s18 8 18 22c-11-3-25-3-36 0z" fill="#C8473A"/><path d="M32 20c-1-5-1-8 0-13" fill="none" stroke-width="2.4"/><circle cx="32" cy="7" r="4.5" fill="#E7BE4F"/>'),
    "cn.zhangjiajie": cone("#7E9A8C", motif='<path d="M16 42c2-4 7-4 8-1 2-5 9-5 10 0 2-3 8-3 9 1 1 3-27 4-27 0z" fill="#FFFFFF" stroke-width="2"/>'),
    "cn.terracotta": S('<path d="M10 44c0-18 10-26 22-26s22 8 22 26c-14-5-30-5-44 0z" fill="#B77E55"/><path d="M26 18c-2-8 2-13 7-13s8 6 5 13z" fill="#A06A44"/><path d="M12 38c13-4 27-4 40 0M14 30c12-4 24-4 36 0" fill="none" stroke-width="2"/>'),
    "cn.li_river": cone("#D9BE86", motif='<path d="M22 38c5-5 13-5 18 0-5 5-13 5-18 0zM40 38l6-4v8z" fill="#5AA7C7" stroke-width="2"/>'),
    "es.sagrada": S('<path d="M16 50 22 14l4 12 6-22 6 22 4-12 6 36z" fill="#D9B98C"/><circle cx="22" cy="14" r="2.6" fill="#D9553A" stroke-width="1.6"/><circle cx="32" cy="5" r="2.6" fill="#3BA6DC" stroke-width="1.6"/><circle cx="42" cy="14" r="2.6" fill="#7FB069" stroke-width="1.6"/><path d="M20 38h24M21 30h22" fill="none" stroke-width="2"/>'),
    "es.alhambra": S('<path d="M14 50 18 12c6-3 22-3 28 0l4 38c-11-3-25-3-36 0z" fill="#B93A20"/><path d="M24 44V34c0-6 16-6 16 0v10z" fill="#F2DDB0" stroke-width="2.2"/><path d="M32 12c6-2 12 2 14 10" fill="none" stroke-width="2.4"/><circle cx="47" cy="25" r="3" fill="#E7BE4F" stroke-width="1.8"/>'),
    "es.park_guell": S('<path d="M5 36C5 21 20 12 36 13c15 1 24 11 23 21-1 7-9 8-14 6-9-3-24-3-33 1-5 2-7-1-7-5z" fill="#3BA6DC"/><path d="M14 22l8 6-6 8zM26 16l9 3-3 9zM40 18l9 6-8 6zM26 30l8-1 2 7z" fill="#F7D21E" stroke-width="1.6"/><path d="M30 20l-6 9M44 30l8-2" stroke="#D9553A" stroke-width="3"/>'),
    "es.camino": S(brim("#B99668", 44, 30, 7) + '<path d="M16 41c0-15 7-23 16-23s16 8 16 23c-10-3-22-3-32 0z" fill="#C9A77A"/><path d="M26 38c-2-7 2-12 6-12s8 5 6 12c-4 2-8 2-12 0z" fill="#FFF3DF" stroke-width="2"/><path d="M32 27v11M28 29l2 9M36 29l-2 9" fill="none" stroke-width="1.5"/>'),
    "es.teide": beanie("#4B4340", "#6E6058", '<path d="M18 20c5-6 23-6 28 0l-5 8-4-4-5 7-5-7-4 4z" fill="#E2502F" stroke-width="2.4"/>', "#E2502F"),
    "th.grand_palace": S('<path d="M12 50 24 26l8-24 8 24 12 24c-12-4-28-4-40 0z" fill="#E7BE4F"/><path d="M20 36c8-3 16-3 24 0M24 26c5-2 11-2 16 0" fill="none" stroke-width="2.4"/><circle cx="32" cy="42" r="3" fill="#D9553A" stroke-width="1.6"/>'),
    "th.phiphi": wide("#F7DD93", "#F0D07C", "#2BB5B2", '<path d="M32 30V20M32 20c-5-3-9-1-10 2M32 20c5-3 9-1 10 2M32 20c-3-4-6-4-8-3M32 20c3-4 6-4 8-3" fill="none" stroke="#3F8F4C" stroke-width="2.4"/>'),
    "th.ayutthaya": S('<path d="M8 50C6 24 18 10 32 10s26 14 24 40c-14-6-34-6-48 0z" fill="#E98A2B"/><path d="M32 22c-5 3-6 9-5 14h10c1-5 0-11-5-14zM22 36c0-4 2-7 5-8l1 8zM42 36c0-4-2-7-5-8l-1 8z" fill="#F7D21E" stroke-width="2"/>'),
    "th.doi_inthanon": S('<path d="M6 46c10-7 42-7 52 0" fill="none" stroke="#5F9E4F" stroke-width="6"/>' + "".join(f'<circle cx="{x}" cy="{y}" r="7" fill="{c}" stroke-width="2.2"/><circle cx="{x}" cy="{y}" r="2" fill="#F7D21E" stroke-width="1"/>' for x, y, c in [(12,38,"#F28FA9"),(24,31,"#F7F1E3"),(40,31,"#C2B4E9"),(52,38,"#F2B18D")])),
    "th.wat_arun": S('<path d="M16 50 26 28 32 2l6 26 10 22c-10-3-22-3-32 0z" fill="#F4EDE0"/><path d="M22 40c6-2 14-2 20 0M26 30c4-1 8-1 12 0" fill="none" stroke-width="2.2"/><circle cx="26" cy="36" r="2" fill="#3BA6DC" stroke-width="1"/><circle cx="38" cy="36" r="2" fill="#D9553A" stroke-width="1"/><circle cx="32" cy="24" r="2" fill="#7FB069" stroke-width="1"/>'),
    "au.opera": S('<path d="M8 28c0-10 48-10 48 0-2 7-46 7-48 0z" fill="#FFF"/><path d="M14 33h36l-2 16H16z" fill="#FFF"/><path d="M15 39c11-2 23-2 34 0l-1 10H16z" fill="#2F4C86"/><path d="M12 49c11-3 29-3 40 0l2 5c-12-3-32-3-44 0z" fill="#22375F"/><path d="M26 28c1-5 4-8 8-10-1 3-1 7 1 10zM34 28c1-4 4-7 8-8-1 3 0 6 1 8z" fill="#BFD9E8" stroke-width="1.8"/>'),
    "au.great_barrier": S('<path d="M48 40V10c0-4 8-4 8 0" fill="none" stroke="#F2B632" stroke-width="5"/><path d="M6 40c10-6 42-6 52 0v8c-10-5-42-5-52 0z" fill="#2BB5B2"/><rect x="14" y="24" width="36" height="20" rx="8" fill="#BFE9F5"/><path d="M32 24v20" fill="none" stroke-width="2.2"/>'),
    "au.uluru": S(brim("#A65A34", 42, 30, 7) + '<path d="M16 40c0-15 7-23 16-23s16 8 16 23c-10-3-22-3-32 0z" fill="#B86B3F"/><path d="M6 44v8M14 46v8M50 46v8M58 44v8" fill="none" stroke-width="2"/><circle cx="6" cy="53" r="2" fill="#E8C088" stroke-width="1.2"/><circle cx="14" cy="55" r="2" fill="#E8C088" stroke-width="1.2"/><circle cx="50" cy="55" r="2" fill="#E8C088" stroke-width="1.2"/><circle cx="58" cy="53" r="2" fill="#E8C088" stroke-width="1.2"/>'),
    "au.twelve_apostles": S('<path d="M12 40c0-16 9-26 20-26s20 10 20 26z" fill="#F2C21E"/><path d="M6 38c14-4 38-4 52 2l4 12c-16-9-40-10-56-6z" fill="#E0AE12"/><path d="M32 14v24" fill="none" stroke-width="2"/>'),
    "au.harbour_bridge": S('<path d="M10 42c0-18 10-28 22-28s22 10 22 28z" fill="#F2C21E"/><rect x="28" y="10" width="8" height="30" rx="3" fill="#E0AE12"/>' + brim("#E0AE12", 45, 28, 5) + '<path d="M14 36q18-20 36 0M22 36v-8M32 36V24M42 36v-8" fill="none" stroke="#3B2A1F" stroke-width="2"/>'),
}

# 남기는 모자 17개와 나라별로 고르게 나눈 스카프 17개·리본 18개. MapHomeGrowthPolicy의 후보와 같아야 한다.
HAT_IDS = ["kr.gyeongbokgung", "kr.namsan", "kr.hallasan", "jp.fuji", "jp.fushimi", "us.liberty", "us.grandcanyon",
           "gb.bigben", "gb.edinburgh", "fr.eiffel", "fr.versailles", "it.colosseum", "it.venice",
           "cn.forbidden_city", "es.sagrada", "th.grand_palace", "au.uluru"]

# 모자 위에 얹는 층: 그늘(짙은 반투명)과 빛(흰 반투명), 천 접힘 선.
SH = 'fill="#1E120A" fill-opacity=".2" stroke="none"'
HI = 'fill="none" stroke="#FFFFFF" stroke-opacity=".55" stroke-width="2.4"'
FO = 'fill="none" stroke="#1E120A" stroke-opacity=".28" stroke-width="1.6"'
HAT_LAYERS = {
    "kr.gyeongbokgung": f'<path d="M23 15c1-3 4-4 7-4" {HI}/><path d="M36 14v18c3 0 4-.4 5-1V15z" {SH}/><path d="M8 45c12 5 36 5 48 0" {FO}/>',
    "kr.namsan": f'<path d="M16 37c1-5 5-8 10-10" {HI}/><path d="M44 28c5 3 7 9 7 15-2-1-4-2-7-2z" {SH}/>',
    "kr.hallasan": f'<path d="M16 34c1-8 6-14 11-16" {HI}/><path d="M44 18c6 5 9 13 9 23h-9z" {SH}/>',
    "jp.fuji": f'<path d="M15 34c1-7 5-13 10-15" {HI}/><path d="M46 20c5 5 7 12 7 20h-8z" {SH}/>',
    "jp.fushimi": f'<path d="M12 36c6-5 14-6 20-6" {HI}/>',
    "us.liberty": f'<path d="M11 44c13 4 29 4 42 0v4c-13 4-29 4-42 0z" {SH}/>',
    "us.grandcanyon": f'<path d="M19 36c0-7 3-13 8-15" {HI}/><path d="M6 45c14 6 38 6 52 0" {FO}/>',
    "gb.bigben": f'<path d="M20 12v24" {HI}/><path d="M41 8h5v34l-5 1z" {SH}/><path d="M8 47c14 4 34 4 48 0" {FO}/>',
    "gb.edinburgh": f'<path d="M12 30c3-8 9-14 17-16" {HI}/><path d="M12 38c12-5 28-5 40 0" {FO}/>',
    "fr.eiffel": f'<path d="M9 34c3-9 11-15 21-16" {HI}/><path d="M16 38c12 4 26 3 38-3l-1 4c-12 5-26 6-37 3z" {SH}/>',
    "fr.versailles": f'<path d="M11 36l-1-14" {HI}/><path d="M9 45c15-5 31-5 46 0v5c-15-4-31-4-46 0z" {SH}/>',
    "it.colosseum": f'<path d="M13 34c1-6 6-11 13-12" {HI}/><path d="M44 21c6 3 10 9 10 15v14l-6-2v-8z" {SH}/>',
    "it.venice": f'<path d="M18 32c0-5 2-9 6-11" {HI}/><path d="M10 45c14 5 30 5 44 0" {FO}/>',
    "cn.forbidden_city": f'<path d="M20 34c1-6 4-10 8-12" {HI}/><path d="M10 46c14 4 30 4 44 0" {FO}/>',
    "es.sagrada": f'<path d="M23 44l3-16" {HI}/><path d="M36 30l4-10 5 26c-3 1-6 2-9 2z" {SH}/>',
    "th.grand_palace": f'<path d="M23 40l5-14" {HI}/><path d="M36 26l4 2 9 19-13 2z" {SH}/>',
    "au.uluru": f'<path d="M20 36c0-7 3-13 8-15" {HI}/><path d="M6 44c14 6 38 6 52 0" {FO}/>',
}

# 천 장식 표. (바탕, 그늘, 무늬, 테두리 장식, 무늬 종류, 랜드마크 표식)
SCARVES = {
    "kr.hahoe": ("#2F4C86", "#223A69", "#F2DDB0", "#C8473A", "bands", "mask"),
    "kr.seongsan": ("#6DAA6B", "#4E8A55", "#F2B632", "#3BA6DC", "waves", "sun"),
    "jp.itsukushima": ("#D9553A", "#B03E28", "#FFF3E0", "#2E6FB0", "scales", "torii"),
    "jp.arashiyama": ("#7FA650", "#5F8A3A", "#D3E59B", "#3F6B2F", "stripes", "leaf"),
    "us.golden_gate": ("#D9502E", "#B23B1F", "#F6E2C8", "#7A2A14", "bands", "bridge"),
    "us.yosemite": ("#4F7F5A", "#3A6347", "#EAD9A8", "#8FC6E2", "zigzag", "mountain"),
    "gb.tower_bridge": ("#2F5FA8", "#234A86", "#F3F5F7", "#C8473A", "stripes", "tower"),
    "gb.lake_district": ("#5B8FB0", "#44748F", "#DCEBF2", "#6B8F5A", "check", "wave"),
    "fr.louvre": ("#7FB7DA", "#5E97BC", "#FFFFFF", "#2F5F86", "diamonds", "pyramid"),
    "fr.alps": ("#C8473A", "#A23429", "#FFFFFF", "#2F4C86", "stripes", "mountain"),
    "it.amalfi": ("#F7D24A", "#DDB22C", "#3BA6DC", "#FFFFFF", "dots", "lemon"),
    "cn.great_wall": ("#6E7F90", "#55636F", "#D8DEE3", "#C8473A", "zigzag", "wall"),
    "cn.li_river": ("#4FA3A5", "#3A8486", "#E8F5F2", "#2F4C86", "waves", "fish"),
    "es.park_guell": ("#2BA6D9", "#1E86B3", "#F7C948", "#E8553A", "diamonds", "star"),
    "es.camino": ("#E7B23C", "#C79324", "#2F5FA8", "#FFF8E6", "scales", "shell"),
    "th.phiphi": ("#2BB5B2", "#1F918E", "#FFF3B0", "#F7DD93", "waves", "sun"),
    "au.great_barrier": ("#FF7F6B", "#DE5F4C", "#FFF1E6", "#2BB5B2", "dots", "star"),
}
RIBBONS = {
    "kr.bulguksa": ("#C9A66B", "#A8864E", "#7A5A32", "#FFF8E6", "stripes", "pagoda"),
    "kr.haeundae": ("#3BA6DC", "#2A86B8", "#FFFFFF", "#F7DD93", "waves", "wave"),
    "jp.himeji": ("#8FA3B8", "#6F8398", "#FFFFFF", "#2F4C86", "scales", "tower"),
    "us.mount_rushmore": ("#8C8F96", "#6E7178", "#EDEEF0", "#C8473A", "stripes", "star"),
    "gb.stonehenge": ("#7E8C7A", "#616E5E", "#DADFD5", "#4A5547", "check", "wall"),
    "fr.mont_saint_michel": ("#4A6FA5", "#38578A", "#C9D6E8", "#F7DD93", "bands", "tower"),
    "it.pisa": ("#D8B978", "#B89857", "#FFF8E6", "#7A5A32", "stripes", "tower"),
    "it.dolomites": ("#D96C8B", "#B84F6E", "#FFE3EA", "#4F6B3C", "zigzag", "mountain"),
    "cn.zhangjiajie": ("#5E8F7E", "#477263", "#D6E8DF", "#2F4C40", "zigzag", "mountain"),
    "cn.terracotta": ("#B5683F", "#934F2B", "#F0D3B5", "#5A3A24", "scales", "wall"),
    "es.alhambra": ("#B8402F", "#96301F", "#F7DD93", "#2F7F6F", "diamonds", "star"),
    "es.teide": ("#4B4340", "#352F2C", "#E8553A", "#C9BDB5", "dots", "mountain"),
    "th.ayutthaya": ("#E8922C", "#C67518", "#FFE9B8", "#7A3E12", "bands", "pagoda"),
    "th.doi_inthanon": ("#A77BD1", "#8860B3", "#FFFFFF", "#7FB069", "dots", "flower"),
    "th.wat_arun": ("#4FB8B0", "#3A9690", "#F7C948", "#E8553A", "diamonds", "pagoda"),
    "au.opera": ("#2C6FB5", "#215790", "#FFFFFF", "#F7C948", "scales", "sail"),
    "au.twelve_apostles": ("#E6A94D", "#C78A30", "#3BA6DC", "#FFF3D6", "waves", "wall"),
    "au.harbour_bridge": ("#8A97A3", "#6C7884", "#FFFFFF", "#2F5FA8", "zigzag", "bridge"),
}

# 12칸 안에 그리는 작은 랜드마크 표식. 흰 면에 짙은 선으로 어떤 천 위에서도 보인다.
MOTIFS = {
    "mask": '<circle cx="6" cy="6" r="5.4"/><path d="M3 5q1-1.5 2 0M7 5q1-1.5 2 0M3.6 8q2.4 2 4.8 0" fill="none" stroke-width=".9"/>',
    "sun": '<circle cx="6" cy="6" r="3.4"/><path d="M6 .6v1.2M6 10.2v1.2M.6 6h1.2M10.2 6h1.2M2.2 2.2l.9.9M8.9 8.9l.9.9M9.8 2.2l-.9.9M3.1 8.9l-.9.9" fill="none" stroke-width="1"/>',
    "torii": '<path d="M.6 2.4c3.6 1 7.2 1 10.8 0v1.8H.6zM2.6 4.2h6.8v1.6H2.6zM3 5.8h1.4v5.6H3zM7.6 5.8H9v5.6H7.6z"/>',
    "leaf": '<path d="M1.4 10.6C1 4.6 5 1.2 10.6 1.4 10.8 7 7.4 11 1.4 10.6z"/><path d="M1.4 10.6 7.4 4.6" fill="none" stroke-width=".9"/>',
    "bridge": '<path d="M2 1h1.6v10H2zM8.4 1H10v10H8.4zM.4 7.6h11.2V9H.4z"/><path d="M2.8 1.4C4 5 8 5 9.2 1.4" fill="none" stroke-width=".9"/>',
    "mountain": '<path d="M.5 10.8 4.6 2.6l1.8 2.8 1.2-1.6 3.9 7z"/>',
    "tower": '<path d="M4 11.2V3.4L6 .6l2 2.8v7.8z"/><path d="M4.4 6h3.2M4.4 8.6h3.2" fill="none" stroke-width=".8"/>',
    "wave": '<path d="M.6 8.4C2 3 6.4 1.6 9 3.4c-2 .2-3 1.4-2.4 2.8.6 1.2 2.6 1.2 4.8.2-.4 2.8-2 4.6-4.8 4.6H.6z"/>',
    "pyramid": '<path d="M6 1 11.4 11H.6z"/><path d="M6 1v10M3.4 6h5.2" fill="none" stroke-width=".8"/>',
    "lemon": '<ellipse cx="6" cy="6.6" rx="4.8" ry="4"/><path d="M6 2.6c.4-1.2 1.4-2 2.8-2-.2 1.4-1.2 2.2-2.8 2z"/>',
    "wall": '<path d="M.6 3.4h2.2V1.8h2v1.6h2.4V1.8h2v1.6h2.2v7.4H.6z"/><path d="M.8 6.8h10.4" fill="none" stroke-width=".8"/>',
    "fish": '<path d="M1 6c2-3 5.4-3 7.4 0l2.8-2.2v4.4L8.4 6C6.4 9 3 9 1 6z"/>',
    "star": '<path d="M6 .8 7.6 4.3l3.8.4-2.8 2.6.8 3.8L6 9.2l-3.4 1.9.8-3.8L.6 4.7l3.8-.4z"/>',
    "shell": '<path d="M6 11 1 5.4C2 2 4 1 6 1s4 1 5 4.4z"/><path d="M6 11V2M6 11 3.2 3M6 11l2.8-8" fill="none" stroke-width=".7"/>',
    "pagoda": '<path d="M6 .4 7 3h2L8 5h2l-1 2.4h1.6L9.4 11H2.6L1.4 7.4H3L2 5h2L3 3h2z"/>',
    "flower": '<circle cx="6" cy="2.8" r="2.2"/><circle cx="9" cy="5.4" r="2.2"/><circle cx="7.9" cy="9" r="2.2"/><circle cx="4.1" cy="9" r="2.2"/><circle cx="3" cy="5.4" r="2.2"/><circle cx="6" cy="6.4" r="1.6"/>',
    "sail": '<path d="M1 10.6C1 5 3.6 1.8 7 1c-1 3-1 6 0 9.6zM6.6 10.6c0-4 1.6-6.4 4.4-7-.6 2.4-.6 4.6 0 7z"/>',
}

def pattern(kind, accent, x0=-4, y0=-4, x1=68, y1=62):
    """주어진 범위를 무늬로 채운다. 천 모양으로 잘라 쓴다."""
    out = []
    if kind == "stripes":
        out = [f'<path d="M{x} {y0}l18 {y1-y0}" stroke="{accent}" stroke-width="3" fill="none"/>' for x in range(x0 - 30, x1, 9)]
    elif kind == "bands":
        out = [f'<path d="M{x0} {y}L{x1} {y-8}" stroke="{accent}" stroke-width="{2.6 if i % 2 else 1.3}" fill="none"/>' for i, y in enumerate(range(y0, y1 + 12, 5))]
    elif kind == "dots":
        for row, y in enumerate(range(y0, y1, 7)):
            out += [f'<circle cx="{x + (row % 2) * 4}" cy="{y}" r="1.7" fill="{accent}"/>' for x in range(x0, x1, 8)]
    elif kind == "waves":
        for y in range(y0, y1, 7):
            d = f"M{x0} {y}" + "".join(f"q2.5 -3 5 0t5 0" for _ in range((x1 - x0) // 10 + 1))
            out.append(f'<path d="{d}" stroke="{accent}" stroke-width="1.5" fill="none"/>')
    elif kind == "check":
        for x in range(x0, x1, 9):
            out.append(f'<path d="M{x} {y0}V{y1}" stroke="{accent}" stroke-width="2.2" stroke-opacity=".75" fill="none"/>')
        for y in range(y0, y1, 9):
            out.append(f'<path d="M{x0} {y}H{x1}" stroke="{accent}" stroke-width="2.2" stroke-opacity=".75" fill="none"/>')
    elif kind == "diamonds":
        for row, y in enumerate(range(y0, y1, 6)):
            for x in range(x0, x1, 10):
                cx = x + (row % 2) * 5
                out.append(f'<path d="M{cx} {y-2.4}l2.4 2.4-2.4 2.4-2.4-2.4z" fill="{accent}"/>')
    elif kind == "zigzag":
        for y in range(y0, y1, 8):
            d = f"M{x0} {y}" + "l4 -3.4 4 3.4" * ((x1 - x0) // 8 + 1)
            out.append(f'<path d="{d}" stroke="{accent}" stroke-width="1.7" fill="none"/>')
    elif kind == "scales":
        for row, y in enumerate(range(y0, y1, 5)):
            for x in range(x0, x1, 8):
                cx = x + (row % 2) * 4
                out.append(f'<path d="M{cx-4} {y}a4 4 0 0 1 8 0" stroke="{accent}" stroke-width="1.2" fill="none"/>')
    return "".join(out)

def cloth(uid, d, base, kind, accent, stroke=True):
    """바탕을 깔고 무늬를 잘라 얹은 뒤 윤곽을 그린다."""
    return (f'<clipPath id="{uid}"><path d="{d}"/></clipPath>'
            f'<path d="{d}" fill="{base}" stroke="none"/><g clip-path="url(#{uid})" stroke-width="0">{pattern(kind, accent)}</g>'
            + (f'<path d="{d}" fill="none"/>' if stroke else ""))

def motif(name, x, y, k=1.0):
    return (f'<g transform="translate({x} {y}) scale({k})" fill="#FFFDF6" stroke="{O}" stroke-width=".9" stroke-linejoin="round">{MOTIFS[name]}</g>')

def scarf(style):
    base, shade, accent, trim, kind, mark = style
    far = "M20 30 13 49 25 53 34 32z"
    tail = "M31 31 33 55 47 53 43 30z"
    wrap = "M8 13C9 35 55 35 56 13 51 20 13 20 8 13z"
    fringe = "".join(f'<path d="M{x} {y}l{dx} 4" fill="none" stroke-width="1.6"/>' for x, y, dx in [(14.5, 50, -.8), (19, 51.5, -.5), (23.5, 52.8, -.2), (35, 55, .2), (40, 54.4, .4), (45, 53.6, .6)])
    return S(
        # 뒤로 돌아가는 고리: 그늘색으로 어둡게 깐다.
        f'<path d="M8 13C9 3 55 3 56 13 51 20 13 20 8 13z" fill="{shade}"/>'
        f'<path d="M15 12c6-4 28-4 34 0-6 3.4-28 3.4-34 0z" fill="#1E120A" fill-opacity=".38" stroke="none"/>'
        + fringe
        + cloth("f", far, shade, kind, accent)
        + f'<path d="M23 33 19 46" fill="none" stroke="#1E120A" stroke-opacity=".25" stroke-width="1.4"/>'
        + cloth("t", tail, base, kind, accent)
        + f'<path d="M31.4 36c4 1 8 1 12-.2l-.4-5.8-12 1z" fill="#1E120A" fill-opacity=".24" stroke="none"/>'
        f'<path d="M14.5 48.7 25.6 52.4 26.8 49 15.7 45.4zM33 55 47 53l-.4-3.2-13.8 1.9z" fill="{trim}" stroke="none"/>'
        f'<path d="{far}" fill="none"/><path d="{tail}" fill="none"/>'
        + cloth("w", wrap, base, kind, accent)
        + f'<path d="M12 18c4 5 11 8 20 8.4M52 18c-3 4-7 6.4-11 7.6" fill="none" stroke="#FFFFFF" stroke-opacity=".45" stroke-width="1.8"/>'
        f'<path d="M15 23c6 4 12 5.4 17 5.6M49 23c-3 2.6-7 4.4-10 5" fill="none" stroke="#1E120A" stroke-opacity=".28" stroke-width="1.5"/>'
        f'<path d="M26 24c3-1.4 12-1.6 15 .4 1.8 3.4 1.2 7.4-.8 9.2-3.4 1.2-10 1.2-13-.2-2-2.6-2.4-6.4-1.2-9.4z" fill="{base}"/>'
        f'<path d="M28.6 26.4c2 2 2 4.6.6 6.6M38.8 26.4c-1.6 2-1.8 4.6-.6 6.6" fill="none" stroke="#1E120A" stroke-opacity=".35" stroke-width="1.4"/>'
        + motif(mark, 34.6, 38.5, .92))

def ribbon(style):
    base, shade, accent, trim, kind, mark = style
    left = "M29 22C21 9 5 6 3 16 1 27 16 34 29 29z"
    right = "M35 22C43 9 59 6 61 16 63 27 48 34 35 29z"
    tl = "M28 31 15 51 24 50 28 57 37 33z"
    tr = "M36 31 49 49 41 50 38 57 28 33z"
    return S(
        cloth("a", tr, shade, kind, accent) + cloth("b", tl, base, kind, accent)
        + f'<path d="M28 31l9 2-1.6 5.4-10.4-3z" fill="#1E120A" fill-opacity=".26" stroke="none"/>'
        f'<path d="M16.8 49 24 48.2 27 53.6 26 56 24 50 15 51zM40.8 47.6 49 49 41 50 38 57 37.6 54.4z" fill="{trim}" stroke="none"/>'
        + cloth("l", left, base, kind, accent) + cloth("r", right, base, kind, accent)
        # 고리 안쪽 그늘과 접힘.
        + f'<path d="M26 22C19 13 8 11 7 17.4 6.4 22 16 25 26 24.6z" fill="{shade}" fill-opacity=".92" stroke="none"/>'
        f'<path d="M38 22C45 13 56 11 57 17.4 57.6 22 48 25 38 24.6z" fill="{shade}" fill-opacity=".92" stroke="none"/>'
        f'<path d="M29 25.6C22 27 13 26 8 23M35 25.6C42 27 51 26 56 23" fill="none" stroke="#1E120A" stroke-opacity=".3" stroke-width="1.5"/>'
        f'<path d="M6 13c2-3 8-2.6 12 0M58 13c-2-3-8-2.6-12 0" fill="none" stroke="#FFFFFF" stroke-opacity=".55" stroke-width="1.8"/>'
        f'<path d="M{left[1:]}" fill="none"/><path d="{right}" fill="none"/>'
        f'<rect x="25" y="17.5" width="14" height="15.5" rx="4.4" fill="{trim}"/>'
        + motif(mark, 26.7, 19.8, .88))

VIEW = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="-2 -2 68 60" width="68" height="60">{}</svg>'

ASSET_GROUPS = [("Hats", "Hat_"), ("Scarves", "Scarf_"), ("Ribbons", "Ribbon_")]

def asset_name(prefix, landmark):
    return prefix + landmark.replace(".", "_")

def write_group(folder, prefix, bodies):
    root = os.path.join(CATALOG, folder)
    # 후보에서 빠진 그림은 지운다.
    if os.path.isdir(root):
        for name in os.listdir(root):
            if name.endswith(".imageset") and name[:-9] not in {asset_name(prefix, k) for k in bodies}:
                shutil.rmtree(os.path.join(root, name))
    os.makedirs(root, exist_ok=True)
    with open(os.path.join(root, "Contents.json"), "w") as f:
        json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)
    for landmark, body in bodies.items():
        d = os.path.join(root, asset_name(prefix, landmark) + ".imageset")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "art.svg"), "w") as f:
            f.write(VIEW.format(body))
        stale = os.path.join(d, "hat.svg")
        if os.path.exists(stale):
            os.remove(stale)
        with open(os.path.join(d, "Contents.json"), "w") as f:
            json.dump({"images": [{"filename": "art.svg", "idiom": "universal"}],
                       "info": {"author": "xcode", "version": 1},
                       "properties": {"preserves-vector-representation": True}}, f, indent=2)

def hex0x(color):
    return "0x" + color[1:].upper()

def write_styles():
    lines = ["// tools/generate_hwarang_hats.py가 만든다. 직접 고치지 않는다.", "",
             "extension HwarangClothStyle {", "    /// 스카프와 꼬리 리본의 색과 무늬. 키는 랜드마크 id다.",
             "    static let byLandmark: [String: HwarangClothStyle] = ["]
    for landmark, (base, shade, accent, trim, kind, _) in {**SCARVES, **RIBBONS}.items():
        lines.append(f'        "{landmark}": .init(base: {hex0x(base)}, shade: {hex0x(shade)}, accent: {hex0x(accent)}, trim: {hex0x(trim)}, pattern: .{kind}),')
    lines += ["    ]", "}", ""]
    with open(STYLES, "w") as f:
        f.write("\n".join(lines))

if __name__ == "__main__":
    assert len(HATS) == 52, len(HATS)
    assert len(HAT_IDS) == 17 and len(SCARVES) == 17 and len(RIBBONS) == 18
    assert set(HATS) == set(HAT_IDS) | set(SCARVES) | set(RIBBONS), "모든 랜드마크가 한 종류씩 가져야 한다"
    write_group("Hats", "Hat_", {k: HATS[k].replace("</g>", "", 0) + S(HAT_LAYERS[k]) for k in HAT_IDS})
    write_group("Scarves", "Scarf_", {k: scarf(v) for k, v in SCARVES.items()})
    write_group("Ribbons", "Ribbon_", {k: ribbon(v) for k, v in RIBBONS.items()})
    write_styles()
    print("hats", len(HAT_IDS), "scarves", len(SCARVES), "ribbons", len(RIBBONS))
