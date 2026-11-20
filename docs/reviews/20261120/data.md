# taption-plan 데이터·동시성·백업 영역 코드 검토

- 검토일: 2026-11-20
- 대상: DayStoreV3(SQLite 정본), 백업/복원, AI 중계 큐·전송·비밀, 결제 문자 파싱, 여행 공유 암호화·세션
- 방법: 대상 파일 전수 정독 + `rg`/`grep`으로 의심 패턴 검증. 아래 항목은 모두 코드 근거가 있는 것만 적었다.
- 제외 파일(Claude Code 작업 중)은 건드리지 않았다: `AssistantAIProvider.swift`, `AssistantConnectView.swift`, `AssistantConnectGuide.swift`, `AITaskPanel.swift`, `AssistantPhase3Tests.swift`
- 이 문서는 검토만 한다. 소스 파일을 수정·커밋·푸시하지 않았다.

파일 경로는 저장소 루트(`~/workspace/repos/taption-plan`) 기준이다.

---

## 상 — 먼저 고칠 것

### D1. Keychain 키 교체가 비원자적이라 실패하면 기존 키가 사라진다
- **파일:줄** — `Packages/TaptionAssistant/Sources/TaptionAssistantKit/AssistantSecrets.swift:44-49`
- **문제** — `write(_:to:)`가 먼저 `SecItemDelete`로 기존 항목을 지운 뒤 `SecItemAdd`로 새로 넣는다. `SecItemAdd`가 실패하면(기기 잠금·Keychain 접근 불가·디스크 문제) 이미 지운 옛 키는 돌아오지 않는다. 주 키(`relay-key`)가 사라지면 AI 연결·중계가 끊기고, 복구하려면 사용자가 연결 키를 다시 만들어야 한다. `SecItemDelete`의 반환값도 확인하지 않는다.
- **고치는 방법** — 삭제 후 추가 대신 `SecItemUpdate`를 먼저 시도하고, 항목이 없을 때만(`errSecItemNotFound`) `SecItemAdd`로 넣는다. 또는 `SecItemAdd`가 성공한 뒤에야 옛 항목을 지우는 순서를 쓰되, 중복 항목(`errSecDuplicateItem`) 처리를 넣는다.

### D2. `rawDigest`가 트랜잭션 없이 스캔해 찢어진 읽기의 다이제스트를 그대로 돌려준다
- **파일:줄** — `Packages/TaptionPlanCore/Sources/TaptionPlanCore/DayStoreV3+RawEvents.swift:733-803`
- **문제** — `rawDigest(for:)`가 `raw_events`를 한 행씩 스캔하면서 SHA256을 계산하는데, 이 스캔이 트랜잭션 밖에 있다. 다른 연결(다른 스토어 인스턴스·확장 프로그램)이 스캔 도중에 쓰면 앞부분은 쓰기 전, 뒷부분은 쓰기 후 상태가 섞인 다이제스트가 된다. 끝에서 `currentDataVersion() == dataVersion`을 확인하는 것은 영속화(`persistRawDigest`)만 막을 뿐, 찢어진 다이제스트 자체는 그대로 반환한다. 호출자는 이 값을 실제 DB 상태와 비교해 materialization 여부를 판단하므로 잘못된 다이제스트가 캐시·머티리얼라이즈 판정을 틀리게 할 수 있다.
- **고치는 방법** — 스캔 전체를 `withReadTransaction` 안에서 수행하거나, 스캔 뒤 `dataVersion`이 바뀌었으면 `staleRawEventCursor`를 던지고 호출자가 다시 시도하게 한다. (`rawEventPage`는 같은 검사를 이미 하고 있다.)

### D3. 복원 복구(`recover`)에서 meta 읽기 실패 시 메모 합치기용 준비 파일을 지워 버린다
- **파일:줄** — `Packages/TaptionPlanStore/Sources/TaptionPlanStore/TaptionStoreBackupRestore.swift:250-263`
- **문제** — `recover`가 `try? await store.meta(pendingMemoKey)`로 "메모 남음" 표시를 읽는다. `meta`가 던지면( DB 오류 등) `pending`이 `nil`이 되고 `keep`도 `nil`이 돼, 뒤의 정리 루프가 준비 디렉토리를 전부 지운다. 그 안에 커밋은 됐지만 메모 합치기를 못 끝낸 준비 파일이 있으면 메모 복원이 영영 사라진다. 다음 `recover`에서는 표시가 남아 있어도 파일이 없으므로 `setMeta(pendingMemoKey, "")`으로 표시만 지우고 끝난다(253-258행: 파일이 없으면 `applyMemos`를 건너뛰고 표시를 지운다).
- **고치는 방법** — `meta` 읽기가 실패하면 정리 루프를 타지 않고 그대로 둔다(다음 작업에서 다시 시도). 즉 `try?` 대신 `do/catch`로 실패 시 `return`한다. 또는 표시를 못 읽었을 때는 어떤 준비 디렉토리도 지우지 않는다.

