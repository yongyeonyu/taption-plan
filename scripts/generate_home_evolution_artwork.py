#!/usr/bin/env python3
"""Generate visible daily house changes for HomeEvolution008...366 SVG assets."""

from __future__ import annotations

import argparse
import hashlib
import re
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "TaptionPlan/Assets.xcassets"
START_LEVEL = 8  # Levels 1–7 are the hand-authored fire-to-house introduction.
MAX_LEVEL = 366

WALLS = ("#E8C98F", "#AFC7A8", "#DEA19A", "#A9C8D8", "#C4AED2", "#E4B96D", "#CD806A")
ROOFS = ("#A9573F", "#587763", "#476D82", "#785B84", "#9A713D", "#5F6185", "#884C46")
WINDOWS = ("#86BBC4", "#F2D38A", "#8DAED2", "#E8C27A", "#91C4B2", "#B7A3D8", "#E9D6AA")
WEEK_ACCENTS = ("#765B86", "#A9573F", "#517C68", "#557A98", "#B37445", "#6F7290", "#B85F67", "#597A7E")
STROKE = "#604A35"
INK = "#503E2E"
GROUND = "#9DB17B"


def tier_for_week(week: int) -> int:
    if week < 4:
        return week
    return min(7, 4 + (week - 4) // 12)


def svg_for_level(level: int) -> str:
    offset = level - START_LEVEL
    week = offset // 7
    day = offset % 7
    tier = tier_for_week(week)
    weekly_style = week % 7
    week_accent = WEEK_ACCENTS[week // 7]
    wall = WALLS[day]
    roof = ROOFS[day]
    window = WINDOWS[day]

    stories = 1 + tier
    body_height = 22 + 5 * tier
    body_bottom = 76
    body_top = body_bottom - body_height
    body_width = min(60, 38 + 3 * tier)
    left = (96 - body_width) / 2
    right = left + body_width
    roof_top = max(5, body_top - 13)
    roof_style = tier % 3

    parts = [
        '<svg xmlns="http://www.w3.org/2000/svg" width="96" height="96" viewBox="0 0 96 96">',
        '<g stroke-linecap="round" stroke-linejoin="round">',
        f'<ellipse cx="48" cy="81" rx="40" ry="6" fill="{GROUND}"/>',
    ]

    # The first month adds a floor each week; later floors arrive every twelve weeks.
    parts.append(
        f'<rect x="{left:.1f}" y="{body_top:.1f}" width="{body_width:.1f}" '
        f'height="{body_height:.1f}" rx="2" fill="{wall}" stroke="{STROKE}" stroke-width="2"/>'
    )

    if roof_style == 0:
        parts.append(
            f'<path d="M{left - 5:.1f} {body_top + 1:.1f} L48 {roof_top:.1f} '
            f'L{right + 5:.1f} {body_top + 1:.1f} Z" fill="{roof}" '
            f'stroke="{STROKE}" stroke-width="2.4"/>'
        )
    elif roof_style == 1:
        parts.append(
            f'<path d="M{left - 5:.1f} {body_top + 4:.1f} L48 {roof_top:.1f} '
            f'L{right + 5:.1f} {body_top + 4:.1f} L{right - 2:.1f} {body_top + 8:.1f} '
            f'L48 {roof_top + 5:.1f} L{left + 2:.1f} {body_top + 8:.1f} Z" '
            f'fill="{roof}" stroke="{STROKE}" stroke-width="2.1"/>'
        )
    else:
        parts.append(
            f'<path d="M{left - 7:.1f} {body_top + 4:.1f} L48 {roof_top:.1f} '
            f'L{right + 7:.1f} {body_top + 4:.1f} L{right + 3:.1f} {body_top + 8:.1f} '
            f'L48 {roof_top + 5:.1f} L{left - 3:.1f} {body_top + 8:.1f} Z" '
            f'fill="{roof}" stroke="{STROKE}" stroke-width="2.2"/>'
        )

    # A large, high-contrast daily accent changes with every completed day.
    if day == 0:
        parts.append(
            f'<path d="M{right - 8:.1f} {roof_top + 8:.1f}v-10h6v10" '
            f'fill="#C9825B" stroke="{STROKE}" stroke-width="1.7"/>'
            f'<path d="M{right:.1f} {roof_top - 3:.1f}c-4-4 4-5 0-9" fill="none" '
            'stroke="#9B9A8B" stroke-width="2"/>'
        )
    elif day == 1:
        parts.append(
            f'<path d="M{left - 8:.1f} 73V62m-5 11 5-9 5 9Z" '
            'fill="#62845D" stroke="#4E6948" stroke-width="1.5"/>'
        )
    elif day == 2:
        parts.append(
            f'<path d="M{left - 7:.1f} {body_bottom - 12}h13v12h-13Z" '
            f'fill="#E7C78F" stroke="{STROKE}" stroke-width="1.7"/>'
            f'<path d="M{left - 9:.1f} {body_bottom - 12}l8-6 8 6Z" '
            f'fill="{roof}" stroke="{STROKE}" stroke-width="1.7"/>'
        )
    elif day == 3:
        parts.append(
            '<path d="M9 78q9-8 18 0v4H9Z" fill="#7F9B61" stroke="#536C43" stroke-width="1.6"/>'
            '<circle cx="13" cy="76" r="3" fill="#EAA5A0"/><circle cx="21" cy="75" r="3" fill="#F2CF74"/>'
        )
    elif day == 4:
        parts.append(
            '<path d="M76 77h11m-8-1v-8h7v8" fill="#C88A52" stroke="#70563C" stroke-width="1.7"/>'
            '<path d="M46 78q2 5 0 8" fill="none" stroke="#D1B981" stroke-width="4"/>'
        )
    elif day == 5:
        parts.append(
            f'<path d="M{left + 3:.1f} {body_top + 4:.1f}l12 0-2 7-12 0Z" '
            'fill="#5B7890" stroke="#425B6F" stroke-width="1.6"/>'
            '<path d="M79 15v8m-4-4h8" stroke="#D4A84F" stroke-width="2.2"/>'
        )
    else:
        parts.append(
            '<path d="M79 74V62m-5 12 5-10 5 10Z" fill="#B65F52" stroke="#74453A" stroke-width="1.6"/>'
            '<circle cx="15" cy="77" r="5" fill="#78945F"/><circle cx="23" cy="78" r="4" fill="#91AA72"/>'
        )

    # Floor windows make the long-term weekly rise easy to read at map scale.
    floor_height = body_height / stories
    window_width = 5.2 if stories < 5 else 4.6
    window_height = min(5.3, max(3.7, floor_height * 0.58))
    for floor in range(stories):
        center_y = body_top + floor_height * (floor + 0.52)
        for side_x in (left + body_width * 0.25, left + body_width * 0.70):
            parts.append(
                f'<rect x="{side_x - window_width / 2:.1f}" y="{center_y - window_height / 2:.1f}" '
                f'width="{window_width:.1f}" height="{window_height:.1f}" rx="1" '
                f'fill="{window}" stroke="{STROKE}" stroke-width="1.1"/>'
            )

    door_height = min(13, max(8, floor_height * 1.4))
    parts.append(
        f'<path d="M44 {body_bottom}v-{door_height:.1f}a4 4 0 0 1 8 0v{door_height:.1f}Z" '
        f'fill="{week_accent}" stroke="{STROKE}" stroke-width="1.4"/>'
    )

    # Weekly variants add a porch, bay window, dormer, balcony, or roof detail.
    if weekly_style == 1:
        parts.append(
            f'<path d="M{left:.1f} {body_bottom - 10}h-9v10h9" fill="#E2BC82" '
            f'stroke="{STROKE}" stroke-width="1.6"/><path d="M{left - 11:.1f} {body_bottom - 10}l7-5 7 5Z" '
            f'fill="{roof}" stroke="{STROKE}" stroke-width="1.4"/>'
        )
    elif weekly_style == 2:
        parts.append(
            f'<path d="M{right - 8:.1f} {body_top + 4:.1f}q8-7 12 0v10h-12Z" '
            'fill="#F0D39C" stroke="#604A35" stroke-width="1.5"/>'
        )
    elif weekly_style == 3:
        parts.append(
            f'<path d="M43 {roof_top + 9:.1f}q5-8 10 0v7h-10Z" fill="{wall}" '
            f'stroke="{STROKE}" stroke-width="1.5"/>'
        )
    elif weekly_style == 4:
        parts.append(
            f'<path d="M{left + 3:.1f} {body_bottom - 13}h{body_width - 6:.1f}v3h-{body_width - 6:.1f}Z" '
            f'fill="{ROOFS[(day + 4) % 7]}" stroke="{STROKE}" stroke-width="1.3"/>'
            f'<path d="M{left + 5:.1f} {body_bottom - 10}v9m{body_width - 16:.1f} -9v9" '
            f'stroke="{STROKE}" stroke-width="1.5"/>'
        )
    elif weekly_style == 5:
        parts.append(
            f'<path d="M{right - 1:.1f} {body_top + 12:.1f}h8v5h-8m1 0v5m5-5v5" '
            f'fill="#D9BA82" stroke="{STROKE}" stroke-width="1.4"/>'
        )
    elif weekly_style == 6:
        parts.append(
            f'<path d="M{left + 4:.1f} {roof_top + 7:.1f}h10v5h-10Z" fill="#EBD9B1" '
            f'stroke="{STROKE}" stroke-width="1.4"/>'
        )

    parts.append(
        f'<text x="48" y="94" text-anchor="middle" font-family="sans-serif" '
        f'font-size="7" font-weight="700" fill="{INK}">Lv.{level}</text>'
    )
    if level == MAX_LEVEL:
        parts.append(
            '<path d="M80 6l2.2 5.1 5.5.4-4.2 3.4 1.5 5.3-5-2.9-4.9 2.9 1.5-5.3-4.2-3.4 5.4-.4z" '
            'fill="#E3B54A" stroke="#765D3E" stroke-width="1.2"/>'
        )
    parts.append('</g></svg>')
    return ''.join(parts)


def body_signature(source: str) -> str:
    normalized = re.sub(r'Lv\.\d+', 'Lv.N', source)
    return hashlib.sha256(normalized.encode()).hexdigest()


def validate() -> None:
    signatures: list[str] = []
    for level in range(1, MAX_LEVEL + 1):
        name = f"HomeEvolution{level:03}"
        path = ASSETS / f"{name}.imageset/{name}.svg"
        if not path.is_file():
            raise SystemExit(f"Missing asset: {path}")
        source = path.read_text()
        ET.fromstring(source)
        signatures.append(body_signature(source))
        if level >= START_LEVEL and source != svg_for_level(level):
            raise SystemExit(f"Generated art is stale: {path}")
    same_pairs = [level for level in range(1, MAX_LEVEL) if signatures[level - 1] == signatures[level]]
    if same_pairs:
        raise SystemExit(f"Adjacent levels look identical after removing the level label: {same_pairs}")
    if len(set(signatures)) != MAX_LEVEL:
        raise SystemExit(
            f"Only {len(set(signatures))} distinct SVG bodies remain after removing level labels."
        )
    print(
        f"Validated {MAX_LEVEL} SVGs; all level bodies are unique and all "
        f"{MAX_LEVEL - 1} adjacent pairs have distinct artwork."
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help="Regenerate HomeEvolution008...366 SVGs")
    parser.add_argument("--check", action="store_true", help="Validate the packaged evolution artwork")
    args = parser.parse_args()
    if args.write:
        for level in range(START_LEVEL, MAX_LEVEL + 1):
            name = f"HomeEvolution{level:03}"
            (ASSETS / f"{name}.imageset/{name}.svg").write_text(svg_for_level(level))
    if args.check or args.write:
        validate()
    if not args.write and not args.check:
        parser.print_help()


if __name__ == "__main__":
    main()
