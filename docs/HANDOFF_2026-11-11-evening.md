BOKKI Plan(Taption Plan) 작업을 이어서 한다. 저장소: /Users/u_mo_c/Documents/taption plan (main). 대표에게는 한국어로 답하고, 질문은 객관식으로 한다.

시작할 때
- AGENTS.md를 따른다. git status, 최근 커밋, temp.md「진행 중」을 확인한다.
- 요청 ID마다 temp.md에 원인·해결·검증을 먼저 적는다. 결과는 test.md에 남기고, 로그는 build/validation/<ID>/에 둔다.
- 커밋 끝줄: Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
- 오늘 바뀐 규칙은 DEVELOPMENT.md 「2026-11-11에 더한 규칙」과 「자주 걸리는 함정」, 외부 테스트는 docs/TESTFLIGHT.md 「외부 테스트」에 있다.

먼저 할 일: TestFlight 313 확인 (요청 ID TFB1111A10)
- 313은 끝남: 처리 `VALID`, 내부 그룹 「TP Taption Plan 내부 테스트」와 외부 그룹 「TP 지인 테스트」 연결, 외부 베타 심사 `APPROVED`·`IN_BETA_TESTING`, 네 번들 313(test.md TFB1111A10). 할 일은 대표 기기 확인 요청뿐.
- 튜토리얼 새 모양(FRD1111A01, 참고 화면 모양·시그니처 색)은 커밋 끝(20675d09)이지만 313 뒤라 다음 빌드에 들어간다. 시뮬레이터에서 보려면 Debug 실행 인자 `-tutorialPreview <단계 이름>`. 이전 단추가 위쪽으로 옮겨 튜토리얼 UI 시험은 아직 안 돌림.
- 313에 처음 들어간 것(대표에게 기기에서 직접 확인해 달라고 할 것):
  - SUB1111A01: 걸으며 연결된 이어폰을 차로 보지 않음, 지하철 출근 인식(교대→마곡나루), 튄 위치·환승 비용 경로
  - CAR1111A01: CarPlay 차 자동 등록(여러 대), 등록 안 한 블루투스는 차 근거 아님, 앱 열 때 「이 기기가 내 차 같아요」
  - CAL1111A02: 위치 끊긴 회의를 앞뒤 같은 장소·일정으로 이어 기록
  - AIQ1111A01: 메모 패널 「AI」 탭(대기·처리중·완료·실패), 결제 문자·영수증을 AI가 처리·다듬기, 서버 배포 끝(버전 1237c930)
  - SIR1111A01·SHT1111A01: Siri 동작 11개·문구 53개, 「BOKKI Plan에 저장」, 결제 앱 알림 넣기(iOS 27 「알림 › 앱 푸시」), 「출금」 인식, 「보키 플랜」 호출, 메뉴 › 연결 「단축어 · Siri」
  - CRT1111A01·튜토리얼: 「내 차」 단계, 「단축어 · Siri」 단계
  - DTP·DTL·ASK(다른 세션): 사이드바 상세 무늬·범례, 센서로 못 정하는 상세는 직접 추가, 앱 열 때 하나씩 묻기
  - 화면: 홈 테두리 회색 1pt 통일(BRD1111A01·A02), 녹화 중 사이드바 단추 숨김(REC1111A01), 미래 날짜 집 레벨은 오늘(LVL1111A01), 듀오 바깥 화면 정렬(DUO1111A01~A03)

