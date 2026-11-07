# 인수인계 프롬프트 (2026-11-08)

아래를 새 세션 첫 메시지로 붙여 넣습니다. 지난 시점의 기록이므로 Git과 코드로 현재 상태를 먼저 확인합니다.

---

BOKKI Plan(저장소 `taption plan`) 작업을 이어받아 주세요. 대표에게는 한국어로 쓰고, 질문은 객관식으로 합니다. `AGENTS.md`를 따르고, 이 문서의 상태가 Git과 다르면 Git을 믿습니다.

## 먼저 확인할 것

```bash
git status --short --branch
git log --oneline -8
python3 scripts/architecture-metrics.py --check docs/architecture-baseline.json
xcrun devicectl list devices
```

작성 시점 상태:

- `main`을 `origin`에 push했고 워크트리·임시 브랜치·stash는 없습니다.
- TestFlight 내부 그룹 최신은 296입니다. `test.md`의 TFB1107A06을 보세요.
- 시험은 실기기 iPhone 18 Pro Max(`00008160-000E195A1140000A`)가 기본이고, 회사에서는 iPhone 11 Pro를 씁니다. `scripts/with-device-lock.sh`와 `-parallel-testing-enabled NO`로 돌립니다. 실기기를 쓸 수 없으면 시뮬레이터 BOKKI-iPhone11을 쓰고 결과를 따로 적습니다.
- iPhone 18에서 시험하면 TestFlight 앱이 Debug 시험 호스트로 바뀌어 느려집니다. 시험이 끝나면 Release를 다시 설치하거나 대표에게 TestFlight 재설치를 알립니다.
- 대표 iCloud 로그·원본은 `~/Library/Mobile Documents/iCloud~com~taption~plan/Documents/TaptionLogs/`(`latest.json`)에 올라옵니다. 분석용 복사본은 `build/validation/<요청 ID>/`에 둡니다.

## 문서

- 남은 일은 `temp.md` 맨 위 `남은 액션아이템`(대표 실기기 확인 / 코드로 할 일 / 보류·외부 대기)에 있습니다. 요청 ID로 찾아 그 항목만 읽습니다.
- 검증 근거는 `test.md`(2026-11-01 이후와 남은 요청), 이전 기록은 `test_ARCHIVE.md`입니다.
- 코드 위치·규칙·함정은 `DEVELOPMENT.md`(「프로젝트 경계」「판정 규칙」「화면 규칙」「자주 걸리는 함정」)에 있습니다.

## 11-06 ~ 11-08에 바뀐 것 (실기기 확인 전)

| 요청 ID | 내용 |
|---|---|
| BRK1106A01 · PLY1106A01 | 회사 근무 중 휴식을 폰 화면·자세로 판정하고, 재생 말풍선을 「회사에서 업무·휴식·걷기」로 |
| SUB1106A02 · REV1107A02 | 지하철 지도 선이 OSM 실제 선로를 따름(`SubwayTrackCatalog`, 생성 `scripts/subway-tracks/build.py`), 좌표 없는 역을 OSM 위치로 채움 |
| RNG · CTR1107A01 | 사진링은 밖을 탭하면 집 위 반달로 접히고 누르면 펼침, 화랑이를 누르면 카운터 보이기·숨기기 |
| REV1107A02 | 넓은 화면(아이패드·듀오) 메뉴·달력을 한 열 스크롤로 |
| SRC1107A01 | 지도 검색 결과 목록, 등록 장소·지하철역 찾기, 실패 안내 |
| NTF1107A01 | 센서 수신 때 뜨던 「센서 기록 확인」 알림 없앰 |
| PRF1101A01 · RFT1107A01 | 영상 렌더러 조회 자료 공유, 거리 계산 사본 정리(`PlanarDistance`), 재생 투영 파일 분리 |
| GOO1104A01 | 구글 `calendar.readonly` 데이터 액세스 인증이 2026-11-08 승인됨 — 경고 없이 연결되는지 기기 확인 필요 |

## 대표 결정 (바꾸지 않습니다)

- 업무 휴식은 폰 화면·자세로 판단합니다(사용시간 권한 쓰지 않음).
- 지도가 가려져도 포그라운드 GPS를 끄지 않습니다(기록 촘촘함 우선).
- 센서 수신은 알림으로 알리지 않습니다.
- 활동 판정·표시는 장소 → 대분류 → 상세 순서. Watch 앱은 백그라운드와 시계 페이스 중심, 설정은 iPhone.
- 백업 비밀번호는 6자리이며 강화를 제안하지 않습니다.
- IAP 판매·심사 제출은 보류입니다.

## 바로 할 만한 일

1. 대표 기기에서 구글 캘린더를 다시 연결해 경고 화면이 없고 일정이 들어오는지 확인합니다(GOO1104A01·CAL1104A02).
2. `temp.md` 「코드로 할 일」에서 실기기 없이 할 수 있는 것: OPT1102A01(발자국 레이어 패치 다시 쓰기), REV1026A01(아이패드 시뮬레이터 UI 시험 실제 통과).
3. 실기기 재현이 필요한 것: SBN1102A01(구글 아이콘 말풍선), CTR1103A02(애플 지도 카운터 흔들림).

## 함정

- 동결 파일(`docs/architecture-baseline.json`)은 줄 수가 늘면 구조 검사가 실패합니다. 커밋 전에 `--check`. 파일을 줄였으면 예산도 낮춥니다.
- `release.sh`는 깨끗한 작업 트리를 요구하고, 올린 빌드 번호 변경은 직접 커밋합니다. 시간 제한을 걸지 말고 백그라운드로 돌립니다.
- 지하철 지도 선은 역 사이를 선로 모양으로 잇습니다. 시험 기대값을 역 좌표 수로 두면 틀립니다.
- `MapHomeStickmanTests.testScarfAndRibbonStayOnTheBodyInEveryScene`·센서 분석 시간 시험은 가끔 시간 초과로 실패합니다. 단독 재실행으로 확인합니다.
- 공개 저장소에는 메일, 계정 이름이 든 주소, 공개 링크를 적지 않습니다.
