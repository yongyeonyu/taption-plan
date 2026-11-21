---
id: 20261121-1409-ci-failure-review
created_at: 2026-11-21T14:09+09:00
status: blocked
title: main CI 5회 연속 실패 원인 검토
from: 비야
basis: 대표 직접 지시 (2026-11-21 통화)
---

## 할 일

1. main 브랜치 CI가 2026-11-21 오전에 5회 연속 실패했습니다. 아래 실행들의 Actions 로그를 읽고 실패 원인을 잡별로 확인합니다.
   - `e7e3a0a` (09:31) — app-tests 실패
   - `b879159` (09:45) — 실패 (relay 성공)
   - `88863f2` (09:53) — packages 실패 (relay 성공)
   - `6732020` (09:54) — packages 실패
   - `efd44de` (10:24, 최신) — app-tests 실패(2분 54초), packages 실패(1분 17초), app 실패(1분 59초) / relay 성공(27초), architecture 성공(12초)
2. 실패가 이미 알려진 항목(`TravelModeView` actor 격리, `DayStoreV3Tests` 간헐 실패)인지, 새로 생긴 문제인지 구분합니다. 최신 커밋 `efd44de`(도시 팩 1·2단계 첫 조각, ARCH1120A01)와 관련이 있는지도 봅니다.
3. 이번 지시는 검토까지입니다. 수정하지 말고, 원인·영향 범위·권장 수정안을 `## 클로드 코드 회신`에 적습니다. 수정이 필요하면 대표에게 객관식으로 묻습니다(AGENTS.md 9절).

## 확인 기준

- 5회 실행의 실패 잡·실제 오류 메시지를 로그에서 확인했습니다.
- 알려진 실패와 새 실패를 구분했습니다.
- 회신에 원인·권장 수정안·대표 확인이 필요한 선택지가 있습니다.

## 하지 말 것

- 코드 수정·파일 삭제·서버 배포·TestFlight 업로드(검토 지시입니다).
- AGENTS.md 4절 「대표 결정」 변경.
- 이미 실패 중인 항목을 이 지시 없이 건드리기.

## 참고

- 최신 실행: https://github.com/yongyeonyu/taption-plan/actions/runs/44849675784
- main HEAD: `efd44decefeb9e3c7182ada0a5af0e5a5c491f36`

## 클로드 코드 회신

- 처리: 검토 완료(코드 수정 없음). 수정은 대표 객관식 확인 대기라 문서를 `done/`으로 옮기지 않고 `status: blocked`로 둠.
- 요청 ID: CIF1121A01 · 시작·끝: 2026-11-21 14:20 ~ 14:40 (KST)
- **읽은 것**: GitHub Actions 실행 5건(`e7e3a0a`·`b879159`·`88863f2`·`6732020`·`efd44de`)의 잡별 결과와 `gh run view --log-failed`의 오류 줄. 최근 80회 실행 목록(80회 중 성공 0회, 마지막 한 건은 진행 중).
- **5회 모두 같은 세 잡이 실패**, `relay`와 `architecture`는 매번 성공:

| 잡 | 오류(로그 그대로) | 알려진 항목? |
|---|---|---|
| `packages` | `DayStoreV3Tests.testConcurrentColdOpensInitializeOneV3Schema` 실패(`database(...)`, `database is locked` 계열) | **알려진 간헐 실패**(`test.md` 126·127행). 11-20 오전 실행(`3df08a0`)에도 같은 줄(68행) |
| `app` | `Packages/SeasonPackKit/.../Render/SeasonPackTreeEffects.swift:124:68`·`:127:16` `cannot convert return expression of type '(CGImage, Double)' to return type '(image: CGImage, side: CGFloat)'` | **새 실패(제 회귀)** |
| `app-tests` | 위와 같은 `SeasonPackTreeEffects.swift` 컴파일 오류 → `Testing cancelled because the build failed` | **새 실패(같은 원인)** |

