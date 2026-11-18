# 지금 상태와 다음 순서 (2026-11-18 밤 기준)

남은 항목 자체는 `test.md` `## 남은 작업`(영역별 색인·요청 상세)과 `## 실기기 확인 목록`(기기별 손 순서)에 있고, 이 문서는 지금 상태 요약과 순서만 적는다. 숫자와 상태는 이 날의 것이므로 시작할 때 `git log`·`test.md`로 다시 확인한다. 2026-11-14 밤(빌드 343 기준) 판은 Git 기록에 있다.

## 0. 지금 상태

- 빌드: TestFlight 내부 351(VALID, 「TP Taption Plan 내부 테스트」 그룹 연결·테스터 노출 확인, TFB1118A02, 판 main `eddf41d7`·PCC 끔). 아이폰 18 실기기 확인은 351로 합니다.
- 서버: 2026-11-18 22:06 배포 `81e89e3e`(도로공사 `/ex/units`·`/ex/fare`, 카카오 `/kakao/directions`, `EX_API_KEY` 넣음). 그 앞 배포는 `6b3ff5b8`(AIF1118A01).
- 시험: 합친 main의 전체 단위 `TaptionPlanTests` 3,064건 실행·건너뜀 26·실패 0(KDR1118A01, 시뮬레이터). UI 56건 실패 0(FUL1118A01 `c762fd37`, 시뮬레이터). 아이폰 11 Pro 실기기 단위 3,029건 중 실패 1(Mac 파일 읽는 시험, 실기기에서 건너뛰게 고침). 실기기 UI 시험은 자동화 켜기 시간 초과로 건너뜀(대표 결정 2026-11-18).
- CI: app job은 기존 `TravelModeView.swift` 978행 actor 격리 오류(Xcode 26)로 실패 중이고 대표 지시로 건드리지 않는다. packages job은 `DayStoreV3Tests.testConcurrentColdOpensInitializeOneV3Schema`가 「database is locked」로 간헐 실패.
- 꺼 둔 것: Apple PCC(`AppleModelEnvironment.isPrivateCloudComputeEnabled = false`, entitlement 승인 전), 푸시 권한 항목(PSH1114A12), 키가 없는 사진 출처.
- 출시 전 반드시: `TripLiveLocationService.isAvailable` 끄기(위치정보법 검토·신고 전, 대표 결정 2026-11-17).

## 1. 대표가 볼 것 (기기)

`test.md` `## 실기기 확인 목록` 순서대로.

1. 아이폰 18(TestFlight 350 이상): FUL1118A01 점검표 17개, PCC1118A01·CRV1118A01 메모 다듬기 시나리오 4개.
2. 실제 운전(아이폰 18): 도로공사 고속도로·민자 고속도로 퇴근으로 통행료 세 갈래(지난 톨게이트·같은 길·카카오), 첫 출퇴근 「확인 필요」, 11-16~11-18 금액 고침.
3. 아이폰 11 Pro: 여행 화면(TVM1117A02·TBH1116A01·STY1116A01), 홈 제안(HUX1116A02~A06), 성능 눈 확인(PRF1116A02·PRF1117A02), AI 연결 왕복.
4. 두 기기: 여행 공유(TSH1114A26)·동행 위치(LOC1116S01).
5. Watch: 하룻밤 착용 뒤 로그(WSN1112A01~A03), 페이스·위젯(WUI1112A01).

## 2. 대표 결정 대기

`test.md` `### 대표 결정 대기`에 모았다. 먼저 물을 것(객관식, 추천 첫째):

1. 메모 저장 상한 1,000자와 다듬기 상한(기기 1,500·PCC 12,000)을 어떻게 맞출지(CRV1118A01 후속 ①).
2. 좌표가 든 메모를 사용자가 직접 「연결된 AI에게 맡기기」로 보낼 때 막을지(CRV1118A01 후속 ②).
3. 민자 도로를 매일 다니는 길을 길별 규칙 여러 개로 둘지(TGT1118A01·KDR1118A01 ④) — 코드로 할 수 있으나 「확인 필요」가 매번 뜨는 것을 받아들일지부터.

외부 대기: Apple PCC entitlement 승인, Apple Small Business Program 접수(대표가 알려 주기로 함), 푸시용 App ID·APNs 키, 사진 출처 키, 위치정보법 검토·신고.

## 3. 다음 코드 일 (기기 확인과 무관하게)

1. 통행료: 한국어·영어 밖 언어 제목의 통행료 판별(`isToll`), 민자 도로 길별 규칙(대표 답 뒤).
2. Apple 모델: 지출·일정 초안을 라우터에 잇기(하루 요약은 기기 모델 안 씀, 대표 결정 2026-11-18). PCC는 승인 뒤.
3. CI packages job의 `DayStoreV3Tests` 「database is locked」 간헐 실패.
4. AI 서버의 완료 보고 동시 덮어쓰기(AIR1114A01), AIF1118A01 남은 낮음 항목.
5. 패키지 이동의 나머지(`docs/AI_RELAY_PLAN.md` 「P4의 남은 순서」), 묵은 코드 일(RMN1114A24).
6. 성능: 날짜 바꾼 뒤 40ms 넘는 끊김·긴 날 재생 다시 재기(PRF1117A02), 콜드 실행은 재개 지시 때(PRF1117A01).
7. 리팩토링 남은 것(RFT1116A01·RFT1116A02, `docs/REFACTOR_TOP20.md`).

## 4. 그 뒤 후보

여행 공유의 일정 상태 바꾸기(두 기기 확인 뒤), 가계부 「확인 필요」 함 다듬기, 취소 연결, 뒤 일정 자동 밀기, 애플 캘린더 양방향, 지출을 일정·이동 구간에 직접 잇기, Trip 이식 남은 단위(공금·지갑·환불은 대표 결정 뒤).
