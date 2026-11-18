# Taption Plan 개발 규칙

현재 사용자 요청과 이 파일을 우선합니다. 진행 상황은 현재 코드·Git 상태와 요청 ID에 연결된 기록으로 확인하고, 날짜가 붙은 인계문은 역사 자료로만 취급합니다. 응답·보고·문서·커밋 메시지는 한국어로 씁니다.

## 1. 시작할 때

- 저장소 루트, `git status --short --branch`, `git log --oneline -5`를 확인합니다. 인계문이나 과거 로그의 브랜치·빌드·clean 상태를 현재 사실로 가정하지 않습니다.
- 요청 ID가 있으면 `rg -n -C 3 '<ID>' test.md`로 해당 줄만 찾습니다. 연결된 소스와 검증 로그는 필요한 파일·오류 주변만 읽고, 전체 기록·로그·`DerivedData`·보관 산출물을 재귀 검색하지 않습니다.
- 작업 범위에 필요한 파일만 열고 기존 변경·자료를 보존합니다. 명시되지 않은 초기화·삭제·임시 브랜치·외부 전송을 하지 않습니다. 기존 검증이 현재 코드와 요청에 여전히 유효하면 재사용합니다.

## 2. 요청 기록 (`test.md` 하나)

`test.md`는 세 부분입니다(2026-11-18부터, `temp.md`는 옮겼다는 안내만 남음).

| 부분 | 담는 것 |
| --- | --- |
| `## 남은 작업` | 영역별(AI·PCC / 가계부·통행료 / 여행·공유 / 홈·UI / 기록·분류·Watch / 성능·구조 / 배포·운영·출시 / 대표 결정 대기) 한 줄 색인 「ID · 남은 것 · 막힌 이유 · 근거」와 `### 요청 상세`(원인·해결·검증 기준·상태·대표 결정) |
| `## 실기기 확인 목록` | 기기별(아이폰 18 Pro Max / 아이폰 11 Pro / Apple Watch / 실제 운전·이동 / 두 기기·아이패드 / 출시 전 점검) 표 「ID · 할 일(손 순서) · 기대 결과 · 결과(○/✕, 날짜)」 |
| `## 검증 기록` | 실행한 검증의 근거, 최신이 위. 2026-11-14 이전에 닫힌 요청은 `test_ARCHIVE.md` |

- **새 요청**: 영문·숫자 10자리 ID(예: `ABC1118A01`)를 만들고, 구현 전에 `## 남은 작업`의 영역에 한 줄, `### 요청 상세`에 원인·해결·검증 기준을 적습니다.
- **진행 중**: 대표 결정·남은 것·막힌 이유를 그 줄과 상세에 덧붙입니다. 기기에서 손으로 볼 것은 `## 실기기 확인 목록`에 표 줄로 넣습니다.
- **끝낼 때**: 검증 기준을 채운 요청만 색인 줄과 상세를 지우고, `## 검증 기록` 맨 위에 결과 절(`### ID · 제목 (날짜, 어디서 돌렸나)`)을 씁니다. 기기 확인이 끝난 표 줄은 결과 칸을 채운 뒤 지웁니다.
- 검증 기록은 지우거나 「통과」로 고쳐 쓰지 않고 새 줄로 덧붙입니다. 기록은 실제 코드와 현재 Git 확인을 대신하지 않습니다. 전체 테스트의 과거 실패나 미완료 항목은 새 근거 없이 통과·완료로 처리하지 않습니다.
- 대표 결정은 날짜와 함께 「대표 결정 YYYY-MM-DD」로 적습니다. 오래 지켜야 하는 결정은 이 파일 4절에도 넣습니다.

## 3. 구현 경계