### D4. 백업 엔진 직렬화에서 취소된 대기자가 영원히 매달리고, 취소됐는데도 작업이 실행된다
- **파일:줄** — `TaptionPlan/Core/TaptionBackupEngine.swift:191-199`
- **문제** — `exclusive`가 `withCheckedContinuation`으로 대기자를 등록한다. 이 continuation은 취소에 반응하지 않으므로, 대기 중 취소된 작업은 앞 작업이 끝날 때까지 그대로 매달렸다가, 재개된 뒤 취소 여부를 확인하지 않고 `prepareEnvironment()`와 본 작업을 그대로 실행한다. 백업·복원·오프로드가 사용자 취소 뒤에도 돌아가는 셈이다.
- **고치는 방법** — `withTaskCancellationHandler`로 취소 시 대기열에서 continuation을 빼고 재개하거나, 재개 직후 `try Task.checkCancellation()`을 넣어 취소됐으면 작업을 시작하지 않게 한다.

### D5. `PRAGMA journal_mode=WAL` 결과를 확인하지 않아 WAL이 안 켜져도 조용히 넘어간다
- **파일:줄** — `Packages/TaptionPlanCore/Sources/TaptionPlanCore/DayStoreV3+Schema.swift:162-177` (`enableWriteAheadLog`, 167행)
- **문제** — `sqliteExecute`는 `sqlite3_exec`로 PRAGMA를 실행하고 반환 행을 버린다. 다른 연결이 DB를 열어 둔 상태에서는 `journal_mode=WAL`이 에러 없이 현재 모드(`delete`)를 돌려주기만 하므로, WAL이 안 켜진 채로 초기화가 성공한다. 이후 코드는 WAL을 전제로 한다(`checkpoint()`의 `sqlite3_wal_checkpoint_v2`, `-wal`/`-shm` 파일 보호). 재시도 루프는 `SQLITE_BUSY` 에러에만 반응해 이 경우를 잡지 못한다.
- **고치는 방법** — `sqlite3_exec` 대신 prepare/step으로 PRAGMA의 반환 값을 읽어 `wal`인지 확인하고, 아니면 `SQLITE_BUSY`처럼 재시도하거나 에러를 던진다.

### D6. 공유 세션을 해제해도 ping Task가 영원히 돌아간다
- **파일:줄** — `Packages/TaptionTripShare/Sources/TaptionTripShare/ShareRoomSession.swift:300-309`
- **문제** — `startPing()`이 `Task { [environment, client] in while !Task.isCancelled { ... await client.ping() } }`를 만든다. 이 Task는 `self`를 약하게 잡지 않고 `client`를 강하게 잡으며, 세션에는 `deinit`이 없다(패키지 전체에 `deinit`이 없음). `stop()` 없이 세션이 해제되면 ping Task를 취소할 주체가 사라져 30초마다 `ping()`을 영원히 보내고 `ShareRoomClient` 액터도 살려 둔다. (`runTask`·`renewTask`는 `[weak self]`라 세션 해제 시 끝나지만 ping만 남는다.)
- **고치는 방법** — `deinit`에서 `pingTask`·`runTask`·`renewTask`를 취소하거나, ping Task도 `[weak self]`로 세션 소멸 시 종료되게 한다. 함께 `events`·`locationEvents`의 continuation도 `finish()`로 닫는다(안 그러면 스트림을 들고 있던 구독자가 영원히 대기한다).

---

## 중 — 고칠 것

### D7. `bind(Data)`가 2GB 넘는 payload에서 `Int32` 변환 트랩으로 크래시한다
- **파일:줄** — `Packages/TaptionPlanCore/Sources/TaptionPlanCore/DayStoreV3+SQLite.swift:199-215` (207행 `Int32(value.count)`)
- **문제** — `bind(_ value: Data, ...)`가 길이 검사 없이 `Int32(value.count)`를 쓴다. `value.count > Int32.max`면 Swift 정수 변환이 런타임 트랩으로 크래시한다. 같은 파일의 `bindText`(:169-185행)는 `value.count <= Int(Int32.max)`를 검사해 `integerOverflow`를 던지는데 `bind(Data)`만 검사가 없다.
- **고치는 방법** — `bindText`와 같은 상한 검사를 `bind(Data)`에도 넣는다. (현실적으로 2GB payload는 드물지만, 검사 한 줄로 크래시를 에러로 바꿀 수 있다.)

### D8. 백업 프레임 복호화에서 빈 압축 payload가 `baseAddress!` 크래시를 낸다
- **파일:줄** — `Packages/TaptionPlanStore/Sources/TaptionPlanStore/TaptionBackupFormat.swift:292-309` (301행)
- **문제** — `TaptionBackupCodec.decompress`가 코덱이 lzfse/zlib이고 `expectedSize > 0`인데 `data`가 비어 있으면 `source.bindMemory(...).baseAddress!`에서 트랩한다. `readSealedFrame`은 `payloadSize == 0`인 프레임을 막지 않는다(크기 검사만 통과하면 됨). 정상 작성기는 이런 프레임을 만들지 않으므로, 인증(GCM)을 통과한 비정상 파일에서만 터진다.
- **고치는 방법** — `decompress` 시작 부분에 `guard !data.isEmpty else { throw .malformed(...) }`를 넣거나, `readSealedFrame`에서 코덱이 압축일 때 `payloadSize > 0`을 요구한다.