남은 코드 작업 (대표 지시: 순서대로 전부)
1. temp.md 정리: 11-10 항목(SEC·AIR·CLN·TRP·BUB 등) 중 test.md에 끝난 근거가 있는 것은 지운다.
2. AI 확인 목록 2단계(AIQ1111A01): 경로 확인·교통비(버스·지하철·통행료)·작은 조각 합침 검토·머문 장소 확인을 AI 목록에 자동으로 올리는 생산자, 필요한 MCP 쓰기 도구(이동 수단·요금, 장소 이름). 서버를 바꾸면 `npm test` 뒤 배포는 대표 허락.
3. 대중교통 구간 요금 표시(`FareCalculator` 호출부)·공항 좌표표(TAU1111A01·TAU1110A01).
4. AI 대화로 여행 가져오기 남은 화면(TRP1110A01): 시간 막대 표시, 좌표·이동 시간 경고, 클립보드 감지, 공유 시트, 재생.
5. 단축어 동작 이름·설명 12개 언어(지금 한국어 `LocalizedStringResource`만, LED1111A02).
6. UI 시험 7개 실기기 시간 초과(UIT1110A01).
- 나중에(대표 「나중에」): 성탄절 같은 날 집 아이콘 화랑이 코스튬(HOM1111A01).

대표 결정·확인이 필요한 것
- Claude 「바로 추가」 링크·승인(CLD1111A01·GDE1111A01), ChatGPT 맞춤 GPT 실제 호출(GPT1111A01), Cue 헤더 인증(CUE1110A01), 여행 프롬프트 키를 1회용 주소로 바꿀지(SET1110A01), 서버 비밀값 `PIN_PEPPER`·`KAKAO_REST_API_KEY` 등록(REV1110A06, wrangler secret은 대표만), 국내 카드 실제 문자 5건 대조(LED1111A02).
- 듀오 안쪽(전면) 화면 미리보기: 시뮬레이터가 접혀 있어 찍지 못함. 대표가 시뮬레이터를 펼쳐 주거나 실기기 화면이 필요.

지켜야 할 것
- BOKKI Plan 기기 시험은 아이폰 11(UDID 00008030-001628201AD2802E)에서만 한다.
  - 시작 전에 `mkdir /tmp/bokki-device-00008030-001628201AD2802E.lock`, 끝나면 `rmdir`, BOKKI Cam 세션에 알림.
  - 빌드 잠금은 /tmp/taptionplan-xcodebuild.lock.
  - 아이폰 18은 대표의 일상폰이자 BOKKI Cam 시험폰이다. 절대 쓰지 않는다.
  - 이 기기 묶음 실행에서 `FeatureEngineTests`의 시간 의존 시험 2건(`testImmediateSensorAnalysisKeepsEveryPendingDay`·`testSensorAnalysisDefersBackgroundReadingsAndCoalescesOnForeground`)이 간헐 실패한다. 단독 재실행으로 확인하고 그대로 기록한다.
- 화면 모양은 시뮬레이터 BOKKI-Preview(듀오, `--display=1`)에서 본다.
- 문구는 language.text로 쓴다. 번역 절차: extract.py → translations/<lang>.json의 "ui"(indent=0, sort_keys, 끝 줄바꿈 유지) → check.py 실패 0 → generate.py.
- 중계 서버는 server/trip-relay. 시험 `npm test`, 배포 `npx wrangler deploy --config wrangler.local.toml`(대표 허락). 마지막 배포 1237c930.
- CI(GitHub, Xcode 26.6)가 오늘 처음으로 네 작업 모두 초록이 됐다. push 뒤 CI를 확인하고, iOS 27 전용 API는 `#if compiler(>=6.4)`로 감싼다. 구조 지표는 커밋 전에 `python3 scripts/architecture-metrics.py --check docs/architecture-baseline.json`.
- 다른 세션과 같은 폴더를 쓸 때는 `git add -A` 대신 파일을 골라 스테이징한다(DEVELOPMENT.md 함정 참고).
- 공개 저장소다. 메일·계정 이름·workers.dev 주소·공개 TestFlight 링크를 남기지 않는다. 실제 비밀번호는 입력하지 않는다.
- 백업 비밀번호는 6자리를 유지한다(KDF 강화 제안 금지).
- IAP와 App Store 심사 제출은 보류한다. 외부 테스트 그룹 「TP 지인 테스트」에는 대표가 말할 때만 올린다(313은 대표 지시로 올림).
