import XCTest
@testable import TaptionPlan
import TaptionTripShare
import TaptionTripShareTesting

// 묶음 C가 채운다(TSH1114A26). 0단계는 pbxproj에 등록된 빈 파일만 둔다.
// 가짜 서버는 `ShareFakeServer().transport`를 `TripShareEnvironment(transport:secrets:sidecar:appKey:)`에 넣어 쓴다
// (`TripShareFoundationTests.testStoreOpensARoomOnTheFakeServerAndForgetsIt`가 본보기). `TripShareStore.shared`를 바꿨으면 tearDown에서 되돌린다.

@MainActor
final class TripShareLedgerTests: XCTestCase {}