- 사용자에게 보이는 문구와 코드는 필요한 만큼만 작성합니다. 작은 함수와 분명한 이름을 우선하고 중복 추상화·장황한 주석을 피합니다.
- SwiftUI 상태는 값이 실제로 바뀔 때만 갱신합니다. 입력·그리기 상한은 4절 「성능 상한」을 따릅니다. 큰 시간표는 캐시와 지연 계산을 사용하고 드래그 종료 시 최종값을 즉시 반영합니다.
- 앱 UI·ActivityKit·MapKit은 앱 target에 둡니다(예외: AI 기능, 4절). 공유 엔진은 Swift Package 경계를 유지하고 공개 facade에서 센서 원본과 자동 판정 근거를 보존합니다.
- SQLite가 정본입니다. Codable 바이너리 payload는 LZFSE 압축·체크섬·바이트 수를 기록하고 현재 포맷만 읽으며(예외: 백업 파일, 4절), 동일 버전 변환은 한 번만 수행합니다. 데이터 경로·스키마 변경은 기존 기록·백업 호환성을 입증합니다.
- 자동 센서·HealthKit 원본과 provenance를 보존하고 자동 기록을 사용자 편집 가능한 수동 계획과 구분합니다. 원본 저장을 확정한 뒤 지도·Live Activity를 증분 갱신합니다. 외부 수신 센서는 지원되는 소스에 한해 빨간 심박 상태로 표시합니다.
- NLE 스타일 파생 projection은 generation이 있는 불변 값으로 만들고 오래된 계산을 폐기합니다. 지도 캐시는 파생 경로·주석·날씨·임시 위치·중심/줌만 담고 bounded LRU·지연 로딩·메모리 압력 축출을 따릅니다. Apple 지도 타일은 저장하지 않습니다.
- 좌표는 AI·서버·분석으로 보내지 않습니다. 예외는 4절 「좌표 예외」에 적힌 것뿐이고, 어느 예외도 AI·분석·로그·다른 서비스로 넓히지 않습니다.
- 백그라운드·재부팅·외부 센서 상태는 iOS가 실제 허용한 이벤트만 표시합니다. 실행되지 않은 수집이나 다른 앱 센서 사용을 추정하지 않습니다.

## 4. 대표 결정 (바꾸려면 대표의 새 지시가 필요)

- **성능 상한(2026-11-01)**: 입력은 240Hz까지 받되 레이아웃에 직접 전달하지 않습니다. 지도 카메라·화랑이·카운터처럼 UIKit/Core Animation이 직접 그리는 것은 움직이는 동안만 최대 120Hz(ProMotion 상한)로 그리고, SwiftUI 레이아웃 상태 갱신은 최대 60Hz로 합칩니다.
- **AI 패키지(2026-11-14)**: AI 기능은 `Packages/TaptionAssistant`로 옮겨 가는 중이라 앱 target 규칙의 예외입니다(`docs/AI_RELAY_PLAN.md`).
- **백업 형식(2026-11-08)**: 백업 파일은 새 `TAPTBK03`으로 쓰고 옛 `TAPTBK02`도 읽습니다.
- **백업 비밀번호(대표 확정)**: 6자리 숫자이며, 비밀번호만 알면 백업을 복구할 수 있어야 합니다. 오프라인 무차별 대입 위험은 수용한 결정이므로 기기 비밀을 키에 섞거나 길이를 늘리지 않습니다. 백업 파일의 평문에는 형식·버전·솔트·반복 횟수·파일명의 월만 두고, 행 수·시각·시간대·내용 해시 등 나머지 메타데이터는 같은 비밀번호 키로 암호화합니다. 백업 목록은 비밀번호를 입력한 뒤에 보여줍니다.
- **좌표 예외**(원칙: 좌표는 AI·서버·분석으로 보내지 않음). 아래 네 가지 모두 AI·분석·로그·다른 서비스로 넓히지 않습니다.
  1. **동행 위치(2026-11-16, LOC1116S01)**: 공유 여행의 동행에게, 그 여행 기간에만, 방 키로 종단 암호화한 현재 위치(위도·경도·정확도·시각)만 중계합니다. 서버는 읽지 못하고 이력을 쌓지 않으며(암호화된 마지막 1건만 10분, 도움 요청은 24시간), 본인이 여행마다 켜야 하고 언제든 끌 수 있습니다. 위치정보법 검토·신고가 끝나기 전에는 이 기능을 배포하지 않습니다. 2026-11-17 결정: 내부 TestFlight 그룹에는 켜 둔 채 올려도 되고, **외부 시험·출시 전에는 `TripLiveLocationService.isAvailable`을 끕니다**. 설계는 `docs/TRIP_LIVE_LOCATION_PLAN.md`.
  2. **장소 사진(2026-11-17, REV1117A01)**: 여행 계획 장소(사용자 현재 위치가 아님)의 좌표는 장소 사진 찾기에 한해 사진 출처(우리 서버·Google·Mapillary·위키 공용)로 보낼 수 있습니다.
  3. **버스 정류장(2026-11-17, REV1117A03)**: 버스 승·하차 정류장 확인은 그 자리 좌표를 우리 중계 서버의 정류장 조회(`/tago/stops`·`/seoul/stops`)에 보낼 수 있습니다. 서버는 이 좌표를 저장·기록하지 않습니다. 좌표는 POST 본문으로 보내고, 서울도 https인 TAGO(`/tago/stops`)로 먼저 찾습니다. 서울시 정류소정보(`ws.bus.go.kr`)는 https가 없어 중계 서버 → 서울시 구간이 평문이므로, TAGO가 응답했는데 가까운 정류장이 없을 때만 씁니다(TAGO가 응답하지 않으면 다음에 다시 봅니다, 「서울도 TAGO로」).
  4. **통행료(2026-11-18, TGT1118A01)**: 자동차 이동의 통행료를 한국도로공사 영업소 자료로 기기에서 알아내지 못할 때만(예: 인천공항고속도로 같은 민자 도로), 그 이동의 출발·도착과 경유지 최대 5개 좌표를 우리 중계 서버를 거쳐 카카오모빌리티 길찾기에 보내 통행료·도로 이름을 받을 수 있습니다. 서버는 이 좌표를 저장·기록하지 않고, 영업소를 기기에서 알아낸 이동은 보내지 않습니다. 도로공사에는 영업소 코드·차종만 보냅니다.
