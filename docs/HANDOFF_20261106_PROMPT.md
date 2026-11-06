# 인수인계 프롬프트 (2026-11-06 밤)

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

- `main`을 `origin`에 push했고 워크트리·임시 브랜치는 없습니다.
- TestFlight 내부 그룹 최신은 289입니다(업무 휴식 판정, 잠긴 근무가 휴식을 덮던 문제 수정, 리팩터링). `test.md`의 TFB1106A07을 보세요.
- 시험은 실기기 iPhone 18 Pro Max(`00008160-000E195A1140000A`)로 합니다. 회사에서는 iPhone 11 Pro를 씁니다. 둘 다 `scripts/with-device-lock.sh`와 `-parallel-testing-enabled NO`로 돌립니다.
- 대표 iCloud 로그·원본은 `~/Library/Mobile Documents/iCloud~com~taption~plan/Documents/TaptionLogs/`(`latest.json`)에 올라옵니다. 분석용 복사본은 `build/validation/<요청 ID>/`에 둡니다.

## 문서

- 남은 일은 `temp.md` 맨 위 `남은 액션아이템`(대표 실기기 확인 / 코드로 할 일 / 보류·외부 대기)에 있습니다. 요청 ID로 찾아 그 항목만 읽습니다.
- 검증 근거는 `test.md`(2026-11-01 이후와 남은 요청), 이전 기록은 `test_ARCHIVE.md`입니다.
- 함정·문서 위치는 `DEVELOPMENT.md`의 「자주 걸리는 함정」「문서」 절에 모았습니다. 옛 인계문(`CODEX_HANDOFF*`, 11-05 프롬프트)과 `Code_review.md`는 지웠습니다.

## 오늘 바뀐 것 (모두 실기기 확인 전)

| 요청 ID | 내용 |
|---|---|
| MAP1106A01 | 지하철 회색 발자국은 GPS가 끊긴 미확정 구간에만, 사진링은 지도 탭으로 줄이고 2초 |
| WCH1106A02 | Watch 가속도 묶음 번호를 초 단위로(32비트 넘침으로 36분 뒤 수집 멈춤) |
| SUB1106A01 | 출발역 220m 안 집 체류를 지하철로 잡지 않고 역 120m 안에 들어온 때부터 탑승 |
| DIR1106A01 | 지하철·기차는 진행 방향으로 바로, 나머지는 0.3초 뒤 좌우 전환, 앞뒤 15초 창 방향 |
| BRK1106A01 | 회사 근무 안에서 화면 켜짐+손 떨림이 3분 간격 이내로 5분 넘게 이어지면 `휴식`으로 분할 |
| REV1106A01 | 예전에 잠긴 자동 `근무`가 새 휴식 조각을 덮던 문제 수정(사용자 수정 기록은 유지) |
| RFT1106A01 | 고정 ID 해시·구간 빼기·`unionDuration`·걷기 판정 사본을 공용 함수로 |

## 대표 결정 (바꾸지 않습니다)

- 업무 휴식은 폰 화면·자세로 판단합니다(사용시간 권한 쓰지 않음). 판독이 빈 시간은 휴식으로 잡지 않습니다.
- 지하철 탑승을 확정한 뒤에는 노선 선 + 실제 GPS 발자국. 회색은 끊긴 미확정 구간에만.
- 건강 기록 시작 제한은 새 설치에만, 건강 앱·Watch 기록에만 적용합니다.
- 활동 판정·표시는 장소 → 대분류 → 상세 순서. Watch 앱은 백그라운드와 시계 페이스 중심, 설정은 iPhone.
- 백업 비밀번호는 6자리이며 강화를 제안하지 않습니다.
- IAP 판매·심사 제출은 보류입니다.

## 바로 할 만한 일

1. 대표가 회사 하루를 보낸 뒤 올린 로그로 BRK1106A01 휴식이 실제로 잡혔는지 확인합니다(11-06 원본 재현: 12:55–13:04 한 건).
2. 집에서 Watch를 Mac에 연결해 시계 페이스 위젯 미노출(WCH1106A01)을 진단합니다. 절차는 `temp.md`의 WCH1106A01.
3. Watch 하루 착용 뒤 가속도가 iPhone `raw_events`에 끊김 없이 들어오는지(WCH1106A02).

## 함정

- 동결 파일(`docs/architecture-baseline.json`)은 줄 수가 늘면 구조 검사가 실패합니다. 커밋 전에 `--check`.
- `release.sh`는 깨끗한 작업 트리를 요구하고, 올린 빌드 번호 변경은 직접 커밋합니다.
- 자동 기록은 갱신마다 분류 잠금(`mergingLockedClassifications`)을 거칩니다. 새 자동 분할을 만들면 예전에 잠긴 자동 기록이 덮지 않는지 시험합니다(REV1106A01).
- `MapHomeStickmanTests.testScarfAndRibbonStayOnTheBodyInEveryScene`은 실기기에서 2분 넘게 걸려 가끔 시간 초과로 재시작됩니다. 단독 재실행으로 확인합니다.
- 공개 저장소에는 메일, 계정 이름이 든 주소, 공개 링크를 적지 않습니다.
