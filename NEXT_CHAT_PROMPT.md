# Taption Plan 다음 채팅 핸드오프

아래 내용을 새 채팅에 그대로 붙여넣고 작업을 이어가세요.

```text
작업 디렉토리: /Users/u_mo_c/Documents/taption plan
먼저 AGENTS.md를 읽고 main 최신 SHA와 git status를 확인한다.

현재 기준
- 현재 main에는 사용자 추가 지하철역·지하철 Wi-Fi 우선 판정, GPS 1초·10초·30초 기록, 지도 상세도·팝업·시간 레일 개선, 광고 완전 제거, C2 고양이 벡터 앱 아이콘이 반영되어 있다.
- `BATCH2WK01`로 지도 오버레이 핀치 전달·위치 추가 취소·저장 위치 이동/편집·사용자 위치 관리 UI·실제 헤딩 나침반·선택 날씨 배경을 통합했고 CloudKit 비공개 복구 백업의 아카이브 키 래핑을 보정했다.
- Pro는 Keychain+iCloud KVS 기반 14일 앱 자체 체험과 StoreKit 2 비소모성 `com.taption.plan.pro` 영구 구매·복원으로 구현했다. 기존 기록도 `startedAt` 기준 14일로 재계산하며, 체험 만료 시 전체 앱과 백그라운드 작업을 잠근다.
- build 77 다방면 리뷰에서 1초 GPS 경로의 O(N²) 비용과 재생 중 오버레이 재계산, 시간 경계, 지도 입력 좌표계, 잠금 외부 노출, iCloud 복구키 fallback, PIN KDF·난수 실패와 영어 접근성 문구를 보정했다.
- 전체 XCTest 576/576, 정적 분석, 전 타깃 Debug와 Release archive/export를 통과했다. iPhone 14 Pro에는 직전 1.0(76)이 설치되어 있고 build 77 Debug 설치는 기기 잠금으로 개발자 이미지 마운트가 거부됐다.
- build 77 TestFlight Delivery UUID는 f962c2b8-f430-44e0-88a8-0a00b7b489c4이고 처리 상태는 VALID/제출 준비 완료다.
- build 77은 `TP Taption Plan 내부 테스트` 그룹에 연결되어 API 관계와 App Store Connect 실제 화면 모두에서 노출된다.

남은 외부 게이트
- App Store Connect Paid Apps Agreement가 `신규` 상태다. 계정 소유자가 법인 정보와 계약·세금·은행 정보를 완료해야 실제 US$0.99 상품을 생성할 수 있다.
- 계약 완료 후 App Store Connect에 비소모성 상품 ID `com.taption.plan.pro`, 가격 US$0.99, 한국어·영어 현지화를 만들고 TestFlight에서 구매·복원을 검증한다.

주의
- TestFlight 업로드 성공, 처리 VALID, 내부 그룹 연결·노출은 서로 다른 게이트로 계속 확인한다.
- 원본 센서·HealthKit 데이터는 삭제·수정하지 않는다.
- StoreKit 상품이 생성되기 전에는 TestFlight 구매 버튼 성공을 완료로 보고하지 않는다.
- 새 요청은 temp.md에 10자리 ID로 등록하고 대표님의 `ㄱㄱ` 후 실행한다.
```