### D9. `backupAllMonths`가 설정 파일 백업 전에 취소를 확인하지 않는다
- **파일:줄** — `TaptionPlan/Core/TaptionBackupEngine.swift:289-297` (296행)
- **문제** — 월 순회 루프 안에서는 매번 `try Task.checkCancellation()`을 하지만, 루프 뒤의 설정 파일 백업(`attempt(.settings, ...)`) 앞에는 검사가 없다. 마지막 월 백업 도중 취소되면 설정 백업이 취소됐는데도 실행된다.
- **고치는 방법** — 296행 앞에 `try Task.checkCancellation()`을 넣는다.

### D10. 복원 중 대용량 파일 복호화에는 취소 검사가 없어 취소가 늦게 먹힌다
- **파일:줄** — `TaptionPlan/Core/TaptionBackupEngine.swift:551-572` (571행)
- **문제** — `apply`에서 `Task.checkCancellation()`은 `decode`가 끝난 뒤에야 한 번 호출된다. `decode`의 줄 처리 핸들러 안에는 취소 검사가 없어, 수만 행짜리 파일을 풀 때는 취소 요청이 전체 복호화가 끝날 때까지 반영되지 않는다.
- **고치는 방법** — `decode`의 핸들러(또는 `flush` 배치 경계)마다 주기적으로 `try Task.checkCancellation()`을 확인한다.

### D11. `listBackups`가 직렬화 밖에서 `keyCache`를 비워 진행 중 백업의 키 유도를 다시 하게 한다
- **파일:줄** — `TaptionPlan/Core/TaptionBackupEngine.swift:258` (`keyCache = [:]`), 197행과 대조
- **문제** — `listBackups`는 `exclusive`로 감싸지 않은 액터 메서드라, 백업 작업이 `await` 지점에서 양보한 사이에 끼어들어 `keyCache`를 비울 수 있다. 키가 지워지면 진행 중 백업이 다음 파일을 열 때 PBKDF2 60만 회를 다시 돌린다(기능 오류는 아니고 성능·배터리 비용).
- **고치는 방법** — `listBackups`도 `exclusive`로 감싸거나, 캐시를 비우는 대신 목록용 키와 작업용 키를 분리한다.

### D12. 백업 JSON Lines 파서가 `NaN`·`Infinity`를 숫자로 받아들인다
- **파일:줄** — `Packages/TaptionPlanStore/Sources/TaptionPlanStore/TaptionBackupFormat.swift:1006` (`Double(token) != nil`)
- **문제** — `Double("NaN")`·`Double("Infinity")`는 `nil`이 아니므로, `NaN` 토큰이 `.number` 필드로 통과한다. 작성기(`Builder.double`)는 유한하지 않은 수를 거부하지만 파서는 허용해, 손상됐거나 조작된(인증된) 파일의 `NaN` 시각이 `Date(timeIntervalSince1970: .nan)`으로 기록 행에 들어갈 수 있다.
- **고치는 방법** — 숫자 토큰 검사에 `value.isFinite`를 추가한다.

### D13. 백업 검증에서 `fields[5]`를 개수 확인 없이 인덱싱한다
- **파일:줄** — `TaptionPlan/Core/TaptionBackupEngine.swift:794` (`fields[5].double`)
- **문제** — `verifyFile`의 핸들러가 `TaptionBackupRowIdentity.entry(of:)`로 "c" 줄을 골라낸 뒤 `fields[5]`를 바로 읽는다. `entry(of:)`는 필드가 3개만 있어도 기록으로 인정하므로, 필드가 3~5개인 "c" 줄이면 인덱스 범위를 벗어나 크래시한다. 현재는 방금 쓴 임시 파일만 검증하므로 정상 경로에서는 나올 수 없지만, 방어 코드가 없다.
- **고치는 방법** — `fields.count == 10`을 먼저 확인하거나 `fields[safe: 5]` 식의 안전한 접근을 쓴다.

### D14. "취소"가 들어간 결제가 무조건 환불(수입)로 기록된다 — 취소수수료 같은 실제 지출도 수입이 된다
- **파일:줄** — `TaptionPlan/Core/LedgerCapture.swift:101` (`isCancel: flat.contains("취소")`), `entry` 471-483행
- **문제** — `parse`가 본문에 "취소"만 있으면 `isCancel = true`로 하고, `entry`는 취소 문자를 수입으로 둔다. "취소수수료 10,000원 결제", "취소 수수료가 청구됩니다" 같은 실제 지출이 수입으로 잘못 들어간다. (PROPOSALS 8절 9번은 "취소는 수입으로 들어가고 원래 결제와 이어지지 않는다"는 별개 문제이고, 이 항목은 취소가 아닌 지출이 수입으로 바뀌는 새로운 오분류다.)
- **고치는 방법** — "취소수수료"·"취소 수수료"·"위약금" 같은 수수료 표현이 있으면 취소로 보지 않거나, "취소"가 "승인취소"·"결제취소"·"취소완료" 같은 취소 확정 표현일 때만 `isCancel`로 본다.

