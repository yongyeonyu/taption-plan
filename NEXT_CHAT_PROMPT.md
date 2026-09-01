# Taption Plan 새 채팅 재개 프로토콜

## 시작 지시

대표님을 존댓말로 응대하고 `/Users/u_mo_c/Documents/taption plan`에서 작업한다. 먼저 `AGENTS.md`, 이 파일, `temp.md`, `test.md`를 읽고 아래 명령으로 live 상태를 재확인한다.

```bash
git status --short --branch --untracked-files=all
git rev-parse HEAD origin/main
git ls-remote origin refs/heads/main
xcrun devicectl list devices
```

기억이나 이 문서보다 live 상태를 우선한다. 임시 브랜치는 만들지 않는다. 새 요청은 10자리 영숫자 ID로 `temp.md`에 원인과 해결 방안을 기록하고, 대표님의 `ㄱㄱ`/`전체 진행` 뒤에만 Luna 에이전트로 병렬 실행한다. SOL·고속 모델은 사용하지 않는다.

## 릴리스 정본

- 요청 ID: `REL901A001`
- 배포 소스 SHA: `9214a831184569a4acec2bde7dcc619808e0ec96`
- 소스 커밋: `[PAR32SEQ01] Tune weather and sidebar display density`
- 배포 당시 `main`, `origin/main`, 원격 `refs/heads/main`이 위 SHA로 일치했고 tracked worktree가 clean이었다. 이후 handoff 문서 커밋만 추가했다.
- 현재 `main` 커밋: `12f87ea` (`[REL901A001] Update build 125 handoff prompt`); 앱 바이너리의 소스 기준은 위 `9214a83`이다.
- 앱·iOS Widget·Watch 앱·Watch Widget: 모두 `1.0 (125)`.
- Release archive: `/tmp/taption-plan-TFB901A009-125.xcarchive`.
- Export IPA: `/tmp/taption-plan-TFB901A009-export/TaptionPlan.ipa`.
- 실기기 설치용 Debug 앱: `/tmp/taption-plan-REL901A001-device-derived/Build/Products/Debug-iphoneos/TaptionPlan.app`.
- IPA SHA-256: `aea26601881a6728ae0c16ab1f63dc500d225699bfb2bdf7902a71e3581ae086`.
- Delivery/build UUID: `6d55cdfb-7b7a-4be8-8657-481eb6ea5db6`.
- App Store Connect Apple ID: `6797370230`.
- Internal 그룹: `TP Taption Plan 내부 테스트`, ID `b4857e5e-d1ff-4bc2-b9ad-a69bcd4603fd`.
- 연결된 iPhone 14 Pro: `C44AF739-127D-572D-AD83-417C7E879045`.
- 연결된 iPad Pro 12.9-inch (6th generation): `4CEC6BE9-E528-52A1-AB94-654A6CDA7E5E`.

## 완료 증거

- 현재 `main`은 `12f87ea`이며 tracked worktree는 clean이다.
- `1.0 (125)` archive/export 성공, IPA의 앱·Widget·Watch 앱·Watch Widget 모두 `1.0 (125)`, Apple Distribution 서명 및 deep/strict codesign 검증 완료.
- altool 업로드 성공, App Store Connect API에서 build `125` `VALID`·`APP_STORE_ELIGIBLE` 확인.
- `TP Taption Plan 내부 테스트`에 build `125` 연결 완료; 그룹 빌드 86개와 내부 테스터 1명(`axony99@gmail.com`) readback 완료.
- TestFlight용 Beta 프로파일은 `devicectl` 직접 설치가 거부되어, 현재 `main`에서 개발용 서명 Debug 앱을 별도로 빌드해 설치했다. TestFlight 업로드 상태에는 영향이 없다.
- iPhone 14 Pro에 Debug `1.0 (125)` 설치·launch/readback 완료, 앱 프로세스 PID `19615` 확인.
- iPad Pro 12.9-inch (6th generation)에 Debug `1.0 (125)` 설치·launch/readback 완료, 앱 프로세스 PID `10757` 확인.
- 집중 지하철 회귀 6/6 통과: `/private/tmp/taption-rel901a001-rail-evidence-v4.xcresult`.
- 최종 전체 XCTest 876/876, 실패·skip 0: `/private/tmp/taption-rel901a001-final-full-v3.xcresult`.
- 두 역 차량 이동에서 `matchesRailRoute` 1회만 발생한 경우 지하철로 승격되던 경로를 차단했다. 두 역 sparse 복원은 철도 일치 최소 2회·25%를 요구하며, 세 역 이상 좌표 궤적과 Watch 진동·지하 신호 판정은 유지한다.
- P1 재감사 `P1R903A001`: CLOSED.
- iPhone 14 Pro `C44AF739-127D-572D-AD83-417C7E879045`에 `Taption Plan 1.0 (122)` 설치 readback, launch 성공, PID `14952` 확인.
- IPA의 네 번들 모두 `1.0 (122)`, Apple Distribution 서명, deep/strict codesign, Production iCloud, `beta-reports-active=true`, `get-task-allow=false` 확인.
- altool 결과: `BUILD-STATUS: VALID`, `IMPORT-STATUS: VALID`, `APP_STORE_ELIGIBLE`, `PROCESSINGSTATE: VALID`.
- App Store Connect API readback: build 122 `VALID`, Internal 그룹 관계에 build UUID 노출, 그룹 빌드 83개, 내부 테스터 1명.
- Chrome의 그룹 빌드 화면에서 `TP Taption Plan 내부 테스트 · 1명의 테스터 · 83개의 빌드`, build `1.0 (122) · 테스트 중 · iOS`를 readback했다. 테스터 화면에는 내부 테스터 1명이 노출됐고 현재 설치 표시는 `1.0 (121)`이다.

