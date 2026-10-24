#!/usr/bin/env python3
"""App Store Connect API client for TestFlight automation.

의존성 없이 동작해야 한다. PyJWT를 쓰지 않고 `openssl`로 ES256 JWT를 만든다.
개인키는 읽기만 하고 어떤 경우에도 화면에 출력하지 않는다.

사용:
    asc.py preflight [--json]
    asc.py latest-build
    asc.py builds [--limit N]
    asc.py wait --build N [--timeout S]
    asc.py attach --build N [--group ID]
    asc.py verify --build N [--group ID] [--out PATH]
    asc.py groups
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

BASE = "https://api.appstoreconnect.apple.com"
SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent.parent
CONFIG_PATH = SCRIPT_DIR / "config.json"


# ---------------------------------------------------------------- 설정


def load_config() -> dict:
    """config.json을 읽고 환경변수로 덮어쓴다. 비밀은 여기에 두지 않는다."""
    if not CONFIG_PATH.is_file():
        raise SystemExit(f"설정 파일이 없습니다: {CONFIG_PATH}")
    config = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    asc = config["appStoreConnect"]
    asc["issuerId"] = os.environ.get("ASC_API_ISSUER", asc["issuerId"])
    asc["keyId"] = os.environ.get("ASC_API_KEY", asc["keyId"])
    key_path = os.environ.get("ASC_API_KEY_PATH", asc["keyPath"])
    asc["keyPath"] = str(
        Path(key_path.format(keyId=asc["keyId"])).expanduser()
    )
    group = config["testflight"]
    group["internalGroupId"] = os.environ.get(
        "TESTFLIGHT_GROUP_ID", group["internalGroupId"]
    )
    return config


# ---------------------------------------------------------------- JWT


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _der_to_raw(der: bytes) -> bytes:
    """openssl이 주는 DER ECDSA 서명을 JWT가 요구하는 R||S 64바이트로 바꾼다."""
    if not der or der[0] != 0x30:
        raise SystemExit("서명 형식이 DER SEQUENCE가 아닙니다.")
    index = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    if der[index] != 0x02:
        raise SystemExit("서명에서 R 정수를 찾지 못했습니다.")
    r_length = der[index + 1]
    r_value = der[index + 2 : index + 2 + r_length]
    index += 2 + r_length
    if der[index] != 0x02:
        raise SystemExit("서명에서 S 정수를 찾지 못했습니다.")
    s_length = der[index + 1]
    s_value = der[index + 2 : index + 2 + s_length]
    return (
        r_value.lstrip(b"\x00").rjust(32, b"\x00")
        + s_value.lstrip(b"\x00").rjust(32, b"\x00")
    )


def make_token(config: dict) -> str:
    """ES256 JWT를 만든다. 개인키 내용은 반환값·로그에 남기지 않는다."""
    asc = config["appStoreConnect"]
    key_path = Path(asc["keyPath"])
    if not key_path.is_file():
        raise SystemExit(f"API 개인키가 없습니다: {key_path}")

    now = int(time.time())
    header = {"alg": "ES256", "kid": asc["keyId"], "typ": "JWT"}
    payload = {
        "iss": asc["issuerId"],
        "iat": now,
        "exp": now + 900,
        "aud": "appstoreconnect-v1",
    }
    signing_input = (
        _b64url(json.dumps(header, separators=(",", ":")).encode())
        + "."
        + _b64url(json.dumps(payload, separators=(",", ":")).encode())
    )
    result = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", str(key_path)],
        input=signing_input.encode(),
        capture_output=True,
    )
    if result.returncode != 0:
        raise SystemExit(
            "openssl 서명에 실패했습니다: "
            + result.stderr.decode(errors="replace").strip()
        )
    return signing_input + "." + _b64url(_der_to_raw(result.stdout))


def token_claims(token: str) -> dict:
    """서명된 토큰의 헤더·페이로드를 되읽는다(검증용, 비밀 아님)."""
    header_b64, payload_b64, _ = token.split(".")
    decode = lambda part: json.loads(
        base64.urlsafe_b64decode(part + "=" * (-len(part) % 4))
    )
    return {"header": decode(header_b64), "payload": decode(payload_b64)}


# ---------------------------------------------------------------- HTTP


def api(
    config: dict,
    method: str,
    path: str,
    params: dict | None = None,
    body: dict | None = None,
    retries: int = 3,
) -> dict:
    url = BASE + path
    if params:
        query = "&".join(
            f"{urllib.parse.quote(str(k))}={urllib.parse.quote(str(v))}"
            for k, v in params.items()
        )
        url = f"{url}?{query}"
    data = None
    headers = {
        "Authorization": f"Bearer {make_token(config)}",
        "Accept": "application/json",
    }
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"

    last_error = None
    for attempt in range(1, retries + 1):
        request = urllib.request.Request(
            url, data=data, method=method, headers=headers
        )
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                raw = response.read().decode("utf-8")
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")
            if error.code in (429, 500, 502, 503, 504) and attempt < retries:
                last_error = f"HTTP {error.code}"
                time.sleep(2 * attempt)
                continue
            raise SystemExit(f"HTTP {error.code} {method} {path}\n{detail}")
        except urllib.error.URLError as error:
            if attempt < retries:
                last_error = str(error.reason)
                time.sleep(2 * attempt)
                continue
            raise SystemExit(f"네트워크 오류 {path}: {error.reason}")
    raise SystemExit(f"요청이 반복 실패했습니다: {path} ({last_error})")


# ---------------------------------------------------------------- 조회


def app_id(config: dict) -> str:
    bundle_id = config["app"]["bundleId"]
    data = api(
        config,
        "GET",
        "/v1/apps",
        {"filter[bundleId]": bundle_id, "limit": "5"},
    )
    if not data.get("data"):
        raise SystemExit(
            f"App Store Connect에서 앱을 찾지 못했습니다: {bundle_id}\n"
            "Issuer ID·키 ID가 이 앱이 속한 팀의 것인지 확인하세요."
        )
    return data["data"][0]["id"]


def list_builds(config: dict, limit: int = 30) -> list[dict]:
    # `/v1/apps/{id}/builds`는 sort 파라미터를 허용하지 않는다(400 PARAMETER_ERROR).
    # 서버가 준 순서를 믿지 않고 빌드 번호로 직접 내림차순 정렬한다.
    data = api(
        config,
        "GET",
        f"/v1/apps/{app_id(config)}/builds",
        {
            "limit": str(limit),
            "fields[builds]": "version,processingState,uploadedDate,expired",
        },
    )
    builds = [
        {
            "id": row["id"],
            "version": row["attributes"]["version"],
            "processingState": row["attributes"]["processingState"],
            "uploadedDate": row["attributes"].get("uploadedDate"),
            "expired": row["attributes"].get("expired"),
        }
        for row in data.get("data", [])
    ]
    return sorted(builds, key=lambda build: int(build["version"]), reverse=True)


def find_build(config: dict, version: int) -> dict | None:
    for build in list_builds(config, limit=200):
        if int(build["version"]) == int(version):
            return build
    return None


def find_group(config: dict, group_id: str | None) -> dict:
    tf = config["testflight"]
    target = group_id or tf["internalGroupId"]
    data = api(
        config,
        "GET",
        f"/v1/betaGroups/{target}",
        {"fields[betaGroups]": "name,isInternalGroup,publicLinkEnabled"},
    )
    return {
        "id": target,
        "name": data["data"]["attributes"]["name"],
        "isInternalGroup": data["data"]["attributes"].get("isInternalGroup"),
    }


# ---------------------------------------------------------------- 명령


def cmd_preflight(config: dict, as_json: bool) -> int:
    checks: list[dict] = []

    def record(name: str, ok: bool, detail: str) -> None:
        checks.append({"check": name, "ok": ok, "detail": detail})

    asc = config["appStoreConnect"]
    record(
        "issuer_id",
        bool(asc["issuerId"]),
        asc["issuerId"],
    )
    record("key_id", bool(asc["keyId"]), asc["keyId"])

    key_path = Path(asc["keyPath"])
    if key_path.is_file():
        size = key_path.stat().st_size
        head = key_path.read_text(encoding="utf-8", errors="replace").splitlines()[:1]
        looks_pem = bool(head) and "PRIVATE KEY" in head[0]
        record(
            "private_key",
            looks_pem and size > 100,
            f"{key_path} ({size} bytes, PEM={'yes' if looks_pem else 'no'})",
        )
    else:
        record("private_key", False, f"없음: {key_path}")

    if any(not c["ok"] for c in checks):
        return report(checks, as_json)

    try:
        token = make_token(config)
        record("jwt_signed", token.count(".") == 2, "ES256 서명 생성")
    except SystemExit as error:
        record("jwt_signed", False, str(error))
        return report(checks, as_json)

    # 서명된 토큰이 실제로 config의 Issuer ID·키 ID를 담고 있는지 되읽어 확인한다.
    claims = token_claims(token)
    payload, header = claims["payload"], claims["header"]
    record(
        "jwt_claims",
        payload.get("iss") == asc["issuerId"]
        and header.get("kid") == asc["keyId"]
        and header.get("alg") == "ES256"
        and payload.get("aud") == "appstoreconnect-v1",
        f"iss={payload.get('iss')} kid={header.get('kid')} "
        f"alg={header.get('alg')} aud={payload.get('aud')}",
    )

    tooling = {}
    for tool in ("xcodebuild", "xcrun", "openssl"):
        tooling[tool] = subprocess.run(
            ["/usr/bin/which", tool], capture_output=True
        ).returncode == 0
    record(
        "tooling",
        all(tooling.values()),
        " ".join(f"{name}={'ok' if ok else 'missing'}" for name, ok in tooling.items()),
    )

    try:
        resolved = app_id(config)
        record("app_lookup", True, f"{config['app']['bundleId']} → {resolved}")
    except SystemExit as error:
        record("app_lookup", False, str(error))
        return report(checks, as_json)

    builds = list_builds(config, limit=200)
    latest = builds[0] if builds else None
    record(
        "builds_readable",
        True,
        "최고 빌드 "
        + (f"{latest['version']} ({latest['processingState']})" if latest else "없음")
        + f" · {len(builds)}건 조회",
    )

    try:
        group = find_group(config, None)
        record(
            "internal_group",
            True,
            f"{group['name']} ({group['id']}, internal={group['isInternalGroup']})",
        )
    except SystemExit as error:
        record("internal_group", False, str(error))

    return report(checks, as_json)


def report(checks: list[dict], as_json: bool) -> int:
    ok = all(check["ok"] for check in checks)
    if as_json:
        print(json.dumps({"ok": ok, "checks": checks}, ensure_ascii=False, indent=2))
    else:
        for check in checks:
            mark = "OK  " if check["ok"] else "FAIL"
            print(f"[{mark}] {check['check']}: {check['detail']}")
        print("사전 점검 통과" if ok else "사전 점검 실패")
    return 0 if ok else 1


def cmd_wait(config: dict, version: int, timeout: int) -> int:
    interval = int(config["testflight"]["pollIntervalSeconds"])
    deadline = time.time() + timeout
    while True:
        build = find_build(config, version)
        if build is None:
            state = "NOT_UPLOADED"
        else:
            state = build["processingState"]
        print(f"[{time.strftime('%H:%M:%S')}] build {version}: {state}", flush=True)
        if state == "VALID":
            return 0
        if state in ("FAILED", "INVALID"):
            print(f"처리가 실패했습니다: {state}", file=sys.stderr)
            return 1
        if time.time() >= deadline:
            print(f"{timeout}초 안에 처리가 끝나지 않았습니다.", file=sys.stderr)
            return 1
        time.sleep(interval)


def cmd_attach(config: dict, version: int, group_id: str | None) -> int:
    build = find_build(config, version)
    if build is None:
        raise SystemExit(f"빌드 {version}을 찾지 못했습니다.")
    group = find_group(config, group_id)
    api(
        config,
        "POST",
        f"/v1/betaGroups/{group['id']}/relationships/builds",
        body={"data": [{"type": "builds", "id": build["id"]}]},
    )
    print(f"빌드 {version}을 {group['name']} 그룹에 연결했습니다.")
    return 0


def cmd_verify(
    config: dict, version: int, group_id: str | None, out: str | None
) -> int:
    build = find_build(config, version)
    group = find_group(config, group_id)
    group_builds = api(
        config,
        "GET",
        f"/v1/betaGroups/{group['id']}/builds",
        {"limit": "50", "fields[builds]": "version,processingState,expired"},
    )
    testers = api(
        config,
        "GET",
        f"/v1/betaGroups/{group['id']}/betaTesters",
        {"limit": "100", "fields[betaTesters]": "email,firstName,lastName,inviteType"},
    )
    versions = sorted(
        int(row["attributes"]["version"]) for row in group_builds.get("data", [])
    )
    attached = [
        row
        for row in group_builds.get("data", [])
        if int(row["attributes"]["version"]) == int(version)
    ]
    result = {
        "checkedAt": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "build": version,
        "buildId": build["id"] if build else None,
        "processingState": build["processingState"] if build else None,
        "group": group,
        "groupBuildVersions": versions,
        "buildAttached": bool(attached),
        "attachedBuild": attached[0]["attributes"] if attached else None,
        "testerCount": len(testers.get("data", [])),
        "testers": [
            {
                "email": row["attributes"].get("email"),
                "inviteType": row["attributes"].get("inviteType"),
            }
            for row in testers.get("data", [])
        ],
    }
    result["ok"] = bool(
        result["processingState"] == "VALID"
        and result["buildAttached"]
        and result["testerCount"] > 0
    )
    if out:
        Path(out).parent.mkdir(parents=True, exist_ok=True)
        Path(out).write_text(
            json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8"
        )
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result["ok"] else 1


def cmd_groups(config: dict) -> int:
    data = api(
        config,
        "GET",
        f"/v1/apps/{app_id(config)}/betaGroups",
        {"limit": "50", "fields[betaGroups]": "name,isInternalGroup"},
    )
    for row in data.get("data", []):
        print(
            row["id"],
            row["attributes"]["name"],
            "internal" if row["attributes"].get("isInternalGroup") else "external",
        )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="App Store Connect API helper")
    parser.add_argument(
        "command",
        choices=[
            "preflight",
            "latest-build",
            "builds",
            "wait",
            "attach",
            "verify",
            "groups",
        ],
    )
    parser.add_argument("--build", type=int)
    parser.add_argument("--group")
    parser.add_argument("--out")
    parser.add_argument("--limit", type=int, default=30)
    parser.add_argument("--timeout", type=int)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    config = load_config()

    if args.command == "preflight":
        return cmd_preflight(config, args.json)
    if args.command == "latest-build":
        builds = list_builds(config, limit=200)
        if not builds:
            print("빌드가 없습니다.")
            return 1
        print(builds[0]["version"])
        return 0
    if args.command == "builds":
        for build in list_builds(config, limit=args.limit):
            print(
                f"{build['version']}\t{build['processingState']}\t"
                f"{build['uploadedDate']}\t{build['id']}"
            )
        return 0
    if args.command == "groups":
        return cmd_groups(config)
    if args.command == "wait":
        if args.build is None:
            parser.error("--build 가 필요합니다")
        timeout = args.timeout or int(
            config["testflight"]["processingTimeoutSeconds"]
        )
        return cmd_wait(config, args.build, timeout)
    if args.command == "attach":
        if args.build is None:
            parser.error("--build 가 필요합니다")
        return cmd_attach(config, args.build, args.group)
    if args.command == "verify":
        if args.build is None:
            parser.error("--build 가 필요합니다")
        return cmd_verify(config, args.build, args.group, args.out)
    return 2


if __name__ == "__main__":
    sys.exit(main())
