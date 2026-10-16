# AirKorea 중계 서버

앱이 `data.go.kr` 서비스 키를 갖지 않도록, 키를 서버에만 두고 측정소 단위로 캐시하는 Cloudflare Worker입니다.
앱은 측정소 이름만 보냅니다(좌표·식별자 없음). 서버는 IP나 요청을 기록하지 않습니다.

## 경로
- `GET /airkorea/stations` — 측정소 목록(24시간 캐시)
- `GET /airkorea/measurement?stationName=<이름>` — 측정소 실시간 PM10/PM2.5(30분 캐시)
- 그 밖의 경로·메서드·파라미터는 거부합니다. 상류 오류 응답(키·한도 오류)은 캐시하지 않고 502로 바꿉니다.

## 배포 (대표님이 하는 일)
1. 공공데이터포털에서 한국환경공단 대기오염정보(측정값)와 측정소정보 API를 활용신청하고 인증키를 받습니다.
2. Cloudflare 계정을 만들고(무료 플랜으로 시작 가능) 이 폴더에서:
   ```sh
   npx wrangler login
   npx wrangler secret put AIRKOREA_SERVICE_KEY   # 키는 여기에만 입력
   npx wrangler deploy
   ```
3. 배포된 주소의 **호스트 이름만**(예: `taption-airkorea-proxy.<계정>.workers.dev`) 앱의 빌드 설정 `AIR_QUALITY_PROXY_HOST`에 넣습니다. 비어 있으면 앱은 대기질을 표시하지 않습니다.
4. Cloudflare 대시보드에서 이 Worker에 속도 제한(rate limiting) 규칙을 추가하세요(예: IP당 분당 30회). 이 서버는 사용자 식별을 하지 않으므로 남용 방어는 플랫폼 규칙에 맡깁니다.

## 확인할 것 (제가 공식 수치를 찾지 못한 항목)
- 일일 트래픽 한도와 운영계정 전환 조건, 상업적 이용 가능 범위는 신청 상세 화면과 에어코리아 OpenAPI 기술문서에서 확인해야 합니다.

## 테스트
```sh
npm test
```
