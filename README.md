# Taption Plan

계획과 실제가 함께 움직이는 개인용 간트차트 iPhone 앱입니다.

## 현재 상태

- SwiftUI 기반 iPhone 프로젝트
- Map Home 중심 화면과 시간 레일 기반 기록 탐색
- `시간표 · 목표 · ＋ · 회고 · 설정` 하단 메뉴
- SwiftData 기반 계획 모델과 상·하위 목표 관계
- 계획 추가 시트
- iPhone·Apple Watch 고도 보정 및 층수 캘리브레이션
- 국내 지하철 역·노선·환승 기반 이동 판정과 Apple 지도 경로 표시
- 확대 시간 레일의 고정 플레이헤드·시간별 지도 위치 갱신
- 과거 날짜 종료 시각까지의 누적 GPS 경로 투영
- Face ID 인증 중 시스템 생명주기 전환에 따른 재잠금 루프 방지
- `TimeScaleTests`, `RouteTimelineDataTests`, `SecurityBackupCoreTests` 선택 테스트와 Debug 빌드 검증
- iPhone 14 Pro 설치·실행 검증 완료
- UI 기획 원본: `plan.md`
- 브라우저 목업: `ui-draft-iphone.html`

구현 세부와 검증 명령은 [`DEVELOPMENT.md`](DEVELOPMENT.md)에 기록합니다.

## 실행

1. `TaptionPlan.xcodeproj`를 Xcode에서 엽니다.
2. iPhone Simulator를 선택합니다.
3. `TaptionPlan` 스킴을 실행합니다.

명령줄 빌드:

```sh
xcodebuild \
  -project TaptionPlan.xcodeproj \
  -scheme TaptionPlan \
  -destination 'generic/platform=iOS Simulator' \
  build
```

## 개발 순서

1. iPhone 기본 간트차트
2. Apple Watch·HealthKit 실제 기록
3. iPad
4. Mac
