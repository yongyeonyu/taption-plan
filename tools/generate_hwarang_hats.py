#!/usr/bin/env python3
"""화랑이 모자 52개(랜드마크별)를 SVG 이미지 세트로 만든다(ACC1101A01)."""
import json, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, "TaptionPlan/Assets.xcassets/Hats")
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
    "kr.namsan": cap("#C8473A", "#8E2F27", '<path d="M26 34V22l6 8 6-8v12" fill="none" stroke="#FFFFFF" stroke-width="3"/>', '<path d="M32 14V3M28 7h8" fill="none" stroke-width="2.6"/>'),
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
VIEW = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="-2 -2 68 60" width="68" height="60">{}</svg>'

def asset_name(landmark):
    return "Hat_" + landmark.replace(".", "_")

def write_assets():
    os.makedirs(ASSETS, exist_ok=True)
    with open(os.path.join(ASSETS, "Contents.json"), "w") as f:
        json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)
    for landmark, body in HATS.items():
        d = os.path.join(ASSETS, asset_name(landmark) + ".imageset")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "hat.svg"), "w") as f:
            f.write(VIEW.format(body))
        with open(os.path.join(d, "Contents.json"), "w") as f:
            json.dump({"images": [{"filename": "hat.svg", "idiom": "universal"}],
                       "info": {"author": "xcode", "version": 1},
                       "properties": {"preserves-vector-representation": True}}, f, indent=2)

if __name__ == "__main__":
    assert len(HATS) == 52, len(HATS)
    write_assets()
    print("hats", len(HATS))