### D15. 정오 12:00 거래를 "시각을 못 읽은 거래"로 오인해 중복 판정이 달라진다
- **파일:줄** — `TaptionPlan/Core/LedgerCapture.swift:627-634`
- **문제** — `LedgerCaptureBatch.exists`가 `hour: 12, minute: 0`인 항목을 시각 없음으로 보고 같은 날 기준으로 중복을 판단한다. 실제로 정오 12시 정각에 결제한 거래도 같은 취급을 받아, 같은 날 같은 금액의 다른 결제를 중복으로 빼 버릴 수 있다. (스크린샷 리더가 시각을 못 읽으면 낮 12시를 기본값으로 쓰기 때문에 생긴 구분법이다.)
- **고치는 방법** — 시각을 못 읽었는지 여부를 `Date` 값이 아니라 별도 플래그(예: `occurredAtKnown: Bool`)로 들고 다니게 한다.

### D16. `appendRawEvents`에 배치·payload 크기 상한이 없어 긴 쓰기 트랜잭션이 다른 쓰기를 막는다
- **파일:줄** — `Packages/TaptionPlanCore/Sources/TaptionPlanCore/DayStoreV3.swift:99-146`, `DayStoreV3+Schema.swift:7` (`busy_timeout=5000`)
- **문제** — `appendRawEvents`는 이벤트 수나 payload 크기를 제한하지 않는다. 아웃박스(`insertOutboxItems`)에는 건수 4,096개·합계 64MB 상한이 있지만 raw 이벤트에는 없다. 수천 건을 한 `BEGIN IMMEDIATE` 트랜잭션으로 쓰면 5초 busy timeout을 넘는 동안 다른 연결의 쓰기가 `SQLITE_BUSY`("database is locked")로 실패한다.
- **고치는 방법** — 배치 크기에 상한을 두고(예: 1,000건 또는 4MB) 넘으면 나누어 쓰거나 에러를 던진다. 또는 호출자(복원 경로)가 페이징하도록 문서화한다.

### D17. 공유 세션의 `probe`·`hello`·잠금 연장이 에러를 조용히 삼킨다
- **파일:줄** — `Packages/TaptionTripShare/Sources/TaptionTripShare/ShareRoomSession.swift:229-240` (`catch {}` 237행), 252행 (`try? await catchUp()`), 595-601행 (`catch {}` 601행)
- **문제** — 소켓이 끊긴 뒤 HTTP로 서버를 확인하는 `probe`가 모든 에러를 `catch {}`로 버리고, `hello` 뒤 따라잡기 실패와 잠금 연장 실패도 삼킨다. 재연결이 왜 안 되는지, 따라잡기가 왜 멈췄는지 진단할 단서가 남지 않는다. (`run` 루프가 다시 시도하므로 기능은 복구되지만, 반복 실패 시 원인을 알 수 없다.)
- **고치는 방법** — 최소한 진단 로그(`TaptionPlanDiagnosticsLogger`)에 에러 종류를 남긴다. `probe`는 실패 원인을 상태(`offline` 등)에 반영하는 것도 검토한다.

### D18. 중계 전송이 `CancellationError`를 삼켜 취소와 네트워크 실패를 구분하지 못한다
- **파일:줄** — `Packages/TaptionAssistant/Sources/TaptionAssistantKit/TripRelay.swift:132` (`try? await session.data(for: request)`)
- **문제** — `sendResponse`가 `try?`로 모든 에러를 `nil`로 만든다. 작업 취소도 네트워크 실패와 같은 `nil`이 돼, 호출자(명령 폴링·작업 업로드)가 취소됐는데도 실패로 처리하고 다음 폴링을 예약하거나 재시도할 수 있다.
- **고치는 방법** — `CancellationError`는 다시 던지고(`catch is CancellationError { throw ... }`), 나머지만 `nil`로 만든다. 또는 `send`의 반환 타입에 취소 여부를 구분한다.

### D19. 복원 준비 파일 비교에서 길이 0 blob이 `Data(bytes: nil)` 트랩을 낼 수 있다
- **파일:줄** — `Packages/TaptionPlanStore/Sources/TaptionPlanStore/TaptionStoreBackupRestore.swift:101-104`
- **문제** — `stagedValue`의 BLOB 분기가 `sqlite3_column_blob` 결과를 옵셔널 해제 없이 `Data(bytes:count:)`에 넘긴다. 길이 0인 blob은 `sqlite3_column_blob`이 NULL을 돌려주므로 트랩한다. 준비 DB가 손상됐을 때만 나오는 경로지만, 복원 비교 도중 크래시하면 복원이 중단된다.
- **고치는 방법** — `sqlite3_column_blob`이 `nil`이면 빈 `Data()`를 돌려주도록 `guard let`을 넣는다.