- **Apple PCC(2026-11-18, PCC1118A01)**: 좌표가 든 글은 Private Cloud Compute로 보내지 않습니다(AI 공유가 「끔」이어도 좌표 없는 글은 PCC를 씁니다). entitlement 승인 전에는 PCC를 꺼 둡니다(`AppleModelEnvironment.isPrivateCloudComputeEnabled = false`). 켤 때는 entitlement·스위치·`PRIVACY.md` 문구를 같은 커밋에 넣습니다(`docs/APPLE_FOUNDATION_MODELS.md`).
- **IAP·판매**: IAP 판매·계약·심사 제출은 별도 재개 요청 전까지 보류합니다.
- **실기기 데이터(2026-10-30)**: 아이폰 11(Pro 포함)이 사용 가능하면 아이클라우드에 올라온 원본·백업 데이터를 받아 그 기기에서 검증하고, 결과를 시뮬레이터 결과와 구분해 `test.md`에 남깁니다.
- **아이폰 18 Pro Max(2026-11-11·2026-11-18)**: 대표의 일상폰이자 BOKKI Cam 시험용입니다. BOKKI Plan 시험의 기본은 아이폰 11 Pro이고, 아이폰 18은 대표가 그 기기를 고른 확인(예: 2026-11-18 PCC·통행료, Apple Intelligence가 필요한 것)에만 씁니다.
- **실기기 UI 시험(2026-11-18)**: 「Timed out while enabling automation mode」로 막혀 건너뛰고 시뮬레이터 결과로 남깁니다.

## 5. 빌드·시험

