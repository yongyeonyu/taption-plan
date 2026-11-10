# 여행 계획 중계 서버 (TRP1110A04)

AI 비서(도구 호출이 되는 비서, ChatGPT 맞춤 GPT Actions, 단축어 등)가 여행 JSON을 보내면, 사용자가 앱을 열 때 미리보기로 가져오는 Cloudflare Worker입니다. 복사·붙여넣기 없이 계획이 도착합니다.

## 동작
- 앱이 기기에서 연동 키(무작위 32바이트, base64url 43자)를 만들어 키체인에만 둡니다.
- AI가 `POST /plan`으로 JSON을 보냅니다. 헤더 `Authorization: Bearer <키>`, 본문은 앱의 여행 JSON 형식(`format: "bokki-trip"`, `version: 1`) 그대로입니다. 최대 64KB.
- 앱은 앱을 열 때 `GET /plan`으로 한 번 확인하고, 받으면 바로 `DELETE /plan`으로 지운 뒤 미리보기를 띄웁니다. 반영은 사용자가 미리보기에서 누를 때만 합니다.
- 서버는 키를 SHA-256으로만 저장하고(원래 키는 저장하지 않음), 계획은 3일 뒤 자동으로 지웁니다. 키마다 마지막 계획 하나만 둡니다. IP·요청을 기록하지 않습니다.

| 요청 | 응답 |
|---|---|
| `POST /plan` | 201 저장, 400 JSON 아님, 401 키 없음·형식 틀림, 413 64KB 초과, 422 여행 형식 아님 |
| `GET /plan` | 200 계획 JSON, 204 없음 |
| `DELETE /plan` | 204 |

## 배포 (대표님이 하는 일)
1. 이 폴더에서:
   ```sh
   npx wrangler login
   npx wrangler kv namespace create PLANS
   ```
2. 나온 KV `id`를 `wrangler.toml`의 `REPLACE_WITH_KV_NAMESPACE_ID` 자리에 넣고 `npx wrangler deploy`.
3. 배포 주소의 호스트 이름만(예: `taption-trip-relay.<계정>.workers.dev` 또는 연결한 도메인) 앱 빌드 설정 `TRIP_RELAY_HOST`(`TaptionPlan/AppSecrets.local.xcconfig`)에 넣습니다. 비어 있으면 앱은 이 기능을 숨깁니다.
4. Cloudflare 대시보드에서 이 Worker에 속도 제한 규칙을 둡니다(예: IP당 분당 30회). 무료 KV는 하루 쓰기 1,000건이라, 남용되면 쓰기가 막힙니다.

## 확인할 것
- 무료 한도(Workers 요청, KV 읽기·쓰기)는 Cloudflare 요금 문서에서 배포 전에 다시 확인하세요.
- 여행 일정이 서버에 최대 3일 머무르므로 개인정보 처리방침(PRIVACY.md)과 App Store 개인정보 항목에 반영해야 합니다.

## 테스트
```sh
npm test
```