### D20. 공유 키 유도(`ShareKeys.derive`)의 반복 횟수 하한이 없다
- **파일:줄** — `Packages/TaptionTripShare/Sources/TaptionTripShare/ShareKeys.swift:79` (`iterations > 0`만 검사)
- **문제** — `pbkdf2`가 `iterations > 0`만 요구한다. 현재 모든 호출처가 기본값 60만 회를 쓰지만, 나중에 어떤 호출처가 작은 값을 넘기면 조용히 약한 키가 만들어진다. 백업 쪽 `deriveKey`는 `minIterations`(10만)~`maxIterations`(500만) 범위를 강제하는 것과 대조된다.
- **고치는 방법** — `derive`·`pbkdf2`에 최소 반복 횟수(예: 100,000)를 강제한다.

---

## 하 — 여유가 있을 때

### D21. 백업 작성기가 기존 파일을 절단하지 않아 이전 내용 찌꺼기가 남을 수 있다
- **파일:줄** — `Packages/TaptionPlanStore/Sources/TaptionPlanStore/TaptionBackupFormat.swift:474-479`
- **문제** — `TaptionBackupFileWriter.init`이 `createFile` 후 `FileHandle(forWritingTo:)`로 열 뿐 절단하지 않는다. 대상 파일이 이미 있고 새 내용보다 길면 꼬리에 예전 바이트가 남아, 복호화 마지막의 "남은 바이트 없음" 검사가 실패한다. 엔진은 항상 UUID 임시 파일을 쓰므로 현재 경로는 안전하다.
- **고치는 방법** — 열 때 `try handle.truncate(atOffset: 0)`을 하거나, 기존 파일이 있으면 지우고 만든다.

### D22. 한 줄이 프레임 상한을 넘으면 그 달 백업 전체가 실패한다
- **파일:줄** — `Packages/TaptionPlanStore/Sources/TaptionPlanStore/TaptionBackupFormat.swift:522-525`
- **문제** — `append`가 줄 하나를 `chunkBytes`보다 크게 두지 못하고, `flush`에서 `maxPlainFrameBytes`(엔진 설정 4MB 청크 기준 16MB)를 넘으면 `malformed("frame too large")`를 던져 그 달 백업 전체가 실패한다. 16MB짜리 메모 한 건이 달 전체 백업을 막는다.
- **고치는 방법** — 실패 전에 해당 행을 건너뛰고 결과에 알리거나, 프레임 상한을 넘기는 줄은 별도 에러로 구분해 사용자에게 보여준다.

### D23. `TaptionDataFileLock.unlock`이 스레드에 안전하지 않아 fd를 두 번 닫을 수 있다
- **파일:줄** — `Packages/TaptionPlanStore/Sources/TaptionPlanStore/TaptionDataFileLock.swift:61-66`
- **문제** — `unlock()`의 `descriptor >= 0` 검사와 `-1` 대입 사이에 동기화가 없다(`@unchecked Sendable`). 두 스레드가 동시에 부르면 둘 다 `close`를 호출하고, 그 사이 fd 번호가 재사용되면 다른 파일의 fd를 닫을 수 있다. `deinit`에서도 `unlock()`을 부르므로 명시적 해제와 소멸이 겹칠 수 있다.
- **고치는 방법** — `NSLock`이나 `OSAllocatedUnfairLock`으로 `unlock`을 감싼다.

### D24. `checkpoint()`가 PASSIVE 체크포인트가 실제로 끝났는지 확인하지 않는다
- **파일:줄** — `Packages/TaptionPlanCore/Sources/TaptionPlanCore/DayStoreV3.swift:499-517`
- **문제** — `sqlite3_wal_checkpoint_v2`에 `SQLITE_CHECKPOINT_PASSIVE`를 쓰고 로그/체크포인트 프레임 수(out 파라미터)를 `nil`로 버린다. PASSIVE는 다른 연결이 읽는 중이면 `SQLITE_OK`를 돌려주면서도 WAL을 다 비우지 않으므로, 호출자는 체크포인트가 끝난 줄 알고 WAL이 남아 있는 상태로 진행한다.
- **고치는 방법** — `logFrames`·`checkpointedFrames`를 받아 둘이 다르면 `SQLITE_CHECKPOINT_RESTART`로 한 번 더 시도하거나 결과를 호출자에게 알린다.

### D25. `deleteAllData`가 `migration_markers`를 남긴다
- **파일:줄** — `Packages/TaptionPlanCore/Sources/TaptionPlanCore/DayStoreV3.swift:412-452`
- **문제** — 전체 삭제가 `raw_events`·`day_materialized`·`raw_digest_cache`·`device_outbox`·`raw_restore_receipts`를 지우지만 `migration_markers`는 남긴다. "데이터 전체 삭제 후 다시 가져오기" 흐름에서 예전 마이그레이션 완료 표시가 남아, 새 데이터에 필요한 마이그레이션을 건너뛸 수 있다. 스키마 수준 표시라 의도된 것일 수도 있다.
- **고치는 방법** — 의도인지 확인하고, 데이터 삭제의 일부라면 `migration_markers`도 함께 지우거나, 남기는 이유를 주석으로 남긴다.