- **새 실패의 원인(확인함)**: LAG1120A01(눈꽃송이 스프라이트, 커밋 `88e07008`·2026-11-20 20:27 KST)에서 제가 넣은 `SeasonPackSnowSprites.sprite(index:config:)`가 `side`(= `(flake.size * 1.4).rounded(.up) + 6`, **Double**)를 반환형 `(image: CGImage, side: CGFloat)` 튜플에 그대로 담습니다. 이 맥의 Xcode 27.2는 튜플 안의 Double→CGFloat 암묵 변환을 받아 주지만 CI 러너의 Swift는 받아 주지 않습니다. 그 결과 `SeasonPackKit`이 컴파일되지 않아 앱 두 잡이 맨 앞에서 멈춥니다(앱·시험이 거기서 끝나서 그 뒤의 오류는 보이지 않음).
- **알려진 실패와의 관계**: 11-20 오전(LAG 이전)의 `app`·`app-tests`는 `TravelModeView.swift:995:113 cannot call value of non-function type 'TravelPlanTableModel'`(알려진 항목, 대표 지시로 미수정)로 실패했습니다. 지금은 SeasonPackKit 오류가 먼저 나서 **그 알려진 오류가 가려져 있고**, SeasonPackKit을 고쳐도 같은 잡들이 `TravelModeView`로 다시 실패할 가능성이 큽니다(추정: 로컬 Xcode 27.2에서는 그 줄이 통과해 직접 재현하지 못함).
- **최신 커밋 `efd44de`(ARCH1120A01)와의 관계**: **없음(확인함).** 이 커밋의 변경은 카드 모델 칸·시드 생성기·팩 모델·시험이고, 로그의 어떤 오류도 그 파일을 가리키지 않으며 로컬에서 전체 시험이 컴파일·통과했습니다. 5회 실패의 원인은 모두 `88e07008` 이후 같은 SeasonPackKit 오류입니다.
- **영향 범위**: CI가 최근 80회 연속 실패(성공 0)라 **CI가 회귀를 잡아 주지 못하는 상태**입니다. 이번 SeasonPackKit 오류는 TestFlight 빌드(로컬 Xcode)에는 영향이 없었습니다. 그러나 다른 도구체인에서는 앱이 컴파일되지 않을 수 있는 실제 호환성 결함입니다.
- **권장 수정안**:
  - **A. SeasonPackKit 두 곳**(제 회귀): `return (hit, CGFloat(side))`·`return (image, CGFloat(side))`로 명시 변환(2줄, 동작 변화 없음). 같은 파일의 시험·패키지 시험은 그대로 통과해야 하며 수정 뒤 `swift test --package-path Packages/SeasonPackKit`과 로컬 전체 시험으로 확인.
  - **B. `TravelModeView.swift:995`**: 알려진 actor 격리·이름 충돌 오류(`cannot call value of non-function type 'TravelPlanTableModel'`). 대표 지시로 손대지 않던 항목이라 **대표 승인이 필요**합니다.
  - **C. `DayStoreV3Tests` 동시 열기 간헐 실패**: v3 초기화에 busy timeout·초기화 락을 넣어 제품 쪽을 안정화하고 시험을 고정(대표 승인 후).
  - **D. CI 개선**: 실패 잡이 SeasonPackKit에서 멈추면 이후 오류가 가려지므로, 수정 뒤 한 번에 `app`을 다시 돌려 남은 오류를 확인.
- **대표 확인이 필요한 선택지(객관식, 아침에 묻겠습니다)**:
  1. A만 즉시 수정(추천, 제 회귀·위험 없음) / A+B / A+B+C / 수정하지 않음.
  2. 수정 뒤 TestFlight 360 이후 빌드에 포함할지, 다음 릴리스로 미룰지.

- **후속(대표 지시: SeasonPackKit 두 줄만)**: `SeasonPackTreeEffects.swift` 반환 두 곳을 `CGFloat(side)`로 명시 변환. `swift test`(SeasonPackKit) 113건 통과. `TravelModeView`·`DayStoreV3Tests`는 손대지 않음. CI 재실행 결과 확인 대기.