- **빌드 잠금**: 빌드·시험은 `/tmp/taptionplan-xcodebuild.lock`을 `mkdir`로 잡고 그 안 `owner` 파일에 「요청ID pid」를 적은 뒤 합니다. 끝나면 자기 잠금만 지웁니다. 남의 잠금은 기다리고 지우지 않습니다. TestFlight `release.sh`도 이 잠금 안에서 돌립니다.
- **시뮬레이터**: `99AC6F35-6B50-4741-A11D-1A46E1F7F4BD`(iPhone 17)를 쓰고 `-parallel-testing-enabled NO`로 돌립니다.
- **외장 볼륨**: derived data는 `/Volumes/TaptionPlanBuild/dd/<ID>`, SPM 캐시는 `/Volumes/TaptionPlanBuild/spm`입니다. 재부팅 뒤에는 `hdiutil attach`가 필요합니다.
- **전체 단위 시험**은 `-only-testing:TaptionPlanTests`, UI 시험은 `-only-testing:TaptionPlanUITests`로 나눠 돌립니다. 「test runner hung before establishing connection」(시험 0건)이 나오면 시뮬레이터를 끄고 켠 뒤 다시 돌리고, 멈춘 로그는 `hung-…`으로 이름을 바꿔 남깁니다. 실제 실행 수·실패·건너뜀은 xcresult로 확인합니다.
- **로그**는 `build/validation/<요청 ID>/`에 둡니다. 결과 묶음·로그 경로가 이미 있으면 덮어쓰지 않고 번호를 붙입니다(`…-1`).
- **고정 작업 공간**: main을 바꾸는 동안 시험을 돌리려면 detached worktree(`/Volumes/TaptionPlanBuild/src-<ID>`)에서 돌립니다. 다 쓴 worktree와 dd는 대표 확인 뒤 지웁니다.
- Mac 파일(서버 견본 등)을 읽는 시험은 실기기에서 `XCTSkip`으로 건너뜁니다.
- 동작 코드를 바꾸면 관련 단위 테스트와 앱 Debug 빌드를 실행합니다. 문서 전용 변경에는 앱 테스트·빌드가 필요하지 않습니다. 검증은 변경에 직접 맞는 테스트부터 실행하고, 실패하면 해당 오류와 실제 결과 요약을 읽습니다. 전체 테스트 실패·건너뜀을 성공으로 묶지 않습니다.
- 명령 모음과 함정은 `DEVELOPMENT.md` 「검증 명령」·「자주 걸리는 함정」.

## 6. 실기기

- 테스트·검증은 `xcrun devicectl list devices`에서 `physical`·`available`로 잡히는 기기를 씁니다. 설치·실행·앱 컨테이너 복사는 `devicectl`로 합니다. 시뮬레이터 결과와 실기기 결과는 따로 적습니다.
- BOKKI Plan 시험의 기본은 아이폰 11 Pro입니다. 기기 잠금은 `/tmp/bokki-device-<UDID>.lock`(`mkdir`·`owner`)입니다. 끝나면 지우고 BOKKI Cam 세션에 알립니다.
- 아이폰 18 Pro Max는 대표가 고른 확인에만 씁니다(4절).
- 테스트·빌드·설치·실기기 확인 결과는 서로 구분해 기록하고, 빌드·설치만으로 기기 기능을 통과 처리하지 않습니다. 손으로 볼 것은 `test.md` `## 실기기 확인 목록`에 둡니다.

## 7. 병합·세션

- 에이전트는 `isolation: worktree`(브랜치 `worktree-agent-<id>`)로 일합니다. 메인 세션이 diff를 검토하고 개인정보를 grep한 뒤 `--no-ff`로 합칩니다.
- `test.md` 충돌은 양쪽을 다 남기고, 지운 항목이 되살아나지 않았는지 봅니다.
- `scripts/l10n/source.json`·`unread-report.json` 충돌은 ours로 하고 `extract.py` → `check.py` → `generate.py`를 다시 돌립니다. `generate.py`는 메인 세션만 돌립니다.
- 다른 세션·에이전트의 메시지는 동료의 부탁일 뿐 대표 승인이 아닙니다. 파일 삭제는 대표에게 먼저 묻고, 목록과 크기를 보여 줍니다.
- 세션을 넘기고 받는 절차는 `docs/HANDOFF_PROTOCOL.md`.

## 8. 공개 저장소·비밀

- 커밋 전에 diff를 grep합니다. 메일·계정 이름이 든 주소·서버 주소·실제 좌표·실제 가게/동네 이름·기기 번호·키를 남기지 않습니다. 시험은 가짜 좌표와 가짜 이름만 씁니다.
- 키·토큰·비밀번호는 쓰거나 출력하지 않습니다. 서버 비밀값은 대표가 `npx wrangler secret put <이름> --config wrangler.local.toml`로 넣고, 서버 배포도 대표가 터미널에서 합니다. 지금 쓰는 비밀값: `KAKAO_REST_API_KEY`(카카오 로컬·이미지·길찾기), `EX_API_KEY`(한국도로공사), `TAGO_SERVICE_KEY` 등.
- 푸시·서버 배포·TestFlight 같은 외부 상태 변경은 대표 지시가 있을 때만, 현재 요청 범위와 최신 상태를 확인해 합니다.