## 기능 변경 요약

- iCloud 월간 백업의 2026-08-31 00:00~12:28 KST 기록에서 09:31~10:06 지하철과 인천2호선·공항철도 경로를 확인했다.
- raw sensor 684건은 모두 iPhone source였고 Watch source·역 이름·철도 플래그가 없었다. 백업 존재와 Watch 실제 전달 성공은 별개다.
- 정적 지하철 카탈로그로 가정→검암→마곡나루 같은 세 역 이상 궤적을 복원하고 검암 체류 후보를 만들 수 있다.
- 예상경로 점선과 실제 재생선은 같은 fractional playhead/projection을 사용하고, 명시 이동과 겹치는 gap·동일 endpoint·시간 중복 forecast를 제거한다.
- Watch 가져오기는 요청 ID, transport, envelope, sensor/health decode, receipt 저장, 대기 해제 로그를 연결한다. 빈 health 응답도 receipt를 갱신한다.
- 유료 상품은 `com.taption.plan.pro`의 verified non-consumable 거래만 Pro로 인정하며, 상품 미조회 상태에서 가격을 추정 표시하지 않는다.

## 반드시 분리할 게이트

아래 항목은 서로 대체하지 않는다.

1. source/build/test 통과
2. `main`/원격 SHA 일치와 clean
3. iPhone 설치 버전 readback
4. 앱 launch/process readback
5. TestFlight upload와 Apple 처리 `VALID`
6. Internal 그룹 연결
7. 그룹 빌드 화면 및 테스터 화면 노출
8. 실제 지도 터치·재생선/점선 정합·역 후보 노출
9. Apple Watch 실제 envelope 수신과 `수신 대기 → 최근 수신` 전환
10. Paid Apps Agreement, IAP 생성, sandbox 구매·복원

## 다음 우선순위

1. iPhone 실제 화면에서 2026-08-31 오전 경로를 열고 검암 체류 후보, 가정→검암→마곡나루 지하철 예상경로, 점선과 졸라맨 재생선 정합을 직접 터치 검증한다.
2. Watch에서 `지금 가져오기`를 누르고 iPhone 설정의 `수신 대기`가 실제 envelope 뒤 `최근 수신`으로 바뀌는지 로그와 함께 확인한다.
3. Paid Apps Agreement 활성화 후 `com.taption.plan.pro`를 생성하고 sandbox 구매·복원을 별도로 검증한다.

## 실기기 공유 규칙

- iPhone 사용 전 Taption Cam `8/29 메인 개발` 작업에 슬롯을 요청하고, 종료 후 즉시 반환한다.
- 설치된 ShotGuide `1.0.0 (57)`과 데이터는 제거·초기화하지 않는다.
- 실제 화면·터치 또는 Watch 현장 증거가 없으면 자동 테스트·설치·실행 결과로 대체 보고하지 않는다.

## 종료 조건

완료된 `temp.md` 항목만 삭제한다. 문서 변경도 승인 파일만 stage해 `main`에 커밋·푸시하고, 마지막에 `HEAD == origin/main == ls-remote main`, tracked/untracked clean을 다시 확인한다.
