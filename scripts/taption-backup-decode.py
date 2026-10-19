#!/usr/bin/env python3
"""Taption Plan 월 백업(yyyy-MM.taptionbackup, 형식 버전 1)을 비밀번호만으로 풀어 JSON Lines로 낸다.

사용:
  python3 scripts/taption-backup-decode.py <백업 파일> --header            # 비밀번호 없이 평문 헤더만(비밀번호를 주면 암호화된 헤더도)
  python3 scripts/taption-backup-decode.py <백업 파일> --summary           # 복호화해 표별 행 수·검증 결과
  python3 scripts/taption-backup-decode.py <백업 파일> --out build/backup-decode   # 줄을 <이름>.jsonl로 저장
  python3 scripts/taption-backup-decode.py <백업 파일> > rows.jsonl        # 표준 출력으로 줄 내보내기

비밀번호는 --password 또는 환경변수 TAPTION_BACKUP_PASSWORD, 없으면 입력창으로 받는다(--header는 입력창을 열지 않는다).
월 파일은 시작 시각이 그 달인 행을, taption-settings.taptionbackup은 시작 시각이 없는 기록을 담는다. 기록 행의 deleted=1은 삭제 표시다.
헤더 영역의 평문에는 형식·버전·KDF(솔트·반복 횟수)와 봉인된 헤더 블록만 있고, 행 수·시각·해시 등은 같은 키로 AES-GCM 봉인돼 있다.
월은 파일 이름에서 얻는다(AAD에 묶임).
키 = PBKDF2-HMAC-SHA256(비밀번호, 헤더의 솔트, 헤더의 반복 횟수 100000~5000000, 32바이트).
전체 검증(모든 프레임의 AES-GCM 태그, 프레임 크기 상한, 본문 SHA-256, 트레일러의 행 수·시각·내용 해시)이 끝난 뒤에만
출력한다. 하나라도 틀리면 아무것도 내지 않고 종료 코드 1로 끝난다.
압축은 macOS의 libcompression(LZFSE/zlib)을 ctypes로 쓴다. macOS에서만 동작한다.
"""
import argparse
import base64
import collections
import ctypes
import getpass
import hashlib
import json
import os
import re
import shutil
import struct
import sys
import tempfile

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

MAGIC = b"TAPTBK02"
HEADER_REGION = 2048
BODY_OFFSET = len(MAGIC) + 4 + HEADER_REGION
COMPRESSION_ALGORITHMS = {1: 0x801, 2: 0x205}  # 1=LZFSE, 2=zlib. 0=압축 안 함
MIN_ITERATIONS = 100_000
MAX_ITERATIONS = 5_000_000
MAX_FRAME_BYTES = 256 << 20
MAX_CHUNK_BYTES = 64 << 20
AEAD_OVERHEAD = 28
SETTINGS_NAME = "taption-settings.taptionbackup"


def fail(message: str) -> None:
    print(f"오류: {message}", file=sys.stderr)
    raise SystemExit(1)


def max_plain_frame(chunk_bytes: int) -> int:
    return min(MAX_FRAME_BYTES, max(chunk_bytes * 4, 64 << 10))


def decompress(codec: int, data: bytes, size: int) -> bytes:
    if codec == 0:
        if len(data) != size:
            fail("압축하지 않은 프레임 크기가 다릅니다")
        return data
    algorithm = COMPRESSION_ALGORITHMS.get(codec)
    if algorithm is None:
        fail(f"알 수 없는 압축 코덱: {codec}")
    if size == 0:
        return b""
    lib = ctypes.CDLL("/usr/lib/libcompression.dylib")
    lib.compression_decode_buffer.restype = ctypes.c_size_t
    lib.compression_decode_buffer.argtypes = [
        ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_int,
    ]
    out = ctypes.create_string_buffer(size)
    written = lib.compression_decode_buffer(out, size, data, len(data), None, algorithm)
    if written != size:
        fail(f"압축 해제 크기가 다릅니다: {written} != {size}")
    return out.raw


def scope_key(path: str) -> str:
    name = os.path.basename(path)
    if name.endswith(SETTINGS_NAME):
        return "settings"
    match = re.search(r"(\d{4}-\d{2})\.taptionbackup$", name)
    if not match:
        fail("파일 이름이 ...yyyy-MM.taptionbackup 또는 taption-settings.taptionbackup 형식이 아닙니다(월은 파일 이름에서 얻습니다)")
    return match.group(1)


