#!/usr/bin/env python3
"""Siri 호출 문장 카탈로그(`TaptionPlan/AppShortcuts.xcstrings`)를 만든다(SHL1111A01).

한국어·영어 문장은 코드(`BokkiShortcuts`)가 정본이고, 12개 언어는 `app-shortcuts.json`에 둔다.
`--check`는 파일을 쓰지 않고 규칙과 카탈로그가 최신인지만 본다.
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
SWIFT = ROOT / "TaptionPlan/Core/LedgerIntents.swift"
SOURCE = ROOT / "scripts/l10n/app-shortcuts.json"
CATALOG = ROOT / "TaptionPlan/AppShortcuts.xcstrings"
LANGUAGES = ["ja", "zh-Hans", "zh-Hant", "de", "fr", "it", "es", "pt-BR", "vi", "id", "th", "hi"]
APP = "${applicationName}"
TOKEN = re.compile(r"\$\{(\w+)\}")
HANGUL = re.compile(r"[가-힣]")


def code_phrases():
    """코드의 `phrases: [...]` 묶음을 카탈로그 표기(`${이름}`)로 읽는다."""
    text = SWIFT.read_text(encoding="utf-8")
    groups = []
    for block in re.findall(r"phrases:\s*\[(.*?)\n\s*\],", text, re.S):
        phrases = re.findall(r'^\s*"(.*)",?\s*$', block, re.M)
        phrases = [re.sub(r"\\\(\\\.\$(\w+)\)", r"${\1}", p.replace(r"\(.applicationName)", APP)) for p in phrases]
        groups.append(phrases)
    return groups


def problems(groups, translations):
    found = []
    keys = [group[0] for group in groups]
    if keys != list(translations):
        found.append(f"묶음의 첫 문장이 코드와 다르다: {sorted(set(keys) ^ set(translations))}")
    for group in groups:
        entry = translations.get(group[0], {})
        slots = set(TOKEN.findall(group[0]))
        if sorted(entry) != sorted(LANGUAGES):
            found.append(f"{group[0]!r}: 언어가 12개가 아니다")
        for language, phrases in [("ko", group)] + list(entry.items()):
            if not phrases:
                found.append(f"{language} {group[0]!r}: 문장이 없다")
            for phrase in phrases:
                if phrase.count(APP) != 1:
                    found.append(f"{language}: 앱 이름이 한 번 들어가야 한다 {phrase!r}")
                if set(TOKEN.findall(phrase)) != slots:
                    found.append(f"{language}: 자리 표시가 다르다 {phrase!r}")
                if language != "ko" and HANGUL.search(phrase):
                    found.append(f"{language}: 한글이 남았다 {phrase!r}")
    for language in LANGUAGES:
        every = [p for entry in translations.values() for p in entry.get(language, [])]
        found += [f"{language}: 같은 문장이 두 번 {p!r}" for p in sorted(set(every)) if every.count(p) > 1]
    return found


def catalog(groups, translations):
    strings = {}
    for group in groups:
        sets = {"ko": group, "en": [p for p in group if not HANGUL.search(p)], **translations[group[0]]}
        strings[group[0]] = {
            "localizations": {
                language: {"stringSet": {"state": "translated", "values": values}}
                for language, values in sorted(sets.items())
            }
        }
    data = {"sourceLanguage": "ko", "strings": strings, "version": "1.0"}
    return json.dumps(data, ensure_ascii=False, indent=2, separators=(",", " : ")) + "\n"


def main():
    groups = code_phrases()
    translations = json.loads(SOURCE.read_text(encoding="utf-8"))
    found = problems(groups, translations)
    if found:
        print("\n".join(found))
        return 1
    text = catalog(groups, translations)
    if "--check" in sys.argv:
        if not CATALOG.exists() or CATALOG.read_text(encoding="utf-8") != text:
            print("AppShortcuts.xcstrings가 최신이 아니다. app_shortcuts.py를 돌린다.")
            return 1
    else:
        CATALOG.write_text(text, encoding="utf-8")
    print(f"호출 문장 묶음 {len(groups)}개 × 언어 {len(LANGUAGES) + 2}개")
    return 0


if __name__ == "__main__":
    sys.exit(main())
