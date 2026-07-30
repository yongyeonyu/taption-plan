# Taption Plan

계획과 실제가 함께 움직이는 개인용 간트차트 iPhone 앱입니다.

## 현재 상태

- SwiftUI 기반 iPhone 프로젝트
- `일 · 주 · 월 · 년` 시간표
- `시간표 · 목표 · ＋ · 회고 · 설정` 하단 메뉴
- SwiftData 기반 계획 모델과 상·하위 목표 관계
- 계획 추가 시트
- UI 기획 원본: `plan.md`
- 브라우저 목업: `ui-draft-iphone.html`

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