def read_public_header(data: bytes) -> dict:
    if len(data) < len(MAGIC) + 4 or data[:8] != MAGIC:
        fail("Taption 월 백업 파일이 아닙니다")
    (length,) = struct.unpack(">I", data[8:12])
    if length != HEADER_REGION:
        fail("헤더 영역 길이가 맞지 않습니다")
    if len(data) < BODY_OFFSET:
        fail("파일이 헤더 영역보다 짧습니다(잘렸습니다)")
    try:
        header = json.loads(data[12:12 + length])
    except ValueError:
        fail("헤더 영역을 읽을 수 없습니다")
    if not isinstance(header, dict) or header.get("format") != "taption-backup" or header.get("version") != 1:
        fail(f"지원하지 않는 형식입니다: {header.get('format') if isinstance(header, dict) else None}")
    kdf = header.get("kdf")
    if not isinstance(kdf, dict) or not isinstance(header.get("sealed"), str):
        fail("헤더에 kdf 또는 봉인된 헤더 블록이 없습니다")
    return header


def check_kdf(kdf: dict) -> tuple:
    if kdf.get("algorithm") != "PBKDF2-HMAC-SHA256":
        fail(f"알 수 없는 KDF: {kdf.get('algorithm')}")
    iterations = kdf.get("iterations")
    if not isinstance(iterations, int) or not MIN_ITERATIONS <= iterations <= MAX_ITERATIONS:
        fail(f"반복 횟수가 허용 범위({MIN_ITERATIONS}~{MAX_ITERATIONS})를 벗어납니다: {iterations}")
    try:
        salt = base64.b64decode(kdf["salt"], validate=True)
    except (KeyError, ValueError):
        fail("솔트를 읽을 수 없습니다")
    if len(salt) < 8:
        fail("솔트가 너무 짧습니다")
    return salt, iterations


def open_header(password: str, public: dict, month: str):
    """키를 유도하고 봉인된 헤더 블록을 연다. (헤더, 키)를 돌려준다."""
    salt, iterations = check_kdf(public["kdf"])
    key = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, iterations, 32)
    try:
        sealed = base64.b64decode(public["sealed"], validate=True)
    except ValueError:
        fail("봉인된 헤더 블록을 읽을 수 없습니다")
    if len(sealed) <= AEAD_OVERHEAD:
        fail("봉인된 헤더 블록이 너무 짧습니다")
    aad = b"TAPTBK02-HDR|" + salt + f"|{month}|".encode() + struct.pack(">I", public["version"])
    try:
        plain = AESGCM(key).decrypt(sealed[:12], sealed[12:], aad)
    except InvalidTag:
        fail("비밀번호가 맞지 않거나 헤더 블록이 손상됐습니다")
    try:
        header = json.loads(plain)
    except ValueError:
        fail("헤더 블록 내용을 읽을 수 없습니다")
    if header.get("month") != month or header.get("kdf") != public["kdf"] or header.get("version") != public["version"]:
        fail("헤더 블록이 파일과 맞지 않습니다")
    return header, key


