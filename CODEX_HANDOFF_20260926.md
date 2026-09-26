# TaptionPlan 별도 채팅 인계 프로토콜 — SEP0926A01

이 문서를 받은 채팅은 TaptionPlan만 담당한다. ShotGuide는 원래 채팅에서 진행하므로 ShotGuide 저장소를 수정·정리·빌드·커밋·push·배포하지 않는다.

## 작업 경계
- 저장소 및 시작 디렉터리: `/Users/u_mo_c/Documents/taption plan`
- 원격: `https://github.com/yongyeonyu/taption-plan.git`, 브랜치 `main`.
- 구현: `TaptionPlan/` 및 관련 패키지·Watch·Widget. 테스트: `TaptionPlanTests/` 및 관련 패키지 테스트.
- 로컬 `AGENTS.md`, `temp.md`, `test.md`를 기준으로 요청 ID에 해당하는 구간만 확인한다.
- TestFlight 그룹은 `TP Taption Plan 내부 테스트`다. 처리 완료 후 그룹 연결 및 실제 그룹 화면의 빌드 노출 readback 전에는 배포 완료로 보고하지 않는다.

## 2026-09-26 확인된 상태
- main `c5e9dbb`까지 push, 서버 main 일치 및 워크트리 clean 확인 완료. 기존 인계의 미push 주장은 이 기준점으로 대체한다. 본 문서는 이후 작성한 신규 파일이므로 다음 채팅에서 Git 상태를 다시 확인한다.
- `520075e`: 문자열 카탈로그·설정·기존 인계·검증 기록 보존. `c5e9dbb`: 다른 채팅에서 추가된 HOF0926A01 인계 확인 요청 보존. 이 요청은 해당 담당 채팅이 판정하며 완료로 추정하지 않는다.
- 앱타깃 Debug BUILD SUCCEEDED: `build/validation/GIT0926P01/build-final.log`. Git push/readback: 같은 폴더 `git-readback.txt`.
- 초기 빌드는 디스크 부족으로 실패했다. 재생성 가능한 빌드 캐시 정리 후 재실행 통과. 소스·검증 결과·배포 archive/export는 보존했다.
- `.kiro/settings/.kirocrew-cli-settings.lock`은 로컬 `.git/info/exclude`로 제외하고 파일은 보존했다.
- 실기기 기능 검증과 신규 TestFlight 배포를 수행했다는 뜻은 아니다.

```sh
xcodebuild build -project TaptionPlan.xcodeproj -scheme TaptionPlan -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath build/ArchiveDD -skipPackagePluginValidation COMPILER_INDEX_STORE_ENABLE=NO OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox'
```

## 작업별 상태
- MENU0926S02: 비주얼 정리 완료(`5fef990`). 메뉴 구성·동작 보존. 다시 단순화 수준을 결정 대기로 돌리지 않는다.
- CATM0926A04: 대분류 화랑이 동작 순환 구현(`79c514f`). FMAP0926R06: 경로 projection 진단 계측(`7fddb72`), 실기기 로그 대기.
- 후속 UI 커밋: `be21e9c` 지도 제스처 통과, `9509cb1` 달력 아이콘 이동, `1e283ec` 탐험 HUD 하단 이동·시간 사이드바 배경. 이전 상단 HUD 설명을 현재 위치로 단정하지 않는다.
- HUD0926M08: 하루 요약 통합 방식은 여전히 결정 대기. HUD 위치 이동 완료와 별개다. 재개 시 탭 확장/인라인/시트 등 번호 선택지와 예시로 확인한다.
- PAW0926T05: 발자국 코드 수정 완료, 이동 기록 재생 실기기 확인 대기.
- GAME0926R03: 육각 격자 방식은 사용자 원복 지시로 폐기. 새로운 RPG 방향은 결정 후 진행한다.
- GPS0922J01, SLP0922S01, BAK0922I01: 수정·테스트 기록은 있으나 실기기 위치/수면/백업 결과 대기. 해당 temp.md 구간과 실제 로그로 판정한다.
- RST0920A01/MIG0921A01=V4 분리, BKC0920A01=CloudKit CAS, BRT0920A01=최근 10개 generation 및 참조 보호, PKG0920A01=host 주입은 이미 결정된 방향이다. 구현 완료 여부는 코드·테스트로 재대조한다. 특히 BRT는 기존 커밋과 temp.md 계획이 다를 수 있어 미착수 또는 완료로 단정하지 않는다.
- 포맷·스키마·백업·App Group 변경은 원본 및 기존 경로 보존, 회귀 통과가 필수다. 대량 미검증 커밋을 만들지 않는다.
- IAP905G002/IAP907A001 판매 작업은 별도 재개 요청 전까지 보류한다.

