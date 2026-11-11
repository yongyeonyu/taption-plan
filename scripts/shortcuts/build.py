#!/usr/bin/env python3
"""앱과 중계 서버에 넣는 「BOKKI 결제」 단축어를 만들고 서명한다(SCA1112A01, SCB1112A01).

「원」이 든 메시지를 받으면(트리거가 단축어 안에 든다, iOS 26부터) 받은 내용을 BOKKI Plan의 「결제 알림 넣기」에 넘긴다.
트리거 형식은 아이폰 11(iOS 26)에서 직접 만든 자동화를 iCloud 링크로 내보내 읽은 것과 같다(SCB1112A01).
앱 Assets 데이터로 쓰고, 안내 화면이 공유 시트로 단축어 앱에 넘긴다.
`shortcuts sign --mode anyone`은 macOS에서만 되고 Apple 계정 로그인이 필요하다.
사용: python3 scripts/shortcuts/build.py
"""
import pathlib, plistlib, re, subprocess, tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
ASSETS = ROOT / "TaptionPlan/Assets.xcassets/Shortcuts"
SHORTCUTS = {"BokkiShortcutPayment": "AddPaymentNotificationIntent"}


def team() -> str:
    text = (ROOT / "TaptionPlan.xcodeproj/project.pbxproj").read_text()
    return re.search(r"DEVELOPMENT_TEAM = (\w+);", text).group(1)


def workflow(intent: str) -> dict:
    shortcut_input = {"Value": {"string": "￼", "attachmentsByRange": {"{0, 1}": {"Type": "ExtensionInput"}}},
                      "WFSerializationType": "WFTextTokenString"}
    action = {"WFWorkflowActionIdentifier": "com.taption.plan." + intent,
              "WFWorkflowActionParameters": {
                  "ShowWhenRun": False,
                  "AppIntentDescriptor": {"TeamIdentifier": team(), "BundleIdentifier": "com.taption.plan",
                                          "Name": "BOKKI Plan", "AppIntentIdentifier": intent},
                  "text": shortcut_input}}
    trigger = {"WFTriggerIdentifier": "WFMessageTrigger", "WFTriggerUUID": "6B1F3C2A-9D4E-4F1B-8A7C-2E5D0B9C1A11",
               "WFTriggerSerializedParameters": {"WFMessageConditions": {
                   "Value": {"WFActionParameterFilterPrefix": 1, "WFContentPredicateBoundedDate": False,
                             "WFActionParameterFilterTemplates": [
                                 {"Operator": 1, "Values": {"Text": "원"}, "Removable": False, "Property": "Message"}]},
                   "WFSerializationType": "WFContentPredicateTableTemplate"}}}
    return {"WFWorkflowActions": [action], "WFWorkflowTriggers": [trigger], "WFWorkflowClientVersion": "5114.0.8.3",
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
