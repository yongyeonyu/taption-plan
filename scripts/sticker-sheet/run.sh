#!/bin/bash
# 스티커 시트 그리기: bash scripts/sticker-sheet/run.sh <출력 폴더> [분류 id…]
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
bin="$(mktemp -d)/sticker-sheet"
swiftc -O "$root"/scripts/sticker-sheet/main.swift "$root"/TaptionPlan/UI/StickerArt*.swift "$root"/TaptionPlan/UI/StickerCatalog.swift -o "$bin"
"$bin" "$@"
