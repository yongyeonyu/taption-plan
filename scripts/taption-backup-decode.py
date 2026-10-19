#!/usr/bin/env python3
"""Taption Plan 월 백업(yyyy-MM.taptionbackup, 형식 버전 1)을 비밀번호만으로 풀어 JSON Lines로 낸다.

사용:
  python3 scripts/taption-backup-decode.py <백업 파일> --header            # 비밀번호 없이 헤더만
  python3 scripts/taption-backup-decode.py <백업 파일> --summary           # 복호화해 표별 행 수·검증 결과
  python3 scripts/taption-backup-decode.py <백업 파일> --out build/backup-decode   # 줄을 <이름>.jsonl로 저장
  python3 scripts/taption-backup-decode.py <백업 파일> > rows.jsonl        # 표준 출력으로 줄 내보내기

비밀번호는 --password 또는 환경변수 TAPTION_BACKUP_PASSWORD, 없으면 입력창으로 받는다.
키 = PBKDF2-HMAC-SHA256(비밀번호, 헤더의 솔트, 헤더의 반복 횟수, 32바이트). 모든 프레임의 AES-GCM 태그,
본문 SHA-256, 트레일러의 행 수·내용 해시를 확인하고, 하나라도 틀리면 종료 코드 1로 끝낸다.
압축은 macOS의 libcompression(LZFSE/zlib)을 ctypes로 쓴다. macOS에서만 동작한다.
"""
import argparse
import base64
import collections
import ctypes
import getpass
import hashlib
import hmac
import json
import os
import struct
import sys

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

MAGIC = b"TAPTBK02"
HEADER_REGION = 2048
BODY_OFFSET = len(MAGIC) + 4 + HEADER_REGION
COMPRESSION_ALGORITHMS = {1: 0x801, 2: 0x205}  # 1=LZFSE, 2=zlib. 0=압축 안 함


def fail(message: str) -> None:
    print(f"오류: {message}", file=sys.stderr)
    raise SystemExit(1)


def decompress(codec: int, data: bytes, size: int) -> bytes:
    if codec == 0:
        if len(data) != size:
            fail("압축하지 않은 프레임 크기가 다릅니다")
        return data
    algorithm = COMPRESSION_ALGORITHMS.get(codec)
    if algorithm is None:
        fail(f"알 수 없는 압축 코덱: {codec}")
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


def read_header(data: bytes) -> dict:
    if data[:8] != MAGIC:
        fail("Taption 월 백업 파일이 아닙니다")
    (length,) = struct.unpack(">I", data[8:12])
    if length != HEADER_REGION:
        fail("헤더 영역 길이가 맞지 않습니다")
    header = json.loads(data[12:12 + length])
    if header.get("format") != "taption-backup" or header.get("version") != 1:
        fail(f"지원하지 않는 형식입니다: {header.get('format')} v{header.get('version')}")
    return header


def derive_key(password: str, header: dict) -> bytes:
    kdf = header["kdf"]
    if kdf["algorithm"] != "PBKDF2-HMAC-SHA256":
        fail(f"알 수 없는 KDF: {kdf['algorithm']}")
    key = hashlib.pbkdf2_hmac("sha256", password.encode(), base64.b64decode(kdf["salt"]), int(kdf["iterations"]), 32)
    mac = hmac.new(key, f"taption-backup-key-check|{header['month']}".encode(), hashlib.sha256).digest()[:16]
    if base64.b64encode(mac).decode() != header["keyCheck"]:
        fail("비밀번호가 맞지 않습니다")
    return key


def decode_lines(data: bytes, header: dict, key: bytes):
    """복호화한 줄(bytes, 개행 제외)을 차례로 내고, 끝에서 모든 검증을 마친다."""
    body = data[BODY_OFFSET:]
    if len(body) != header["bodyBytes"] or hashlib.sha256(body).hexdigest() != header["bodySHA256"]:
        fail("본문 바이트 수 또는 SHA-256이 헤더와 다릅니다(파일이 깨졌습니다)")
    salt = base64.b64decode(header["kdf"]["salt"])
    offset, digest, trailer = 0, hashlib.sha256(), None
    for index in range(header["chunkCount"]):
        codec = body[offset]
        plain_size, sealed_size = struct.unpack(">II", body[offset + 1:offset + 9])
        sealed = body[offset + 9:offset + 9 + sealed_size]
        offset += 9 + sealed_size
        final = index == header["chunkCount"] - 1
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
                trailer = json.loads(line)
                continue
            digest.update(line + b"\n")
            yield line
    if offset != len(body):
        fail("본문 끝이 맞지 않습니다")
    if trailer is None or trailer[5] != digest.hexdigest() or trailer[5] != header["contentSHA256"]:
        fail("트레일러의 내용 해시가 맞지 않습니다")
    if (trailer[1], trailer[2]) != (header["readingCount"], header["recordCount"]):
        fail("트레일러의 행 수가 헤더와 다릅니다")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("file")
    parser.add_argument("--password", default=os.environ.get("TAPTION_BACKUP_PASSWORD"))
    parser.add_argument("--header", action="store_true", help="비밀번호 없이 헤더만 출력")
    parser.add_argument("--summary", action="store_true", help="복호화·검증 후 표별 행 수만 출력")
    parser.add_argument("--out", help="JSON Lines를 쓸 폴더(없으면 표준 출력)")
    args = parser.parse_args()

    with open(args.file, "rb") as handle:
        data = handle.read()
    header = read_header(data)
    if args.header:
        print(json.dumps(header, ensure_ascii=False, indent=2, sort_keys=True))
        return
    key = derive_key(args.password or getpass.getpass("비밀번호: "), header)

    out_file = None
    if args.out and not args.summary:
        os.makedirs(args.out, exist_ok=True)
        out_file = open(os.path.join(args.out, os.path.basename(args.file) + ".jsonl"), "wb")
    counts = collections.Counter()
    for line in decode_lines(data, header, key):
        counts["schema" if line.startswith(b'["#') else {b"r": "readings", b"c": "records"}[line[2:3]]] += 1
        if out_file:
            out_file.write(line + b"\n")
        elif not args.summary:
            sys.stdout.buffer.write(line + b"\n")
    if out_file:
        out_file.close()
    print(json.dumps({"month": header["month"], "verified": True, "rows": dict(counts),
                      "firstTimestamp": header["firstTimestamp"], "lastTimestamp": header["lastTimestamp"]},
                     ensure_ascii=False), file=sys.stderr if not (args.summary or args.out) else sys.stdout)


if __name__ == "__main__":
    sys.exit(main())
