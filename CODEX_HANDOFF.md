# Codex 작업 지시 — Taption Plan push

작업 디렉터리: `/Users/u_mo_c/Documents/taption plan`
Team `4FWG8XXYM7`, bundle `com.taption.plan`, scheme `TaptionPlan`, App id `6797370230`.

## 현재 상태 (2026-09-25 12:15 KST 기준, git으로 실측 먼저)

- 로컬 `main`이 `origin/main`보다 **35 커밋 ahead**, 워크트리 소스 클린(`test.md`·`.kiro/`·`CODEX_HANDOFF.md`만 로컬 문서).
  - 범위: `fba8901`(워치리스 수면 게이트 완화) … `b5feb36`(BRT raw 센서 generation 보존).
- `CURRENT_PROJECT_VERSION = 156` (4개 번들 Debug/Release 8곳 전부).
- **✅ 빌드 155는 이미 TestFlight 업로드·처리완료(VALID)·Internal 그룹 'TP Taption Plan 내부 테스트' 연결·노출 readback까지 끝났다.** Delivery UUID `08571d8b-7287-42e5-9439-e62a79f8172f`.
- **⚠️ 빌드 156은 아직 업로드 안 됨.** 155 이후 커밋 4개(`cb1d25d` 식사 이중계산 수정 / `f193d49` 156 bump / `217a7a3` 영어 시간 로컬라이즈 / `b5feb36` BRT generation 보존)가 담긴다. 이 셸 환경은 매크로 샌드박스 제약으로 앱타깃 아카이브가 막혀(malformed) 156을 못 올렸다 → 아래 워크어라운드 플래그로 터미널에서 아카이브·업로드 필요.
  - 155 이후 4커밋은 **문법·스코프만 확인, 앱타깃 컴파일 미검증**. 156 아카이브가 곧 컴파일 검증이 된다.

## 해야 할 일 — push (유일 잔여)

```
cd "/Users/u_mo_c/Documents/taption plan"
git log origin/main..HEAD --oneline   # 31커밋 맞는지 확인
git push origin main
```

- 정책상 다른 에이전트는 protected branch(main) 직접 push가 막혀 있어 못 한다. Codex(대표님 터미널)는 가능.
- push 외에 TestFlight 재빌드·업로드는 필요 없다(빌드 155가 이미 올라가 그룹 노출됨). 새 코드 커밋을 추가한 경우에만 다음 빌드(156)를 올린다.

## TestFlight 재빌드가 필요할 때만 (새 커밋 추가 시)

1. 빌드번호 bump: `sed -i '' 's/CURRENT_PROJECT_VERSION = 155;/CURRENT_PROJECT_VERSION = 156;/g' TaptionPlan.xcodeproj/project.pbxproj` (8곳 확인)
2. 변경 커밋
3. 아카이브 (Xcode 27 매크로 워크어라운드 필수, 고정 DerivedData 경로 재사용):
   ```
   xcodebuild archive -project TaptionPlan.xcodeproj -scheme TaptionPlan \
     -configuration Release -destination "generic/platform=iOS" \
     -archivePath "$KIROCREW_SCRATCH/TaptionPlan-156.xcarchive" \
     -derivedDataPath build/ArchiveDD -skipPackagePluginValidation -allowProvisioningUpdates \
     COMPILER_INDEX_STORE_ENABLE=NO \
     OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox'
   ```
   (이 플래그 없으면 `SwiftUIMacros.StateMacro ... malformed response`로 실패.)
4. export: `xcodebuild -exportArchive -archivePath <위 아카이브> -exportOptionsPlist ExportOptions.plist -exportPath "$KIROCREW_SCRATCH/TF-156" -allowProvisioningUpdates`
5. 업로드: `xcrun altool --upload-package "$KIROCREW_SCRATCH/TF-156/TaptionPlan.ipa" --type ios --apiKey AGB82JKGT3 --apiIssuer 229c124e-7477-462c-b3f0-3180eb81ff25 --show-progress`
   (.p8 = `~/.appstoreconnect/private_keys/AuthKey_AGB82JKGT3.p8`)
6. VALID 폴링 → Internal 그룹 `b4857e5e-d1ff-4bc2-b9ad-a69bcd4603fd` 연결(POST relationships/builds) → readback(GET builds?filter[betaGroups]=…). 그룹 노출 확인까지 해야 완료(규칙⑫).

## 설계 결정 4건 (2026-09-25 확정) — 검증 가능 세션에서 착수

