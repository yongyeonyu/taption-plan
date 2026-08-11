# Taption Plan 다음 채팅 핸드오프

아래 내용을 그대로 붙여넣고 작업을 이어가세요.

```text
작업 디렉토리: /Users/u_mo_c/Documents/taption plan
먼저 AGENTS.md를 읽고 규칙을 따른다. 현재 main 브랜치의 최신 커밋과 git status를 먼저 확인한다.

이번 작업에서 반영된 내용
- iPhone·Apple Watch 고도/층수 보정: CLFloor 안정화, GPS 정확도·기압·상대고도·계단 근거 결합
- Apple Watch 상대고도를 altimeterSessionID 단위로 분리해 세션 간 값 혼합 방지
- 등록 장소의 기준 층은 고정하고 실제 층 이동만 파생값으로 계산
- 국내 도시철도 역·노선·환승 카탈로그와 역 좌표 경로 추가
- 역 순서 + 지하 하강/GPS 약화 + 걸음 수 + 워치 진동을 결합한 지하철 판정
- 마곡나루 → 검암(환승) → 가정 경로를 공항철도 → 인천2호선으로 계산하고 지도에 역 핀/경로 표시
- 원본 SensorReading/HealthKit 자료는 보존하고 파생값만 재계산
- 개발 문서: DEVELOPMENT.md, README.md, plan.md

검증 상태
- iOS Simulator 전체 테스트 통과
- iPhone 실기기 Debug 빌드 통과 및 bundleID com.taption.plan 설치 완료
- 실기기 실행은 잠금 상태라 launch 요청이 거부됨. 기기 잠금 해제 후 실행/화면/로그를 확인한다.
- Apple Watch 실기기 설치·센서 경로 검증은 아직 별도 확인이 필요하다.

다음 우선순위
1. iPhone 잠금 해제 후 앱 실행, 고도 보정과 지하철 경로를 실제 로그로 확인
2. Apple Watch 연결 상태에서 센서 세션 ID와 역 이동 경로를 대조
3. 실제 이동 로그에서 잘못된 역 근접/환승 판정이 있으면 원본은 건드리지 않고 분류 파생값만 보정
4. 수정 전후 관련 테스트와 Debug 빌드를 다시 실행하고, 사용자가 요청할 때만 TestFlight를 올린다.

주의
- 사용자 데이터나 원본 센서 파일을 삭제하거나 git reset --hard 하지 않는다.
- 자동 기록은 수정 불가로 유지하고, 사용자 편집은 파생 분류에만 적용한다.
- 월/년 시간표와 고빈도 제스처에서 전체 데이터를 매번 재계산하지 않는다.
```
