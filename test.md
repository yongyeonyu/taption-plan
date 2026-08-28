# Taption Plan 실기기 검증 큐

구현·빌드·업로드·설치·실행·실제 화면 터치는 서로 다른 게이트로 기록한다. 설치·실행만으로 UI 동작을 완료 처리하지 않는다.

## 2026-08-28 실행 기록

- generic iOS Debug build: 성공
- generic iOS `build-for-testing`: 성공
- iOS Simulator: 사용 가능한 기기 없음
- iPhone 14 Pro 서명 Debug build/install/launch: 성공
- iPhone XCTest 전체: 775건 중 773건 통과, 2건 실패
- iPhone XCTest 대상 변경: `MapHomeStickmanTests` 13건 + 근방 후보 삭제 회귀 1건, 14건 모두 통과
- 전체 XCTest 실패 원인: 저장소에 없는 `TaptionPlan/Localizable.xcstrings`와 `.cat-visual-check/cat_sheet_x4.png` fixture
- iPhone 미러링: 기기가 사용 중이라 잠금 전 연결 시간 초과, 화면·터치 readback 미검증
- iPad Pro 12.9-inch 서명 Debug build/install/launch: 성공, `com.taption.plan` `1.0 (107)` readback
- iPad 대상 회귀 XCTest: 교통 후보 6건 + MapLibre viewport 최종 flush 1건, 7건 모두 통과
- Release build `1.0 (108)` archive/export/upload: 성공, App Store Connect processing `제출 준비 완료`
- `TP Taption Plan 내부 테스트` 그룹: build `1.0 (108)` 연결·`테스트 중`·iOS 노출 readback 성공
- iPad TestFlight 직접 설치: Distribution IPA의 Beta entitlement 제약으로 미완료; iPad에는 서명 Debug `1.0 (107)`만 설치·launch됨

## STK828M5Q2 · BCH828STK1

- 신규 기능: 하단 스티커 메뉴 복구, `전부 보기`/`해당되는 것만 보기` 지도 메모 필터, 지도·일정 스티커 추가, 스티커 모드 편집·삭제
- 신규 회귀 XCTest: `MapHomeStickmanTests` 16건 중 신규 3건 포함 전체 통과
- iPad Pro 12.9-inch 서명 Debug `1.0 (108)` 설치·실행 readback: 성공
- Release `1.0 (109)` archive/export/upload: 성공, Delivery UUID `f363e054-23cd-483a-89ba-3d981792f515`
- App Store Connect processing: `제출 준비 완료`
- `TP Taption Plan 내부 테스트`: build `1.0 (109)` 연결·`테스트 중`·iOS 노출 readback 성공
- iOS Simulator: 사용 가능한 기기 없음; 지도 스티커·메모 실제 화면·터치는 별도 미검증

## REL28TRN01 · test.md 전체 실행 후속

- iPhone 14 Pro 서명 Debug `1.0 (109)` 설치·실행 readback: 성공
- Apple Watch SE 서명 Debug `1.0 (109)` 설치·실행 readback: 성공
- iPhone 전체 XCTest: 783건 중 781건 통과, 2건 실패
- iPad Pro 12.9-inch 전체 XCTest: 783건 중 781건 통과, 2건 실패
- 실패 2건: 저장소에 없는 `TaptionPlan/Localizable.xcstrings`, `.cat-visual-check/cat_sheet_x4.png` fixture
- HealthKit·Watch·지도·스티커 관련 단위/통합 테스트: 전체 실행 범위에서 통과
- iPhone 미러링: iPhone 잠금 전 연결 시간 초과 상태로 실제 화면·터치 readback 미완료
- 지도·교통·스티커·Dynamic Island의 실제 화면·터치, HealthKit 권한/원본, Watch 지연 동기화, IAP 외부 계약·Sandbox 구매는 외부/수동 게이트로 남김

## TRN828Q7A1 · BUG28P9K3X · DEL28Q9M4X

- 대상: iPhone 14 Pro 및 연결 가능한 iPad, 최신 검증 빌드
- 지도 후보: 3분 미만은 미표시, 3분 이상은 `?` 표시
- 후보 메뉴: 지하철·버스·기차·비행기·배 탑승 선택과 삭제 버튼을 실제 터치
- 삭제: 100m 이내의 같은 체류 구간 또는 5분 이내 인접 체류 후보를 종류·POI ID와 관계없이 한 번에 숨김
- 보존: 등록 교통 위치·원본 GPS·이미 확정된 이동 기록이 삭제되지 않음
- 재실행: 삭제 결정이 저장 후 재실행에도 유지됨
- 지도 경로: Apple MapKit과 MapLibre에서 후보 표시·탭·삭제를 각각 확인
- 상태: 컴파일·실기기 대상 XCTest 완료 · Simulator/실기기 화면·터치 대기

## MAP828R5K2

- Apple 지도와 MapLibre 제공자 전환을 실제 터치
- MapLibre 4개 스타일과 오버레이·경로·플레이어 위치를 확인
- 지도 검색·줌·팬·사이드바 가림 및 접근성 라벨을 확인
- 상태: 코드 검증·실기기 대상 XCTest 완료 · 실기기 화면·터치 대기

## HLTH28P7Q4 · SLEEP827B2

- iPhone HealthKit 권한 시트와 유형별 권한 결과를 readback
- 전체 이력 진행률·원본 건수·source/device provenance를 확인
- 페어링 Apple Watch 데이터의 지연 도착·백그라운드 observer·재실행 anchor 증분을 확인
- 2026-08-27 07:15 전후 수면 원본과 걸음·화면 사용 시각을 대조
- 확인되지 않은 휴대폰 터치 시각을 수면 종료로 추정하지 않음
- 상태: 코드 검증·실기기 대상 XCTest 완료 · 실기기 HealthKit/Watch readback 대기

## NXT27AUG01 · IAP73PAID1

- Dynamic Island compact/expanded 센서 실시간 화면 확인
- 재생·사이드바·졸라맨 최전면·지하철 확정/예상 경로 확인
- `NEXT_CHAT_PROMPT.md`의 커밋·빌드·기기·TestFlight 상태를 최신 readback으로 갱신
- Paid Apps Agreement·세금/은행·상품 연결·Sandbox 구매/복원 전까지 IAP 게이트 미완료
- 상태: 인계 문서 갱신 완료 · 실기기 화면·터치 및 IAP 외부 게이트 대기
