#!/usr/bin/env python3
"""번역 자동 점검. 실패가 하나라도 있으면 종료 코드 1로 끝나며, 출시 조건이다."""
from __future__ import annotations
import json, re, sys
from collections import Counter
from pathlib import Path

L10N = Path(__file__).resolve().parent
LANGUAGES = ["ja", "zh-Hans", "zh-Hant", "de", "fr", "it", "es", "pt-BR", "vi", "id", "th", "hi"]
HANGUL = re.compile(r"[가-힣]")
SPEC = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|@|f|\.\df|%)")
BRACE = re.compile(r"\{\d+\}")
KEEP = ["BOKKI Plan", "Hwarang", "Chunhyang", "Yunbok"]
LENGTH_LIMIT = 2.5


def specs(text: str) -> Counter:
    return Counter(re.sub(r"\d+\$", "", s) for s in SPEC.findall(text))


def main() -> int:
    source = json.loads((L10N / "source.json").read_text(encoding="utf8"))
    failures, long_rows = [], []
    for language in LANGUAGES:
        path = L10N / "translations" / f"{language}.json"
        if not path.exists():
            failures.append(f"{language}: 번역 파일 없음")
            continue
        pack = json.loads(path.read_text(encoding="utf8"))
        for section, key_of in (("ui", lambda e: e["key"]), ("catalog", lambda e: f"{e['table']}:{e['key']}")):
            for entry in source[section]:
                key = key_of(entry)
                value = pack.get(section, {}).get(key)
                en = entry["en"]
                if value is None or (not value.strip() and en.strip()):
                    failures.append(f"{language}: 누락 {key!r}")
                    continue
                if HANGUL.search(value):
                    failures.append(f"{language}: 한글 남음 {key!r} → {value!r}")
                if section == "catalog" and specs(value) != specs(en):
                    failures.append(f"{language}: 형식 지정자 불일치 {key!r} → {value!r}")
                if section == "ui":
                    extra = set(BRACE.findall(value)) - set(BRACE.findall(en))
                    missing = set(BRACE.findall(en)) - set(BRACE.findall(value))
                    if extra:
                        failures.append(f"{language}: 없는 자리 {extra} {key!r} → {value!r}")
                    # 영어 복수 꼬리({n}이 s 등)만 뺄 수 있다. 나머지 자리는 지켜야 한다.
                    args = entry.get("args") or []
                    required = {f"{{{i}}}" for i, a in enumerate(args) if '"s"' not in a}
                    if missing & required:
                        failures.append(f"{language}: 자리 빠짐 {missing & required} {key!r} → {value!r}")
                for name in KEEP:
                    if name in en and name not in value:
                        failures.append(f"{language}: 고유 이름 {name} 빠짐 {key!r} → {value!r}")
                if len(en) >= 12 and len(value) > len(en) * LENGTH_LIMIT:
                    long_rows.append({"language": language, "key": key, "en": en, "value": value})
    (L10N / "long-strings.json").write_text(json.dumps(long_rows, ensure_ascii=False, indent=1) + "\n", encoding="utf8")
    print(f"실패 {len(failures)}, 긴 문구 {len(long_rows)}")
    for failure in failures[:80]:
        print(failure)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