## 다른 채팅에서 시작할 프롬프트

> 이 채팅은 TaptionPlan 전용입니다. `/Users/u_mo_c/Documents/taption plan/CODEX_HANDOFF_20260926.md`와 이 프로젝트 AGENTS.md를 읽고, git status 및 최근 커밋과 temp.md의 관련 요청을 대조해 이어받으세요. main c5e9dbb까지 push와 앱타깃 빌드 검증을 완료한 상태가 기준점입니다. ShotGuide는 다른 채팅 담당이므로 조작하지 마세요. 완료된 메뉴 정리와 HUD 위치 이동을 재구현하지 말고, 실기기 로그 대기·결정 대기·검증 가능한 구현을 구분해 요청 목록에 정리하세요. 다음 실행 요청은 이 채팅에서 별도로 받습니다.

## 운영 규칙
- 이 문서는 작업 인계와 범위 구분을 위한 기준이다. 현재 사용자의 지시와 해당 프로젝트 AGENTS.md를 우선한다. 오래된 인계 문서의 push 대기·빌드 불가 주장을 현재 사실로 사용하지 않는다.
- 새 요청에는 영문·숫자 10자리 ID를 부여하고 해당 저장소 temp.md에 원인·해결방안·검증 기준을 먼저 기록한다. 완료 근거는 test.md에 남기고 완료 항목만 temp.md에서 제거한다. 기존 요청 ID는 추적을 위해 유지한다.
- 요청을 모아 우선순위를 정리하고, 사용자가 ㄱㄱ/전체진행을 요청하면 계획을 정리한 뒤 승인된 범위를 실행한다. 애매한 기능·UI 선택은 예시와 번호 선택지로 확인한다. 이미 확정된 결정은 다시 묻지 않는다.
- UI/UX를 임의로 바꾸지 않는다. 임시 브랜치를 만들지 않으며, 기존 사용자 변경과 다른 채팅의 진행 중 변경을 보존한다. 다른 채팅의 문서 변경을 임의로 완료 처리하지 않는다.
- 하위 에이전트 SOL 모델 및 고속 사용 금지. 요청 범위 밖의 삭제·초기화·외부 전송을 하지 않는다. 휴지통 전체 비우기는 작업 정리로 간주하지 않는다.
- 코드 변경은 앱타깃 BUILD SUCCEEDED와 필요한 회귀 검증 후 커밋한다. parse/build/install만으로 실기기 기능을 통과 처리하지 않는다.
- 고정 DerivedData를 재사용하고 디스크 여유를 먼저 확인한다. 실패 시 관련 오류 근처만 읽고, 기록·캐시·DerivedData·보관 산출물을 재귀 검색하지 않는다. 유효한 기존 검증은 재사용한다.
- 빌드와 실기기 검증, Git push, TestFlight 배포를 구분한다. 2026-09-26 정리·push 요청은 완료되었으며 이 문서 자체가 새 배포 요청은 아니다.
- 다른 프로젝트의 파일·Git·기기 설치·배포·로그를 이 채팅에서 조작하지 않는다. 교차 프로젝트 작업이 필요하면 사용자에게 해당 프로젝트 채팅으로 전달할 내용을 제공한다.
- 한국어는 존댓말로, 완료 보고는 결론을 간결하게 쓰고 명령·산출물·제한은 검증 기록에 남긴다.
