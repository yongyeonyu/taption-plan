# Taption Plan 다음 채팅 핸드오프

아래 내용을 그대로 붙여넣고 작업을 이어가세요.

```text
작업 디렉토리: /Users/u_mo_c/Documents/taption plan
먼저 AGENTS.md를 읽고 규칙을 따른다. 시작 시 main의 최신 커밋과 git status를 확인한다.

현재 기준
- 브랜치: main
- 번들 ID: com.taption.plan
- 확대 시간 레일: 플레이헤드 고정, 시간 축·세그먼트·경로 축 스크롤, 선택 시각의 저장 위치를 지도에 반영
- 과거 날짜: 하루 종료 시각까지 GPS 경로를 누적 투영
- 보안: Face ID 시스템 prompt의 inactive → active 전환으로 재잠금·재시도 루프가 발생하지 않도록 처리
- iPhone 14 Pro 설치·실행 확인 완료

검증 완료
- `TimeScaleTests`, `RouteTimelineDataTests`, `SecurityBackupCoreTests` 선택 테스트 통과
- iOS Debug 빌드 통과
- `com.taption.plan` 실기기 설치 및 실행 통과

다음 확인 항목
1. iPhone에서 확대 시간 레일을 드래그해 플레이헤드가 고정되고 지도 위치가 시간에 따라 갱신되는지 확인
2. 과거 날짜에서 원본 GPS 누적 경로가 지도에 표시되는지 확인
3. Face ID 성공 후 재시도 없이 앱에 진입하고, 실제 백그라운드 복귀 잠금은 유지되는지 확인
4. 수정 시 관련 테스트와 Debug 빌드를 다시 실행

주의
- 원본 센서·HealthKit 데이터와 사용자 변경값을 섞거나 삭제하지 않는다.
- 자동 기록 원본은 보존하고, 고빈도 제스처에서 전체 데이터를 재계산하지 않는다.
- 실기기 설치·실행과 TestFlight 업로드는 별도 검증 단계로 기록한다.
```