### D26. 복원 영수증이 손상되면 롤백이 영원히 실패하고, 이 API는 실사용처가 없다
- **파일:줄** — `Packages/TaptionPlanCore/Sources/TaptionPlanCore/DayStoreV3.swift:149-197` (154행 `JSONDecoder().decode`)
- **문제** — `finishRestoreSession(committed: false)`에서 영수증 JSON 복호화가 실패하면 트랜잭션 전체가 롤백되고 영수증이 남아, 다시 불러도 같은 곳에서 실패한다(독성 영수증). 또한 `restoreSessionID`·`finishRestoreSession`은 테스트에서만 쓰이고 실사용처가 없다.
- **고치는 방법** — 복호화에 실패한 영수증은 건너뛰고 지우거나 별도 에러로 보고해 롤백이 진행되게 한다. 실사용처가 없을 예정이면 API를 정리하거나 사용처를 문서화한다.

### D27. 가게 이름에 "충전"이 들어간 결제가 충전으로 오인돼 빠진다
- **파일:줄** — `TaptionPlan/Core/LedgerCapture.swift:35-40` (39행)
- **문제** — `isTopUp`이 본문에 "충전"만 있고 `spendingCharges`("충전소"·"전기차"·"충전요금" 등)가 없으면 충전으로 본다. "충전"이 들어간 상호에서의 실제 결제(예: "배터리충전 5,000원 결제")가 가계부에서 빠진다.
- **고치는 방법** — "충전" 뒤에 금액이 바로 오는 형태("충전 50,000원")나 충전 대상("○○카드 충전") 패턴일 때만 충전으로 본다.

### D28. 다건 알림 정규식이 " N건 "이 들어간 일반 결제를 안내로 오인한다
- **파일:줄** — `TaptionPlan/Core/LedgerCapture.swift:48`
- **문제** — `isNotice`의 `(?:^|\s)[0-9]+건(?:\s|$)`이 "스타벅스 2건 15,000원 결제" 같은 글도 안내로 빼 버린다. 건수가 들어간 결제 알림이 누락될 수 있다.
- **고치는 방법** — 건수와 함께 "합계"·"총"·"이용내역" 같은 집계 표현이 있을 때만 안내로 본다.

### D29. 날짜 파싱이 월별 일수를 검증하지 않는다 (2월 31일 등)
- **파일:줄** — `TaptionPlan/Core/LedgerCapture.swift:190` (`(1...31).contains`), 583행 (`dayHeader` 동일)
- **문제** — `date`와 `dayHeader`가 일을 1~31로만 검사한다. "2월 31일" 같은 존재하지 않는 날짜가 들어오면 `Calendar.date(from:)`의 정규화 동작에 따라 다른 날짜(3월 3일 등)로 바뀌어 조용히 저장될 수 있다.
- **고치는 방법** — 만든 `Date`의 월·일이 입력과 같은지 왕복 확인하고 다르면 `nil`을 돌려준다.

### D30. 영수증 머리말("영수증" 등)이 가게 이름이 된다
- **파일:줄** — `TaptionPlan/Core/LedgerCapture.swift:529-532`
- **문제** — `LedgerReceiptReader.draft`가 가게 이름을 "글자가 있고 숫자가 없는 첫 줄"로 잡는다. 영수증 첫 줄이 "영수증"·"매출전표"·"현금영수증"이면 그 말이 가게 이름이 된다.
- **고치는 방법** — "영수증"·"매출전표"·"현금영수증"·"거래명세서" 같은 머리말을 제외하고 다음 줄을 본다.

### D31. Keychain 비밀 읽기에서 키 형식 검증이 없다
- **파일:줄** — `Packages/TaptionAssistant/Sources/TaptionAssistantKit/AssistantSecrets.swift:33-39`
- **문제** — `AssistantKeychainSecrets.read`가 UTF-8 문자열이면 그대로 돌려준다. `TripRelay.key`는 `isValidKey`(43자 base64url)를 검사하는 것과 대조된다. 손상된 값이 들어가면 서버가 거부할 때까지만 알 수 있다.
- **고치는 방법** — `master`·`pendingMaster` 슬롯은 `TripRelay.isValidKey`로 검증하고, 형식이 다르면 `nil`을 돌려준다.

