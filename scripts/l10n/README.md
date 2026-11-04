# 언어 팩

한국어·영어는 코드의 `text("한글", "English")`가 그대로 정본이고, 나머지 12개 언어(ja, zh-Hans, zh-Hant, de, fr, it, es, pt-BR, vi, id, th, hi)는 여기서 만듭니다.

- `extract.py`: 코드와 기존 카탈로그에서 대상을 모아 `source.json`을 만듭니다. 읽지 못한 호출은 `unread-report.json`에 남깁니다.
- `translations/<언어>.json`: 번역 원본. 키는 `ko|en`(변수 자리는 `{0}`), 영어만 있는 표는 `|en`, 기존 카탈로그는 `Localizable:키`·`InfoPlist:키`입니다.
- `generate.py`: 네 제품의 `UIText.xcstrings`와 `Localizable`·`InfoPlist`를 다시 씁니다. 카탈로그를 손으로 고치지 않습니다. 충돌을 피하려고 메인 세션만 실행합니다.
- `check.py`: 누락·남은 한글·자리 표시자·고유 이름을 점검합니다. 실패하면 출시하지 않습니다(사람 검수가 없는 대신의 조건, 대표 결정).
- `screens.sh`: 언어별 화면 스크린샷과 화면 글자를 남깁니다.

코드 규칙: 문구는 `language.text("한글", "English")`처럼 리터럴로 씁니다. 변수로 받은 문구만 `runtimeText`를 쓰고, 이 값은 표에 등록된 경우에만 번역됩니다. 문구를 더하면 `extract.py` → 번역 → `check.py` → `generate.py` 순서로 돌립니다. 빠진 번역은 영어로 보입니다.

언어 고르기: `AppLanguagePreference`가 자동·한국어·영어와 12개 번역 언어를 들고 있고(raw 값이 번들 코드), 번역 언어를 고르면 `UITextPack`이 그 `.lproj`에서 찾습니다. 다음 실행부터는 `AppleLanguages`로 시스템 문구도 따릅니다. 별도 AI 검수를 거치지 않은 문구가 남아 있습니다(`test.md` LNG1104A01·FBK1104B01·LNG1104A03).
