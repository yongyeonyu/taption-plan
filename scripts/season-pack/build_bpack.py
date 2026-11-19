#!/usr/bin/env python3
"""시즌 팩 폴더 하나를 `.bpack` 파일 하나로 묶고 카탈로그(`index.json`) 항목을 만든다 (SEA1119A01).

    python3 scripts/season-pack/build_bpack.py <팩 폴더> [--out build/season-pack] [--index index.json]

팩 폴더에는 `manifest.json`과 매니페스트 `assets`가 가리키는 파일이 있다
(예: Packages/SeasonPackKit/Sources/SeasonPackKit/Resources/seed/christmas/1).

파일 형식(`SeasonPackArchive.swift`와 같다, 압축 없음):
    "BSPK" | u8 형식 버전(1) | u32 빅엔디언 매니페스트 길이 | 매니페스트 JSON | `assets` 순서대로 파일 바이트(각 `bytes`)

이 스크립트는 파일을 만들고 목록을 갱신할 뿐 서버에 올리지 않는다. 올리는 명령은 끝에 출력만 한다(대표가 직접 실행).
공개 저장소이므로 버킷 이름·계정·주소는 코드에 적지 않고 자리표시자(<버킷>)로 출력한다.
"""
import argparse
import hashlib
import json
import re
import struct
import sys
from datetime import datetime, timezone
from pathlib import Path

PACK_BYTES = 8 * 1024 * 1024
IMAGE_BYTES = 400 * 1024
AUDIO_BYTES = 2 * 1024 * 1024
FILES_PER_PACK = 40
MAX_MANIFEST = 256 * 1024
KEY_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


def fail(message):
    print(f"오류: {message}", file=sys.stderr)
    sys.exit(1)


def relative_ok(path):
    return bool(path) and not path.startswith("/") and ".." not in path.split("/") and all(KEY_NAME.match(p) for p in path.split("/"))


def build(pack_dir: Path):
    manifest_path = pack_dir / "manifest.json"
    if not manifest_path.is_file():
        fail(f"{manifest_path}이(가) 없습니다")
    manifest_bytes = manifest_path.read_bytes()
    if len(manifest_bytes) > MAX_MANIFEST:
        fail("매니페스트가 256KB를 넘습니다")
    manifest = json.loads(manifest_bytes)
    for key in ("format", "schema", "id", "version", "event", "assets"):
        if key not in manifest:
            fail(f"매니페스트에 `{key}`가 없습니다")
    if not KEY_NAME.match(manifest["id"]) or manifest["id"] == "memos" or manifest["version"] < 1:
        fail("id/version이 올바르지 않습니다")
    assets = manifest["assets"]
    if len(assets) > FILES_PER_PACK:
        fail(f"자산이 {FILES_PER_PACK}개를 넘습니다")
    body, total, seen = bytearray(), 0, set()
    for asset in assets:
        path = asset["path"]
        if not relative_ok(path) or path in seen:
            fail(f"경로가 올바르지 않거나 중복입니다: {path}")
        seen.add(path)
        data = (pack_dir / path).read_bytes()
        if len(data) != asset["bytes"]:
            fail(f"{path}: 크기가 매니페스트와 다릅니다({len(data)} ≠ {asset['bytes']})")
        if hashlib.sha256(data).hexdigest() != asset["sha256"].lower():
            fail(f"{path}: SHA-256이 매니페스트와 다릅니다")
        limit = AUDIO_BYTES if asset["kind"] == "audio" else IMAGE_BYTES
        if asset["kind"] in ("image", "audio") and len(data) > limit:
            fail(f"{path}: {asset['kind']} 한도({limit}바이트)를 넘습니다")
        total += len(data)
        body += data
    if total > PACK_BYTES:
        fail("팩 전체가 8MB를 넘습니다")
    blob = b"BSPK" + bytes([1]) + struct.pack(">I", len(manifest_bytes)) + manifest_bytes + bytes(body)
    return manifest, blob


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("pack_dir", type=Path)
    parser.add_argument("--out", type=Path, default=Path("build/season-pack"))
    parser.add_argument("--index", type=Path, help="갱신할 카탈로그 index.json(없으면 새로 만든다)")
    args = parser.parse_args()

    manifest, blob = build(args.pack_dir)
    pack_id, version = manifest["id"], manifest["version"]
    key = f"packs/season/{pack_id}/{version}/{pack_id}-{version}.bpack"
    args.out.mkdir(parents=True, exist_ok=True)
    out_file = args.out / f"{pack_id}-{version}.bpack"
    out_file.write_bytes(blob)
    entry = {
        "id": pack_id, "version": version,
        "archive": {"key": key, "bytes": len(blob), "sha256": hashlib.sha256(blob).hexdigest()},
        "windows": manifest["event"].get("windows", []),
        "updatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    if manifest.get("requiresAppBuild") is not None:
        entry["requiresAppBuild"] = manifest["requiresAppBuild"]

    index_path = args.index or args.out / "index.json"
    index = {"format": "bokki-season-packs", "schema": 1, "packs": []}
    if index_path.is_file():
        index = json.loads(index_path.read_text())
    index["packs"] = [e for e in index["packs"] if e.get("id") != pack_id] + [entry]
    index["packs"].sort(key=lambda e: e["id"])
    index_path.write_text(json.dumps(index, ensure_ascii=False, indent=2) + "\n")

    print(f"만들었습니다: {out_file} ({len(blob):,}바이트)")
    print(f"카탈로그 갱신: {index_path}")
    print(json.dumps(entry, ensure_ascii=False, indent=2))
    print("\n[대표가 직접 실행] 올리는 순서 — 파일을 먼저, 카탈로그를 나중에(앱이 없는 파일을 가리키지 않게):")
    print(f"  npx wrangler r2 object put <버킷>/{key} --file {out_file} --content-type application/octet-stream "
          f"--cache-control \"public, max-age=31536000, immutable\"")
    print(f"  npx wrangler r2 object put <버킷>/packs/season/index.json --file {index_path} --content-type application/json "
          f"--cache-control \"public, max-age=300\"")


if __name__ == "__main__":
    main()
