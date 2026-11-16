#!/usr/bin/env python3
"""APS1115A01: 스크린샷·미리보기 영상을 App Store Connect 1.0(ko)에 올린다.

기존 자료는 지우지 않고, 새 자료를 앞에 둔다. 비밀은 scripts/testflight/asc.py가 읽는다.
사용: python3 asc_upload.py [--dry-run]
"""
import hashlib
import json
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT.parent.parent / "scripts" / "testflight"))
import asc  # noqa: E402

SHOTS = {"APP_IPHONE_67": "iphone", "APP_IPHONE_DUO": "duo", "APP_IPAD_PRO_3GEN_129": "ipad"}
PREVIEW = ("IPHONE_67", ROOT / "output" / "preview" / "app-preview-iphone.mp4")


def localization(config):
    app = asc.app_id(config)
    versions = asc.api(config, "GET", f"/v1/apps/{app}/appStoreVersions", {"filter[appStoreState]": "PREPARE_FOR_SUBMISSION"})
    version = versions["data"][0]["id"]
    locs = asc.api(config, "GET", f"/v1/appStoreVersions/{version}/appStoreVersionLocalizations")
    return next(l["id"] for l in locs["data"] if l["attributes"]["locale"] == "ko")


def find_or_create_set(config, loc, kind, attr, value):
    sets = asc.api(config, "GET", f"/v1/appStoreVersionLocalizations/{loc}/{kind}")
    for item in sets["data"]:
        if item["attributes"][attr] == value:
            return item["id"]
    body = {"data": {"type": kind, "attributes": {attr: value},
                     "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": loc}}}}}
    return asc.api(config, "POST", f"/v1/{kind}", body=body)["data"]["id"]


def upload(config, kind, set_kind, set_id, path, extra=None):
    data = path.read_bytes()
    attrs = {"fileName": path.name, "fileSize": len(data), **(extra or {})}
    rel = {set_kind: {"data": {"type": set_kind + "s", "id": set_id}}}
    created = asc.api(config, "POST", f"/v1/{kind}", body={"data": {"type": kind, "attributes": attrs, "relationships": rel}})["data"]
    for op in created["attributes"]["uploadOperations"]:
        chunk = data[op["offset"]:op["offset"] + op["length"]]
        headers = {h["name"]: h["value"] for h in op.get("requestHeaders", [])}
        request = urllib.request.Request(op["url"], data=chunk, method=op["method"], headers=headers)
        with urllib.request.urlopen(request, timeout=300) as response:
            response.read()
    body = {"data": {"type": kind, "id": created["id"],
                     "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}}
    asc.api(config, "PATCH", f"/v1/{kind}/{created['id']}", body=body)
    return created["id"]


def wait_done(config, kind, ids):
    states = {}
    for _ in range(60):
        for asset_id in ids:
            attrs = asc.api(config, "GET", f"/v1/{kind}/{asset_id}")["data"]["attributes"]
            states[asset_id] = attrs.get("assetDeliveryState") or {}
        if all(s.get("state") in ("COMPLETE", "FAILED") for s in states.values()):
            break
        time.sleep(10)
    return states


def put_first(config, set_kind, set_id, kind, new_ids):
    current = asc.api(config, "GET", f"/v1/{set_kind}s/{set_id}/relationships/{kind}")["data"]
    old = [item["id"] for item in current if item["id"] not in new_ids]
    order = [{"type": kind, "id": i} for i in new_ids + old]
    asc.api(config, "PATCH", f"/v1/{set_kind}s/{set_id}/relationships/{kind}", body={"data": order})
    return old


def main():
    dry = "--dry-run" in sys.argv
    config = asc.load_config()
    loc = localization(config)
    report = {}
    for display, folder in SHOTS.items():
        files = sorted((ROOT / "output" / folder).glob("0[1-6]-*.png"))
        print(display, [f.name for f in files])
        if dry:
            continue
        set_id = find_or_create_set(config, loc, "appScreenshotSets", "screenshotDisplayType", display)
        ids = [upload(config, "appScreenshots", "appScreenshotSet", set_id, f) for f in files]
        states = wait_done(config, "appScreenshots", ids)
        done = [i for i in ids if states[i].get("state") == "COMPLETE"]
        old = put_first(config, "appScreenshotSet", set_id, "appScreenshots", done) if done else []
        report[display] = {"set": set_id, "uploaded": len(ids), "complete": len(done), "kept_old": len(old),
                           "errors": [states[i].get("errors") for i in ids if states[i].get("state") != "COMPLETE"]}
        print(json.dumps(report[display], ensure_ascii=False))
    preview_type, path = PREVIEW
    print(preview_type, path.name)
    if not dry:
        set_id = find_or_create_set(config, loc, "appPreviewSets", "previewType", preview_type)
        pid = upload(config, "appPreviews", "appPreviewSet", set_id, path, {"mimeType": "video/mp4"})
        states = wait_done(config, "appPreviews", [pid])
        report[preview_type] = {"set": set_id, "state": states[pid]}
        print(json.dumps(report[preview_type], ensure_ascii=False))
        out = ROOT.parent.parent / "build" / "validation" / "APS1115A01" / "asc-upload.json"
        out.write_text(json.dumps(report, ensure_ascii=False, indent=2))
        print(out)


if __name__ == "__main__":
    main()