대표님 결정: **RST/MIG=선택2(V4 분리), BKC=CloudKit CAS, BRT=최근 10개 보존, PKG=host 주입.**
전부 저장소 정본·백업 스키마·패키지 경계를 바꾸는 고위험 변경이라, 앱타깃 컴파일·회귀 테스트가 통과하는 세션(터미널 or Xcode GUI)에서만 착수한다. 미검증 셸에서 반쯤 만든 커밋을 쌓지 말 것.

### ✅ BRT0920A01 — 이미 착수·커밋됨 (`b5feb36`, 미검증)
- raw 센서 백업(`{monthKey}.{UUID}.rawsensorbackup`)은 같은 달에 generation이 누적되는데 정리 로직이 없었다. `FilePlanCloudRawSensorBackupStore.save` 성공 직후 동일 monthKey generation을 수정일 내림차순 최근 10개만 보존, 나머지 삭제. legacy(UUID 없는) 파일·다른 monthKey 보호. 상수 `PlanCloudRawSensorRetention.maximumGenerationsPerMonth = 10`.
- **주의**: 월별 아카이브(`.taptionbackup`)는 monthKey당 1개라 대상 아님. "10개 정리"를 월별 아카이브에 적용하면 오래된 달 백업 유실 → 하지 말 것.
- **검증 필요**: `TaptionPlanTests/SecurityBackupCoreTests` 통과 확인. 특히 (a) 11번째 저장 시 가장 오래된 generation만 삭제, (b) legacy 파일 미삭제, (c) 다른 monthKey 미영향 케이스 테스트 추가 권장.

### ⬜ RST/MIG — V4 스키마 분리 (미착수, 대규모)
- **목표**: 대용량 월/일 복원 시 통짜 메모리 로드로 인한 OOM 제거.
- **계획**: (1) `PlanRawSensorMonthlyArchive`를 페이지(예: 하루/N-reading 단위) 청크로 쪼갠 V4 payload 정의(`version=4`), (2) V3→V4 마이그레이션 1회 변환(규칙: 동일 버전 변환 1회만), (3) load/query를 페이지 커서 스트리밍으로 교체, (4) 부분 실패 시 rollback journal.
- **영향 파일**: `SecurityBackupCore.swift`(payload/store), `PlanRepository.swift`(481행 주석: 월 raw JSON 256MiB 상한 — split 대상), 복원 UI.
- **검증**: SecurityBackupCoreTests + PlanRepository 복원 테스트, 대용량 fixture로 메모리 상한 회귀.

### ⬜ BKC — CloudKit CAS 원자성 (미착수, 대규모, V4와 함께 설계)
- **목표**: 다중 기기가 같은 달 백업을 덮어써 한쪽 기록이 복원에서 빠지는 문제 제거.
- **계획**: 불변 generationID(이미 raw 백업 경로에 존재) 활용 → CloudKit `recordChangeTag` 기반 compare-and-swap manifest로 월별 최신 generation 포인터를 원자적 갱신. 충돌 시 양쪽 generation 보존 후 재병합(union). BRT의 10개 보존과 정합(CAS로 밀려난 generation도 10개 안에서 보존).
- **영향**: `UbiquitousPlanCloudRawSensorBackupStore`, manifest 타입 신설, `TaptionBackupRecoveryKey` 인접.
- **검증**: 두 기기 동시 저장 시뮬레이션 테스트, CAS 충돌 재시도 경로.

### ⬜ PKG0920A01 — App Group host 주입 (미착수, 리팩터)
- **목표**: 공개 Core API가 앱 전용 App Group ID(`TaptionPlanSharedContainer.appGroupIdentifier`)를 소유하는 경계 위반 제거.
- **계획**: Core에 `AppGroupProviding` 프로토콜 주입점 도입 → host(앱)가 `appGroupIdentifier`를 주입. Core 내부 하드코딩 제거.
- **⚠️ 최고 위험**: 데이터 컨테이너 경로가 바뀌면 **기존 사용자 데이터 유실**. 반드시 주입 후에도 동일 경로를 반환함을 회귀 테스트로 증명한 뒤 머지. 8+ 참조 파일 + Watch/Widget 타깃 전부 영향.
- **검증**: 경로 동일성 테스트, 앱/워치/위젯 3타깃 빌드·기존 데이터 로드 회귀.



- `temp.md` / `test.md` / `.kiro/` / `CODEX_HANDOFF.md` 커밋 금지 (로컬 문서).
- 이미 올라간 빌드 155 재업로드 금지.
- UI/UX 임의 수정 금지.