### D32. 백업 교체 후 확인용 fetch가 실패하면 이미 교체된 파일을 실패로 보고한다
- **파일:줄** — `TaptionPlan/Core/TaptionBackupEngine.swift:444-457`
- **문제** — `write`가 `destination.replace`에 성공한 뒤 확인용 `fetch`를 하는데, 이 fetch가 실패하면(네트워크 등) 에러를 던져 백업을 실패로 보고한다. 실제로는 새 파일이 이미 올라가 있고, epoch 메타만 안 남았다. 다음 백업에서 다시 쓰기를 시도하므로 데이터 손실은 없지만 사용자에게 오해를 준다.
- **고치는 방법** — 확인용 fetch 실패를 "교체는 됐으나 확인 못 함"으로 구분해 결과에 알리거나, epoch 메타를 남기고 다음 백업에서 검증하게 한다.

### D33. AI 작업 확인(ack) 목록이 300개로 잘리면 오래된 확인이 사라진다
- **파일:줄** — `Packages/TaptionAssistant/Sources/TaptionAssistantKit/AITaskQueue.swift:120-129`
- **문제** — `acked` 목록이 최신 300개만 유지된다. 확인 목록에서 밀려난 id의 업로드가 큐에 남아 있으면(응답 유실로 남은 경우) 다시 올려 서버가 끝난 일을 되살릴 수 있다. 서버가 id로 중복을 제거한다면 무해하다.
- **고치는 방법** — 서버의 id 중복 제거를 확인하고, 안 된다면 업로드 큐와 확인 목록의 보관 정책을 맞춘다.

### D34. 공유 세션의 AsyncStream continuation을 끝내는 곳이 없다
- **파일:줄** — `Packages/TaptionTripShare/Sources/TaptionTripShare/ShareRoomSession.swift:15-19`
- **문제** — `events`·`locationEvents`의 continuation을 `finish()`하는 곳이 없다. 세션이 해제된 뒤에도 스트림을 들고 `for await`를 도는 구독자는 영원히 대기한다. (D6의 `deinit` 수정과 함께 해결된다.)
- **고치는 방법** — `deinit`에서 두 continuation을 `finish()`한다.

---

## 확인됨 — 이미 알려진 항목 (재제안 안 함)

### 알려진 항목
- **CI `DayStoreV3Tests.testConcurrentColdOpensInitializeOneV3Schema` "database is locked" 간헐 실패 — 확인됨.** 테스트는 `Packages/TaptionPlanCore/Tests/TaptionPlanCoreTests/DayStoreV3Tests.swift:53`에 있다. 코드상 경로: 두 연결이 동시에 빈 DB를 열면 한쪽이 `BEGIN IMMEDIATE`에서 5초 `busy_timeout`을 넘겨 실패할 수 있다(`DayStoreV3+Schema.swift:7, 74`). 기존 스키마가 있는 경로의 `CREATE INDEX/TABLE IF NOT EXISTS`(:25-72행)도 트랜잭션 밖에서 실행돼 같은 락 경합에 노출된다. (이미 알려진 항목이라 수정안은 적지 않는다.)
- **TravelModeView.swift actor 격리 CI 실패** — 대표 지시로 건드리지 않음. 제안 없음.
- **AIR1114A01 서버 동시 완료 덮어쓰기** — 서버 쪽 문제. 제안 없음.

### PROPOSALS.md 8절의 11가지 빈틈 — 코드 대조 결과
| # | 빈틈 | 코드 확인 결과 |
|---|---|---|
| 1 | 가게 이름이 카드사 이름으로 시작하면 버려짐 | **수정됨 확인** — `LedgerCapture.swift:220-228` `cardFollowers`·`isCardName`이 "롯데마트"·"하나로마트"를 가게로 살린다 |
| 2 | 카드 이름을 글 전체에서 찾아 오인식 | **수정됨 확인** — `card()`(:234-261)가 뒤따르는 글자·위치 조건을 검사한다 |
| 3 | "승인거절 … 잔액부족"이 지출로 저장 | **수정됨 확인** — `declined`(:23)에 "거절"·"잔액부족"이 있고 `isNotice`에서 제외한다 |
| 4 | "카드 결제대금 출금"이 지출로 이중 계산 | **수정됨 확인** — `notPayments`(:21)에 "결제대금"·"카드대금"이 있다. 단 본문에 "승인"이 함께 있으면 예외(:51) |
| 5 | "12:30" 뒤 "30원" 오인식, "GS25 원효로점" 깨짐 | **수정됨 확인** — `wonAmounts`(:268-283)의 숫자 꼬리 검사와 `wonParticles`(:264-265) |
| 6 | 한 줄짜리 앱 알림 가게 이름 못 잡음 | **수정됨 확인** — `inlineMerchant`(:291-293) 존재 |
| 7 | "12.50 USD"·날짜 없는 시각·"11월10일" 미지원 | **부분 확인됨** — 외화 숫자 우선은 수정됨(`foreignAmount` :128-141). 날짜 없는 시각("12:31"만)과 "11월10일"은 `LedgerMessageParser.when`(:177-188)에서 여전히 못 읽는다. "11월10일"은 스크린샷 리더의 `dayHeader`(:580-587)에서만 처리한다 |
| 8 | 급여·환급 입금 버려짐, 자기 계좌 이체·충전 지출 처리 | **확인됨** — `paymentWords`(:51)에 "입금"이 없고, 이체 문자는 지출 후보가 된다 |
| 9 | 취소가 수입으로 들어가고 원결제와 미연결 | **확인됨** — `entry`(:471-483)에서 `isCancel`이면 `.income`으로 두고 원결제와 잇지 않는다 |
| 10 | 중복 판정이 문자·알림끼리만, 10분 안 같은 금액의 진짜 두 결제 소실 | **확인됨** — `isDuplicate`(:81-85)가 `source == .message`만 본다 |
| 11 | 붙여넣기·영수증이 결제 후보가 아닌 글도 AI에 보냄 | **수정됨 확인** — `looksLikePayment`가 `SiriIntents.swift:119`, `LedgerSheet.swift:183`, `AITaskProducer.swift:215`에 연결돼 있다 |

