#!/usr/bin/env python3
"""앱에 넣는 결제 문자·알림 단축어를 만들고 서명한다(SCA1112A01).

받은 문자·알림(단축어 입력)을 BOKKI Plan의 「결제 문자 넣기」·「결제 알림 넣기」 동작에 그대로 넘긴다.
`shortcuts sign --mode anyone`은 macOS에서만 되고 Apple 계정 로그인이 필요하다.
사용: python3 scripts/shortcuts/build.py
"""
import pathlib, plistlib, re, subprocess, tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
ASSETS = ROOT / "TaptionPlan/Assets.xcassets/Shortcuts"
SHORTCUTS = {"BokkiShortcutPaymentText": "AddPaymentMessageIntent",
             "BokkiShortcutPaymentAlert": "AddPaymentNotificationIntent"}


def team() -> str:
    text = (ROOT / "TaptionPlan.xcodeproj/project.pbxproj").read_text()
    return re.search(r"DEVELOPMENT_TEAM = (\w+);", text).group(1)


def workflow(intent: str) -> dict:
    shortcut_input = {"Value": {"string": "￼", "attachmentsByRange": {"{0, 1}": {"Type": "ExtensionInput"}}},
                      "WFSerializationType": "WFTextTokenString"}
    action = {"WFWorkflowActionIdentifier": "com.taption.plan." + intent,
              "WFWorkflowActionParameters": {
                  "AppIntentDescriptor": {"TeamIdentifier": team(), "BundleIdentifier": "com.taption.plan",
                                          "Name": "BOKKI Plan", "AppIntentIdentifier": intent},
                  "text": shortcut_input}}
    return {"WFWorkflowActions": [action], "WFWorkflowClientVersion": "2607.0.0",
            "WFWorkflowMinimumClientVersion": 900, "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowIcon": {"WFWorkflowIconStartColor": 431817727, "WFWorkflowIconGlyphNumber": 59511},
            "WFWorkflowImportQuestions": [], "WFWorkflowTypes": [], "WFWorkflowHasShortcutInputVariables": True,
            "WFWorkflowInputContentItemClasses": ["WFStringContentItem", "WFRichTextContentItem", "WFGenericFileContentItem"],
            "WFWorkflowOutputContentItemClasses": []}


def main() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        for name, intent in SHORTCUTS.items():
            raw = pathlib.Path(tmp) / f"{name}.shortcut"
            raw.write_bytes(plistlib.dumps(workflow(intent), fmt=plistlib.FMT_BINARY))
            out = ASSETS / f"{name}.dataset" / f"{name}.shortcut"
            subprocess.run(["shortcuts", "sign", "--mode", "anyone", "--input", str(raw), "--output", str(out)], check=True)
            out.chmod(0o644)
            print(out.relative_to(ROOT), out.stat().st_size)


if __name__ == "__main__":
    main()