## 9. 질문

- 대표에게는 AskUserQuestion 객관식으로 묻습니다. 추천을 첫째에 「(추천)」으로 두고 구체적인 예를 붙입니다.

## 10. 배포

- 빌드 번호를 바꾸면 `CURRENT_PROJECT_VERSION`과 앱·위젯·Watch·Watch 위젯 `Info.plist`의 `CFBundleVersion`을 모두 확인하고, 최종 산출물에서도 네 제품 번들을 읽어 일치 여부를 검증합니다.
- TestFlight는 업로드만으로 완료하지 않습니다. 처리가 `제출 준비 완료`가 된 뒤 `TP Taption Plan 내부 테스트` 그룹에 연결하고 그룹 화면에서 빌드와 테스터 노출을 읽어 확인·기록합니다.
- **트리거**: 「테스트플라이트 연결해서 빌드업해」 요청이 들어오면 빌드 잠금 안에서 `bash scripts/testflight/release.sh --yes`를 실행합니다. 추가 확인 없이 빌드 번호 증가 → 아카이브 → 익스포트 → 업로드 → 내부 그룹 연결 → 검증까지 진행합니다.
- 설정은 `scripts/testflight/config.json`(Issuer ID·키 ID·번들·그룹 ID, 비밀 없음), 개인키는 `~/.appstoreconnect/private_keys/AuthKey_<키 ID>.p8`에만 둡니다. 키 내용은 출력·커밋하지 않습니다.
- 사전 점검만 하려면 `--preflight`, 업로드 없이 산출물까지만 확인하려면 `--no-upload`, 이미 올린 빌드를 다시 확인하려면 `bash scripts/testflight/verify.sh --build <번호>`를 씁니다.
- `release.sh`의 9단계가 `VALID`·그룹 연결·테스터 노출을 모두 읽어야 종료 코드 0이 되고, 보고서는 `build/validation/<요청 ID>/testflight-report.json`에 남습니다. 자세한 사용법은 `docs/TESTFLIGHT.md`.

## 11. 문서 위치

진입·규칙·기록
- `README.md`: 프로젝트 개요와 문서 진입점.
- `DEVELOPMENT.md`: 소스 경계, 아키텍처 예외, 데이터 계약, 검증 명령과 함정.
- `test.md`: 남은 작업·실기기 확인 목록·검증 기록(2절). 요청한 부분만 읽습니다. `temp.md`는 옮겼다는 안내만 남은 파일입니다.
- `docs/NEXT_PLAN.md`: 지금 상태 요약과 다음 순서(항목 자체는 `test.md` `## 남은 작업`).
- `docs/HANDOFF_PROTOCOL.md`: 세션을 넘기고 받는 절차(점검표·인계문 형식·같은 폴더 세션 규칙).
- `docs/TESTFLIGHT.md`: TestFlight 자동 배포의 트리거·설정·검증·실패 대응.
- `scripts/l10n/README.md`: 12개 언어 팩의 추출·번역·점검·생성 절차.
- `PRIVACY.md`·`TERMS.md`·`SUPPORT.md`: 개인정보처리방침·약관 초안·지원.

AI·서버
- `docs/AI_RELAY_PLAN.md`: 외부 AI ⇄ 중계 서버 ⇄ 앱 강화 계획 — 패키지 구조, 규칙 저장소, 요청·회신 파이프라인, 동작 확장, 단계 P0~P13과 진행 상태, 패키지 이동의 남은 순서, 여행 공유 설계안(AIX1114A01).
- `docs/APPLE_FOUNDATION_MODELS.md`: Apple 모델 3단계 길(PCC → 기기 모델 → 중계 큐)의 판단 표·연결한 곳·PCC entitlement 승인 뒤 할 일(PCC1118A01).
- `docs/ACTIVITY_RELAY_API.md`·`docs/TRIP_RELAY_API.md`: AI 비서 ↔ 앱 하루 기록·명령 규격, 여행 계획 중계 규격. `docs/AI_ASSISTANT_GUIDE.md`: 연결된 AI의 행동 수칙.
- `docs/SHARED_RULES_PLAN.md`: 공통 규칙(서명한 묶음 받기·후보 모으기·대표 검토·약관 초안) 설계와 배포 순서(SRL1116A01).
- `docs/AI_PUZZLE_PLAN.md`: AI와 「조각 맞추기」로 일정 만들기 세 안 비교(AIT1116A01). 시안 `design/AIT1116A01/`.

