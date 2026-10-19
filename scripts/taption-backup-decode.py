#!/usr/bin/env python3
"""Taption Plan 백업(.taptionbackup, .rawsensorbackup)을 비밀번호만으로 풀어 JSON Lines로 낸다.

사용:
  python3 scripts/taption-backup-decode.py <백업 파일> --out build/backup-decode
  python3 scripts/taption-backup-decode.py <백업 파일> --summary

비밀번호는 --password 또는 환경변수 TAPTION_BACKUP_PASSWORD, 없으면 입력창으로 받는다.
새 형식 백업(파일 안에 passwordKDFSalt가 있는 것)만 열린다. 이전 백업은 솔트가 기기에만 있어 열 수 없다.
이 도구는 인증 태그를 확인하지 않고 복호화한다(분석용). 위변조 검증이 필요하면 앱의 복원을 쓴다.
"""
import argparse
import base64
import collections
import ctypes
import getpass
import hashlib
import json
import os
import struct
import sys

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

SECTIONS = [
    "header", "plans", "actuals", "recordLinks", "memos", "stickers", "categories", "photos",
    "calendarEvents", "weather", "places", "travel", "floorTransitions", "yearlyReports", "routePoints",
]
FRAME_MAGICS = {b"TPS4": "snapshot", b"TPP4": "raw-sensor"}
COMPRESSION_MAGIC = b"TPZ1"
COMPRESSION_LZFSE = 0x801


def lzfse_decode(data: bytes, expected: int) -> bytes:
    lib = ctypes.CDLL("/usr/lib/libcompression.dylib")
    lib.compression_decode_buffer.restype = ctypes.c_size_t
    lib.compression_decode_buffer.argtypes = [
        ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_int,
    ]
    out = ctypes.create_string_buffer(expected)
    written = lib.compression_decode_buffer(out, expected, data, len(data), None, COMPRESSION_LZFSE)
    if written != expected:
        raise ValueError(f"LZFSE 해제 크기가 다릅니다: {written} != {expected}")
    return out.raw


def decompress(blob: bytes) -> bytes:
    if blob[:4] != COMPRESSION_MAGIC:
        return blob
    (size,) = struct.unpack("<Q", blob[4:12])
    return lzfse_decode(blob[12:], size)


def gcm_decrypt_without_tag_check(key: bytes, combined: bytes) -> bytes:
    nonce, body = combined[:12], combined[12:-16]
    counter = nonce + b"\x00\x00\x00\x02"  # GCM의 첫 데이터 블록 카운터
    decryptor = Cipher(algorithms.AES(key), modes.CTR(counter)).decryptor()
    return decryptor.update(body) + decryptor.finalize()


def read_frame(data: bytes):
    magic = data[:4]
    if magic not in FRAME_MAGICS:
        raise ValueError(f"알 수 없는 프레임 머리표: {magic!r}")
    (count,) = struct.unpack("<I", data[4:8])
    offset, pages = 8, []
    for _ in range(count):
        (length,) = struct.unpack("<I", data[offset:offset + 4])
        offset += 4
        pages.append(data[offset:offset + length])
        offset += length
    if offset != len(data):
        raise ValueError("프레임 끝이 맞지 않습니다")
    return FRAME_MAGICS[magic], pages


def derive_key(password: str, archive: dict) -> bytes:
    salt = archive.get("passwordKDFSalt")
    if not salt:
        raise SystemExit("이 백업에는 passwordKDFSalt가 없습니다. 비밀번호만으로 열 수 없는 이전 형식입니다.")
    iterations = int(archive.get("passwordKDFIterations") or 600_000)
    return hashlib.pbkdf2_hmac("sha256", password.encode(), base64.b64decode(salt), iterations, 32)


def decode_archive(path: str, password: str):
    with open(path, "rb") as handle:
        archive = json.load(handle)
    pin_key = derive_key(password, archive)
    wrapped = base64.b64decode(archive["wrappedPayloadKey"])
    try:
        archive_key = AESGCM(pin_key).decrypt(wrapped[:12], wrapped[12:], None)
    except Exception as error:  # noqa: BLE001
        raise SystemExit(f"비밀번호가 맞지 않거나 파일이 손상됐습니다: {error}")
    kind, pages = read_frame(base64.b64decode(archive["encryptedPayload"]))
    meta = {k: archive.get(k) for k in ("version", "monthKey", "createdAt", "generationID", "hasRawSensorArchive")}
    meta["kind"] = kind
    meta["page_count"] = len(pages)
    for index, page in enumerate(pages):
        plain = decompress(gcm_decrypt_without_tag_check(archive_key, page))
        yield meta, index, plain


def page_records(kind: str, plain: bytes):
    if kind == "snapshot":
        section = SECTIONS[plain[0]] if plain[0] < len(SECTIONS) else f"section-{plain[0]}"
        (ordinal,) = struct.unpack("<I", plain[1:5])
        try:
            rows = json.loads(plain[5:])
        except ValueError:
            rows = {"undecodable_bytes": len(plain) - 5}
        yield {"section": section, "ordinal": ordinal, "rows": rows}
    else:
        try:
            yield {"raw": json.loads(plain)}
        except ValueError:
            yield {"raw_undecodable_bytes": len(plain)}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("file")
    parser.add_argument("--password", default=os.environ.get("TAPTION_BACKUP_PASSWORD"))
    parser.add_argument("--out", help="JSON Lines를 쓸 폴더(없으면 요약만 출력)")
    parser.add_argument("--summary", action="store_true", help="쪽·행 개수 요약만 출력")
    args = parser.parse_args()
    password = args.password or getpass.getpass("비밀번호: ")

    counts = collections.Counter()
    out_file = None
    if args.out and not args.summary:
        os.makedirs(args.out, exist_ok=True)
        out_file = open(os.path.join(args.out, os.path.basename(args.file) + ".jsonl"), "w", encoding="utf-8")
    meta = {}
    for meta, index, plain in decode_archive(args.file, password):
        for record in page_records(meta["kind"], plain):
            if "section" in record:
                rows = record["rows"]
                counts[record["section"]] += len(rows) if isinstance(rows, list) else 1
            else:
                counts["raw_items"] += 1
            if out_file:
                out_file.write(json.dumps(record, ensure_ascii=False) + "\n")
    if out_file:
        out_file.close()
    print(json.dumps({"meta": meta, "counts": dict(counts)}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    sys.exit(main())