---

## 살펴보고 문제없다고 판단한 것 (기록용)

- `DayStoreV3` actor의 `nonisolated(unsafe) var database` — 비격리 접근은 `deinit`의 `sqlite3_close`뿐이고, 진행 중 메서드가 `self`를 강하게 잡으므로 경합이 없다. `sqlite3_changes(database)` 호출처들은 모두 `prepare()`가 `nil`을 먼저 걸러낸 뒤라 안전하다.
- `DayStoreV3.appendRawEvents`·`finishRestoreSession`의 루프 안 `defer { sqlite3_finalize }` — `defer`는 반복마다 실행되므로 문이 쌓이지 않는다.
- `DayStoreV3` 트랜잭션 중첩 — `withTransaction`을 중첩해 부르는 곳이 없다. `markMigrationCompleted`는 트랜잭션 없이 단일 문이다.
- `TaptionPlanV3Store` 초기화의 기존 스키마 경로 — `IF NOT EXISTS`라 부분 적용 뒤 다시 열어도 안전하다.
- `TaptionBackupFileWriter`의 `createFile` + 미절단 — 엔진이 항상 UUID 임시 파일을 쓰므로 현재 경로는 안전하다(D21은 방어용).
- `TaptionBackupFileReader.decode`의 트레일러·해시 검증 — 줄을 핸들러에 넘기기 전에 검증하지 않는다는 점이 주석으로 명시돼 있고, 엔진은 준비 저장소에 모았다가 커밋하므로 설계상 맞다.
- `TaptionRestoreStaging.commit`의 메모 2단계 커밋 — "메모 남음" 표시와 `recover`의 멱등 재시도가 설계돼 있다(D3의 meta 읽기 실패 경로만 예외).
- `TaptionStoreV2.setMeta` — 트랜잭션을 직접 열지 않아 `applyRestoreStaging`의 트랜잭션 안에서 안전하다. `close()`는 `connection = nil`이라 멱등하다.
- `TaptionBackupDestination.list()` — `.taptionbackup` 파일만 돌려주므로 `deleteAllBackups`가 다른 파일을 지우지 않는다.
- `AITaskQueue.enqueue`(`TaptionPlan/UX/AITaskQueue.swift:12-24`) — `uploadLimit`(20)을 강제하고 초과분은 오래된 것부터 버린다.
- `AITaskQueue.upload`의 ack 처리 — 서버가 받은 id를 `acked`에 남겨 재업로드를 막는다(D33의 300개 상한만 참고).
- `AssistantRelayGate` — `begin`/`end`가 호출처에서 `defer`로 짝을 이루고, `waitUntilIdle` 실패 시 회전이 중단된다.
- `ShareCipher.open`의 슬라이스 — `raw.count >= overheadBytes` 검사가 있어 `body[0..<12]`·`body[tagStart...]`가 범위를 벗어나지 않는다.
- `ShareItemContext.aad`의 `|` 구분자 — roomID·itemID는 URL-safe base64url, kind는 고정 enum raw 값이라 `|`가 들어갈 수 없어 모호성이 없다.
- `ShareInvite.make()`의 `!` — `roomID()`는 22자 base64url, `linkSecret()`은 32바이트를 항상 만들므로 안전하다.
- `ShareRoomSession`의 `.replaced` 상태 — `isFinal`이 `.ended`에만 true라 `start()`로 다시 붙을 수 있다.
- `ShareRoomSession.catchUp`의 `catchUpTask` 공유 — 액터 격리라 경합이 없고, `runCatchUp`의 `defer`가 정리한다.
- `ShareBackoff.delay` — 지수 백오프가 60초(+25% 지터)로 상한이 있다.
- `LedgerMessageParser.card()`의 `best!` — `best == nil`일 때 단락 평가로 닿지 않는다.
- `TaptionDataFileLock.acquire`의 무한 대기 — 호출처가 모두 `try await` 컨텍스트이고 루프 안에서 `Task.checkCancellation()`을 하므로 취소가 먹힌다.
- `TaptionBackupCodec.compress`·`deriveKey`의 `baseAddress!` — 호출 전에 비어 있지 않음을 검사한다.
- `finishRestoreSession`·`restoreSessionID` — 실사용처가 테스트뿐이다(D26 참고).