여행·공유
- `docs/TRAVEL_MODE_PLAN.md`: 여행 모드 개편 컨셉·화면·단계 T0~T12(TVM1111A01).
- `docs/COURSE_FIRST_PLAN.md`: 여행 「코스 먼저」 실행 계획 C1~C8과 사진 출처 판단(TVV1113A01).
- `docs/TRIP_PORT_ANALYSIS.md`: Taption Trip 여행·정산 기능 이식 분석과 단위 U1~U13(TRP1111A01).
- `docs/TRIP_IMPORT.md`: AI 대화로 여행 계획 가져오기(TRP1110A01).
- `docs/TRIP_SHARE_PROTOCOL.md`: 여행 공유 통신 규약 v1 — 키 유도·시험 벡터, 암호문 형식, HTTP 경로·WebSocket 메시지, 잠금, 권한 표, 한도, 키 교체, 앱 구현 체크리스트(TSH1114A26). 기기 쪽 코드는 `Packages/TaptionTripShare`·`TaptionPlan/Core/TripShare*.swift`(`DEVELOPMENT.md` 소스 표 「여행 공유」 줄).
- `docs/TRIP_LIVE_LOCATION_PLAN.md`: 여행 중 동행 실시간 위치 공유 설계(범위·동의·종단 암호화·주기·도와주세요·약관 초안·배포 순서, LOC1116S01). 통신 형식은 `docs/TRIP_SHARE_PROTOCOL.md` 21절.

화면·성능·구조
- `docs/HOME_UX_REVIEW.md`: 메인 홈 화면 UI·UX 검토와 제안 8개(HUX1116A01). 시안 `design/HUX1116A01/preview.html`.
- `docs/STYLE_UNIFY.md`: 앱 전체 스타일 통일 조사와 순서(STY1116A01).
- `docs/IPAD_UI.md`: 넓은 화면 배치 구성안과 남은 결함.
- `docs/PERFORMANCE_PLAN.md`: 아이폰 11 Pro 성능 측정·개선 계획과 전후 수치(PRF1116A01~PRF1117A02).
- `docs/STRUCTURE_PERFORMANCE.md`: 구조 성능 개선 안·전후 수치와 합친 뒤 할 일(ARC1103A01).
- `docs/DATA_PIPELINE.md`: 저장소 파이프라인 측정 결과와 개선 설계(P0~P3). 측정 도구는 `scripts/pipeline-bench.py`.
- `docs/ARCHITECTURE_ROADMAP.md`: 구조 로드맵(Phase 0~5)과 결정 기록(ADR).
- `docs/REFACTOR_TOP20.md`: 리팩토링 상위 20개 파일의 잰 값·할 일·겹침·상태와 전후 줄 수(RFT1116A01).
- `docs/reviews/`: 영역 리뷰 기록(REV1117A01~A04, LGC1117A01).
- `docs/ACCURACY_PLAN.md`: 분류 정확도 검토(약한 곳 10가지)와 제안 A~D, 카카오 지도 동일 화면 단계 K1~K5(ACC1114A01).
- `docs/PROPOSALS.md`: 구조·DB·AI 연결·UI·지도 색·UX·가계부·리팩토링 제안과 근거, 대표 결정 목록(PLN1111A01).
- `docs/HOME_EVOLUTION_LIST.md`: 집 성장 366일 건축물 목록(생성물).
- `docs/CLIENT_REPORT.md`·`docs/UX_ARCHITECTURE.md`·`docs/DESIGN_SYSTEM.md`: 2026-10-24 UX 진단·설계 자료(당시 기준).

보관본
- `test_ARCHIVE.md`, `docs/HANDOFF_<날짜>.md` 같은 날짜가 붙은 인계문: 지난 시점의 기록입니다. 현재 작업 시작 시 읽지 않고 고치지 않습니다.
