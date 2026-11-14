import TaptionAssistantProtocol
import XCTest
@testable import TaptionPlan

/// 패키지 타깃 안의 문구가 앱 번들의 번역 팩에서 번역을 찾는지 본다(RMN1114A24).
/// AI 코드를 `Packages/TaptionAssistant`로 옮길 때 문구가 든 코드도 옮길 수 있는지의 근거다.
final class PackageTextLookupTests: XCTestCase {
    private var saved = AppLanguagePreference.automatic

    override func setUp() {
        super.setUp()
        saved = AppLanguagePreference.current
    }

    override func tearDown() {
        AppLanguagePreference.save(saved)
        super.tearDown()
    }

    /// 번역 팩에 든 번역문을 시험이 직접 읽는다. 조회 코드(`UITextPack`)를 거치지 않은 기준값이다.
    private func packValue(_ key: String, code: String) throws -> String {
        let path = try XCTUnwrap(Bundle.main.path(forResource: code, ofType: "lproj"), "시험 호스트 앱 번들에 \(code).lproj가 없다")
        let bundle = try XCTUnwrap(Bundle(path: path))
        let value = bundle.localizedString(forKey: key, value: "\u{1}", table: "UIText")
        XCTAssertNotEqual(value, "\u{1}", "\(code) 번역 팩에 「\(key)」가 없다")
        return value
    }

    func testPackageCodeFindsTranslationInAppBundle() throws {
        let template = try packValue("메모 {0}개|{0} memo(s)", code: "ja")
        XCTAssertFalse(template.contains("memo"), "일본어 번역이 아니다: \(template)")

        AppLanguagePreference.save(.japanese)
        XCTAssertEqual(UITextPack.activeLanguageCode, "ja", "시험 호스트에서 번역 언어가 켜지지 않았다")

        let fromPackage = AssistantOperationSpec.Counter.memos.noticePart(2, .english)
        XCTAssertEqual(fromPackage, template.replacingOccurrences(of: "{0}", with: "2"), "패키지 코드가 앱 번들의 일본어 번역을 돌려줘야 한다")
        XCTAssertNotEqual(fromPackage, "2 memo(s)", "영어로 떨어졌다")
        let fromApp = AppLanguagePreference.ResolvedLanguage.english.text("메모 \(2)개", "\(2) memo(s)")
        XCTAssertEqual(fromPackage, fromApp, "앱 타깃에서 부른 것과 같아야 한다")
    }

    func testPackageCodeFollowsLanguageChanges() throws {
        let german = try packValue("가계부 {0}개|{0} ledger entr(ies)", code: "de").replacingOccurrences(of: "{0}", with: "3")
        AppLanguagePreference.save(.german)
        XCTAssertEqual(AssistantOperationSpec.Counter.ledger.noticePart(3, .english), german)
        AppLanguagePreference.save(.english)
        XCTAssertEqual(AssistantOperationSpec.Counter.ledger.noticePart(3, .english), "3 ledger entr(ies)", "영어로 고정하면 번역하지 않는다")
        AppLanguagePreference.save(.korean)
        XCTAssertEqual(AssistantOperationSpec.Counter.ledger.noticePart(3, .korean), "가계부 3개")
    }
}
