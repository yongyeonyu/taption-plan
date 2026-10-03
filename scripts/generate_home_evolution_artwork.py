#!/usr/bin/env python3
"""Install/check the approved 366 home illustrations: 122 subjects, three levels each."""

from __future__ import annotations

import argparse
import hashlib
import json
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "TaptionPlan/Assets.xcassets"
MANIFEST = ROOT / "scripts/home_evolution_artwork_manifest.json"


def approved_entries() -> tuple[dict, list[dict]]:
    manifest = json.loads(MANIFEST.read_text())
    entries = manifest["entries"]
    assert manifest["assetCount"] == len(entries) == 366
    assert manifest["stageCount"] == 122
    assert [e["level"] for e in entries] == list(range(1, 367))
    assert len({e["sha256"] for e in entries}) == 366
    for e in entries:
        assert e["stage"] == (e["level"] - 1) // 3 + 1
        assert e["detail"] == (e["level"] - 1) % 3 + 1
        assert e["assetName"] == f'HomeEvolution{e["level"]:03d}'
    return manifest, entries


def check_svg(data: bytes, entry: dict) -> None:
    svg = ET.fromstring(data)
    assert svg.attrib["width"] == svg.attrib["height"] == "128"
    assert svg.attrib["viewBox"] == "0 0 128 128"
    if hashlib.sha256(data).hexdigest() != entry["sha256"]:
        raise SystemExit(f'Artwork differs from approved level {entry["level"]}: {entry["assetName"]}')


def asset_path(entry: dict) -> Path:
    name = entry["assetName"]
    return ASSETS / f"{name}.imageset/{name}.svg"


def install(manifest: dict, entries: list[dict], source: Path | None) -> None:
    source = source or ROOT / manifest["sourceDirectory"]
    data_by_level = []
    for entry in entries:
        data = (source / entry["sourceSVG"]).read_bytes()
        assert hashlib.sha256(data).hexdigest() == entry["sourceSHA256"]
        original_size = b'width="512" height="512" viewBox="0 0 128 128"'
        assert data.count(original_size) == 1
        data = data.replace(original_size, b'width="128" height="128" viewBox="0 0 128 128"', 1)
        check_svg(data, entry)
        if not asset_path(entry).is_file():
            raise SystemExit(f"Missing destination: {asset_path(entry)}")
        data_by_level.append(data)
    for entry, data in zip(entries, data_by_level):
        destination = asset_path(entry)
        if destination.read_bytes() != data:
            destination.write_bytes(data)


def validate(entries: list[dict]) -> None:
    for entry in entries:
        destination = asset_path(entry)
        check_svg(destination.read_bytes(), entry)
        contents = json.loads(destination.with_name("Contents.json").read_text())
        assert any(image.get("filename") == destination.name for image in contents["images"])
        assert contents.get("properties", {}).get("preserves-vector-representation") is True
    actual = {p.name for p in ASSETS.glob("HomeEvolution*.imageset")}
    assert actual == {f'{e["assetName"]}.imageset' for e in entries}
    print("Validated 366 approved SVG assets: 122 subjects, exactly three levels each; all bodies unique.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help="Install the approved 366 SVGs into existing asset sets")
    parser.add_argument("--check", action="store_true", help="Check artwork against the approved SHA-256 manifest")
    parser.add_argument("--source", type=Path, help="Directory containing the approved daily SVG files")
    args = parser.parse_args()
    if not args.write and not args.check:
        parser.print_help()
        return
    manifest, entries = approved_entries()
    if args.write:
        install(manifest, entries, args.source)
    validate(entries)


if __name__ == "__main__":
    main()