def verify_and_collect(data: bytes, header: dict, key: bytes, sink):
    """모든 검증을 하면서 복호화한 줄(개행 포함)을 `sink`에 쓴다. 틀리면 종료한다."""
    body = data[BODY_OFFSET:]
    if len(body) != header["bodyBytes"] or hashlib.sha256(body).hexdigest() != header["bodySHA256"]:
        fail("본문 바이트 수 또는 SHA-256이 헤더와 다릅니다(파일이 깨졌습니다)")
    chunk_bytes, chunk_count = header["chunkBytes"], header["chunkCount"]
    if not 1 <= chunk_bytes <= MAX_CHUNK_BYTES or chunk_count < 0 or chunk_count > len(body) // (9 + AEAD_OVERHEAD):
        fail("헤더의 청크 크기 또는 개수가 허용 범위를 벗어납니다")
    max_plain = max_plain_frame(chunk_bytes)
    salt = base64.b64decode(header["kdf"]["salt"])
    offset, plain_total, digest, trailer = 0, 0, hashlib.sha256(), None
    counts = collections.Counter()
    for index in range(chunk_count):
        if offset + 9 > len(body):
            fail(f"프레임 {index}의 머리가 잘렸습니다")
        codec = body[offset]
        plain_size, sealed_size = struct.unpack(">II", body[offset + 1:offset + 9])
        if plain_size > max_plain or not AEAD_OVERHEAD <= sealed_size <= max_plain + AEAD_OVERHEAD:
            fail(f"프레임 {index}의 크기가 허용 범위를 벗어납니다")
        sealed = body[offset + 9:offset + 9 + sealed_size]
        if len(sealed) != sealed_size:
            fail(f"프레임 {index}가 잘렸습니다")
        offset += 9 + sealed_size
        plain_total += plain_size
        final = index == chunk_count - 1
        aad = b"TAPTBK02|" + salt + f"|{header['month']}|".encode() + struct.pack(">I", index) \
            + bytes([1 if final else 0, codec]) + struct.pack(">I", plain_size)
        try:
            compressed = AESGCM(key).decrypt(sealed[:12], sealed[12:], aad)
        except InvalidTag:
            fail(f"프레임 {index}의 인증 태그가 맞지 않습니다(변조 또는 손상)")
        for line in decompress(codec, compressed, plain_size).split(b"\n"):
            if not line:
                continue
            if trailer is not None:
                fail("트레일러 뒤에 데이터가 있습니다")
            if line.startswith(b'["#end"'):
                try:
                    trailer = json.loads(line)
                except ValueError:
                    fail("트레일러를 읽을 수 없습니다")
                continue
            digest.update(line + b"\n")
            kind = "schema" if line.startswith(b'["#') else {b"r": "readings", b"c": "records"}.get(line[2:3])
            if kind is None:
                fail("알 수 없는 줄 종류가 있습니다")
            counts[kind] += 1
            if line.startswith(b'["c"'):
                try:
                    if json.loads(line)[7]:
                        counts["tombstones"] += 1
                except (ValueError, IndexError):
                    fail("기록 줄을 읽을 수 없습니다")
            sink.write(line + b"\n")
    if offset != len(body) or plain_total != header["plaintextBytes"]:
        fail("본문 끝 또는 평문 크기가 맞지 않습니다")
    if not isinstance(trailer, list) or len(trailer) != 7:
        fail("트레일러가 없거나 형식이 맞지 않습니다")
    if trailer[5] != digest.hexdigest() or trailer[5] != header["contentSHA256"]:
        fail("트레일러의 내용 해시가 맞지 않습니다")
    if (trailer[1], trailer[2]) != (header["readingCount"], header["recordCount"]):
        fail("트레일러의 행 수가 헤더와 다릅니다")
    if (counts["readings"], counts["records"]) != (header["readingCount"], header["recordCount"]) \
            or header["rowCount"] != header["readingCount"] + header["recordCount"]:
        fail("실제 행 수가 헤더와 다릅니다")
    if trailer[3] != header.get("firstTimestamp") or trailer[4] != header.get("lastTimestamp"):
        fail("트레일러의 첫/마지막 시각이 헤더와 다릅니다")
    if trailer[6] != header.get("latestRecordUpdate"):
        fail("트레일러의 기록 최신 수정 시각이 헤더와 다릅니다")
    return counts


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("file")
    parser.add_argument("--password", default=os.environ.get("TAPTION_BACKUP_PASSWORD"))
    parser.add_argument("--header", action="store_true", help="평문 헤더만 출력(비밀번호가 있으면 암호화된 헤더도)")
    parser.add_argument("--summary", action="store_true", help="복호화·검증 후 표별 행 수만 출력")
    parser.add_argument("--out", help="JSON Lines를 쓸 폴더(없으면 표준 출력)")
    args = parser.parse_args()

    try:
        with open(args.file, "rb") as handle:
            data = handle.read()
    except OSError as error:
        fail(f"파일을 열 수 없습니다: {error}")
    public = read_public_header(data)
    month = scope_key(args.file)
    if args.header:
        shown = {"public": {key: value for key, value in public.items() if key != "sealed"}, "sealedHeaderBytes": len(public["sealed"])}
        if args.password:
            shown["encrypted"] = open_header(args.password, public, month)[0]
        print(json.dumps(shown, ensure_ascii=False, indent=2, sort_keys=True))
        return
    header, key = open_header(args.password or getpass.getpass("비밀번호: "), public, month)

    # 전체 검증이 끝나기 전에는 아무것도 내보내지 않는다: 임시 파일에 모았다가 검증 뒤에 옮긴다.
    with tempfile.TemporaryFile() as staged:
        counts = verify_and_collect(data, header, key, staged)
        staged.seek(0)
        if args.out and not args.summary:
            os.makedirs(args.out, exist_ok=True)
            target = os.path.join(args.out, os.path.basename(args.file) + ".jsonl")
            partial = target + ".partial"
            with open(partial, "wb") as out_file:
                shutil.copyfileobj(staged, out_file)
            os.replace(partial, target)
        elif not args.summary:
            shutil.copyfileobj(staged, sys.stdout.buffer)
    print(json.dumps({"month": header["month"], "verified": True, "rows": dict(counts),
                      "firstTimestamp": header["firstTimestamp"], "lastTimestamp": header["lastTimestamp"]},
                     ensure_ascii=False), file=sys.stderr if not (args.summary or args.out) else sys.stdout)


if __name__ == "__main__":
    sys.exit(main())
