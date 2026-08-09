# Design QA

- Source visual truth: `/Users/u_mo_c/Downloads/스크린샷, 2026-08-09 21.49.46.png`
- Source viewport: 1179 x 2556
- Implementation capture: `/tmp/taption-plan-after-onboarding.png`
- Implementation viewport: 2048 x 2732 (iPad simulator, iPhone compatibility mode)
- Required state: 기록 > 일, 자동 기록 데이터와 범례가 채워진 상태

## Fidelity surfaces

- 범례 항목을 고르면 같은 색의 일과·활동 구간만 강조한다.
- 선택하지 않은 구간과 범례 항목은 낮은 불투명도로 남긴다.
- 범례 밖 버튼을 누르면 선택이 해제되어 전체 색이 복원된다.
- 일과, 활동, 수면 단계와 이동수단은 서로 구분되는 현대적인 색을 사용한다.

## Findings

- [P1] 시뮬레이터에 실기기 자동 기록 데이터가 없어 첨부 화면과 동일 상태의 시각 비교를 완료할 수 없다.
- 선택·해제 정책과 팔레트 고유성은 코드 및 자동 테스트로 확인했다.
- 글꼴, 간격, 링 크기와 기존 레이아웃은 변경하지 않았다.

final result: blocked
