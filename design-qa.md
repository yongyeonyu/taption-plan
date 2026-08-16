# Design QA

## Existing record screen QA

- Source visual truth: `/Users/u_mo_c/Downloads/스크린샷, 2026-08-09 21.49.46.png`
- Source viewport: 1179 x 2556
- Implementation capture: `/tmp/taption-plan-after-onboarding.png`
- Implementation viewport: 2048 x 2732 (iPad simulator, iPhone compatibility mode)
- Required state: 기록 > 일, 자동 기록 데이터와 범례가 채워진 상태

### Fidelity surfaces

- 범례 항목을 고르면 같은 색의 일과·활동 구간만 강조한다.
- 선택하지 않은 구간과 범례 항목은 낮은 불투명도로 남긴다.
- 범례 밖 버튼을 누르면 선택이 해제되어 전체 색이 복원된다.
- 일과, 활동, 수면 단계와 이동수단은 서로 구분되는 현대적인 색을 사용한다.

### Findings

- [P1] 시뮬레이터에 실기기 자동 기록 데이터가 없어 첨부 화면과 동일 상태의 시각 비교를 완료할 수 없다.
- 선택·해제 정책과 팔레트 고유성은 코드 및 자동 테스트로 확인했다.
- 글꼴, 간격, 링 크기와 기존 레이아웃은 변경하지 않았다.

final result: blocked

## Map home visual QA

**Comparison target**

- Source visual truth: `/Users/u_mo_c/.codex/generated_images/019ff155-8ce7-7e83-908b-c33f87fe0ab2/exec-65cd3529-f8ed-47e1-a59f-ee1d8feee1b4.png`
- Implementation screenshot: `/tmp/taption-map-home-final.png`
- Combined comparison: `/tmp/map-home-design-compare-final.png`
- Source pixels: 853 × 1844. Implementation pixels: 1179 × 2556 (@3x, 393 × 852 pt).
- Normalization: both captures were height-normalized to 852 px for the combined comparison. Device status chrome is excluded from fidelity judgement because it is runtime-owned.
- State: light mode, day tab, dynamic current time, live simulator position; the simulator had no saved home coordinate, so the production rule correctly did not fabricate a home marker.

**Findings**

- No actionable P0, P1, or P2 mismatch remains in the app-owned map home surface.
- Expected provider variance: the reference uses an illustrated map base while the app renders live Apple MapKit tiles. Tile labels, roads, and POIs cannot be pixel-identical without changing map providers and supplying that provider's credentials. The app-owned overlay uses muted flat styling and excludes POIs to keep the same pastel hierarchy.
- [P3] Saved-home marker was source-verified but could not be rendered in the clean simulator data state. It uses the dedicated pastel house-and-tree asset only when a saved `home` place has a valid coordinate.

**Focused comparison**

- Header: one continuous white rounded bar, date jump controls, and calendar match the source structure and spacing rhythm.
- Time scale: centered three-way selector uses the source's pale-blue selected state instead of a saturated fill.
- Time rail: compact 24-hour vertical rail, time-ordered red current indicator, and lower-right three-control stack were tuned against the combined capture.
- Current location: one custom blue halo marker and `내 위치` label are rendered; the duplicate native annotation title was removed.
- Typography, color, imagery, copy: app-owned content uses the same dark ink, white material, pale blue selection, Korean labels, and generated pastel home marker art direction.

**Comparison history**

1. P2: the first implementation used a saturated selected time tab, an oversized rail, and a duplicate native current-location label. Fixed with the pale selected token, compact rail dimensions, and untitled custom annotations.
2. Post-fix evidence: `/tmp/taption-map-home-final.png`; no actionable P0/P1/P2 differences in app-owned UI remain.

**Implementation checklist**

- [x] Map-first root screen and hidden legacy shell
- [x] Dynamic date, day/week/month, location marker, 24-hour rail, and map controls
- [x] Data-driven home marker with no fabricated coordinate
- [x] Debug build and full test suite

**Follow-up polish**

- Validate the saved-home marker on a device that has a registered home coordinate.
- A pixel-identical map base requires an authorized alternate map-tile provider.

final result: passed

## Map home sidebar and Section Edit handle QA

**Comparison target**

- Source visual truth: `/tmp/codex-remote-attachments/019ff155-8ce7-7e83-908b-c33f87fe0ab2/9A23BB6A-3FC8-4AE3-9883-8765CE2BCCEF/1-붙여넣은-이미지-1.jpg`
- Source content crop: `/tmp/taption-side-handle-qa.Hp9bJU/reference-phone-crop.png`
- Implementation screenshot: `/tmp/taption-side-handle-qa.Hp9bJU/map-home-side-handle-final-3.png`
- Combined comparison: `/tmp/taption-side-handle-qa.Hp9bJU/comparison-final.png`
- Source crop: 472 × 982 px, normalized to 410 × 852 px. Implementation: 1179 × 2556 px (@3x, 393 × 852 pt), normalized to 393 × 852 px. The comparison aligns content height; device chrome and Android navigation differ by runtime and are excluded.
- State: map home, light mode, live current time, no saved simulator home or live GPS sample.
- The derived `/tmp/taption-side-handle-qa.Hp9bJU` captures were deleted after visual review; their paths remain as the recorded QA evidence.

**Findings**

- No actionable P0, P1, or P2 visual mismatch remains for the app-owned sidebar surface.
- The right edge uses one shared 24-hour time track: blue is the elapsed portion and dark gray is the remaining portion on the same vertical axis. The selected time is a dark two-line hour/minute block, with the current activity chip on its left.
- The activity chip and time block are wired to the Section Edit sheet; vertical dragging on the rail remains minute-snapped and frame-gated. The simulator capture verifies the visible state, while the physical tap path remains a follow-up device check.
- [P3] Map tiles, saved-home content, and ad creative vary by provider/runtime and were not used to judge sidebar fidelity.

**Focused comparison**

- Header: the menu/date/calendar bar remains one thin continuous strip and preserves 44 pt touch targets.
- Sidebar: the source’s single blue/gray time axis, right numeric column, and two-line current-time block are matched structurally. The implementation uses the app’s pastel blue and ink tokens.
- Typography, spacing, colors, image quality, copy: native rounded numerals and dark ink preserve legibility at the thin rail width; no source artwork was substituted for an app-owned UI asset.

**Comparison history**

1. P1: the first pass treated the side handle as a small floating control. Fixed with a full-height time track, a narrow numeric column, and a two-line time block.
2. P2: map labels competed with hour numerals. Fixed with a narrow translucent numeric-column backing.
3. P1: the initial implementation rendered blue elapsed time and gray handle as parallel rails. Fixed in RAILJOIN15 by sharing one X-axis and width, with blue above gray as one continuous track.
4. Post-fix evidence: simulator map-home capture reviewed after RAILJOIN15; no actionable P0/P1/P2 differences remain for the one-axis rail.

**Implementation checklist**

- [x] Thin numeric time rail
- [x] One-axis elapsed/remaining draggable time track
- [x] Two-line selected-time block and activity chip
- [x] Section Edit sheet trigger
- [x] 60 Hz drag gate and final-sample update preserved
- [x] Debug build and targeted tests

**Follow-up polish**

- Validate the Section Edit sheet tap path on a physical device with a real activity record.

final result: passed
