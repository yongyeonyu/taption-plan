#!/usr/bin/env python3
"""외부 테스트 그룹에 빌드를 올린다(TFB1111A10).

release.sh가 내부 그룹까지 끝낸 뒤 대표가 「외부 테스트까지」라고 할 때만 쓴다.
1) 외부 그룹에 빌드 연결  2) 「테스트할 내용」(ko) 적기  3) 베타 앱 심사 제출(이미 있으면 넘김)  4) 상태 읽기

    python3 scripts/testflight/external.py --build 313 --group <외부 그룹 id> --notes "..."
    python3 scripts/testflight/external.py --build 313 --status
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import asc  # noqa: E402


def localization(config: dict, build_id: str, notes: str) -> None:
    rows = asc.api(config, "GET", f"/v1/builds/{build_id}/betaBuildLocalizations").get("data", [])
    korean = next((row for row in rows if row["attributes"].get("locale") == "ko"), None)
    if korean:
        asc.api(config, "PATCH", f"/v1/betaBuildLocalizations/{korean['id']}", body={
            "data": {"type": "betaBuildLocalizations", "id": korean["id"], "attributes": {"whatsNew": notes}},
        })
    else:
        asc.api(config, "POST", "/v1/betaBuildLocalizations", body={
            "data": {
                "type": "betaBuildLocalizations",
                "attributes": {"locale": "ko", "whatsNew": notes},
                "relationships": {"build": {"data": {"type": "builds", "id": build_id}}},
            },
        })


def submit(config: dict, build_id: str) -> None:
    existing = asc.api(config, "GET", f"/v1/builds/{build_id}/betaAppReviewSubmission").get("data")
    if existing:
        print("베타 심사 제출이 이미 있습니다.")
        return
    asc.api(config, "POST", "/v1/betaAppReviewSubmissions", body={
        "data": {"type": "betaAppReviewSubmissions", "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}},
    }, retries=5, retry_404=True)
    print("베타 심사에 제출했습니다.")


def status(config: dict, build_id: str, group_id: str | None) -> dict:
    review = asc.api(config, "GET", f"/v1/builds/{build_id}/betaAppReviewSubmission").get("data")
    detail = asc.api(config, "GET", f"/v1/builds/{build_id}/buildBetaDetail")["data"]["attributes"]
    result = {
        "betaReviewState": review["attributes"].get("betaReviewState") if review else None,
        "externalBuildState": detail.get("externalBuildState"),
        "internalBuildState": detail.get("internalBuildState"),
    }
    if group_id:
        builds = asc.api(config, "GET", f"/v1/betaGroups/{group_id}/builds", {"limit": "50", "fields[builds]": "version"}).get("data", [])
        result["inExternalGroup"] = any(row["id"] == build_id for row in builds)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="외부 테스트 그룹 올리기")
    parser.add_argument("--build", type=int, required=True)
    parser.add_argument("--group")
    parser.add_argument("--notes", default="")
    parser.add_argument("--status", action="store_true")
    args = parser.parse_args()
    config = asc.load_config()
    build = asc.find_build(config, args.build)
    if build is None:
        raise SystemExit(f"빌드 {args.build}을 찾지 못했습니다.")
    if not args.status:
        if not args.group:
            parser.error("--group 이 필요합니다")
        asc.cmd_attach(config, args.build, args.group)
        if args.notes:
            localization(config, build["id"], args.notes)
        submit(config, build["id"])
    print(json.dumps(status(config, build["id"], args.group), ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
