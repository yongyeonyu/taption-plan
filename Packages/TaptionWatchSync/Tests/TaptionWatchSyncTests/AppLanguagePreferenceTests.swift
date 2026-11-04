import Foundation
import XCTest
import TaptionWatchSync

final class AppLanguagePreferenceTests: XCTestCase {
    func testUnknownStoredValueFallsBackToAutomatic() {
        let defaults = UserDefaults(suiteName: "AppLanguagePreferenceTests.unknown")!
        defaults.removePersistentDomain(forName: "AppLanguagePreferenceTests.unknown")
        defaults.set("japanese", forKey: AppLanguagePreference.sharedDefaultsKey)

        XCTAssertEqual(
            AppLanguagePreference.load(from: defaults),
            .automatic
        )
        XCTAssertEqual(
            AppLanguagePreference.resolve(
                rawValue: "japanese",
                locale: Locale(identifier: "en_US")
            ),
            .english
        )
    }

    func testAutomaticUsesKoreanOnlyForKoreanDeviceLanguage() {
        XCTAssertEqual(
            AppLanguagePreference.resolve(
                rawValue: "automatic",
                locale: Locale(identifier: "ko_KR")
            ),
            .korean
        )
        XCTAssertEqual(
            AppLanguagePreference.resolve(
                rawValue: "automatic",
                locale: Locale(identifier: "fr_FR")
            ),
            .english
        )
    }

    func testExistingManualChoicesRemainStable() {
        XCTAssertEqual(
            AppLanguagePreference(rawValue: "korean"),
            .korean
        )
        XCTAssertEqual(
            AppLanguagePreference(rawValue: "english"),
            .english
        )
        XCTAssertNil(AppLanguagePreference.automatic.watchPayloadValue)
        XCTAssertEqual(AppLanguagePreference.korean.watchPayloadValue, "korean")
        XCTAssertEqual(AppLanguagePreference.english.watchPayloadValue, "english")
    }

    func testLegacyManualSelectionIsPreserved() {
        let defaults = UserDefaults(
            suiteName: "AppLanguagePreferenceTests.legacy"
        )!
        defaults.removePersistentDomain(
            forName: "AppLanguagePreferenceTests.legacy"
        )
        defaults.set(
            "korean",
            forKey: AppLanguagePreference.legacyDefaultsKey
        )

        XCTAssertEqual(
            AppLanguagePreference.load(
                from: defaults,
                key: AppLanguagePreference.legacyDefaultsKey
            ),
            .korean
        )
        defaults.set(
            "english",
            forKey: AppLanguagePreference.legacyDefaultsKey
        )
        XCTAssertEqual(
            AppLanguagePreference.load(
                from: defaults,
                key: AppLanguagePreference.legacyDefaultsKey
            ),
            .english
        )
    }

    func testSharedSaveUsesStableKey() {
        let defaults = UserDefaults(suiteName: "AppLanguagePreferenceTests.save")!
        defaults.removePersistentDomain(forName: "AppLanguagePreferenceTests.save")

        AppLanguagePreference.save(.english, to: defaults)

        XCTAssertEqual(
            defaults.string(forKey: AppLanguagePreference.sharedDefaultsKey),
            "english"
        )
    }

    func testOlderWatchPayloadWithoutLanguageDecodes() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let payload = TaptionWatchPayload(
            generatedAt: now,
            viewportStart: now,
            viewportEnd: now.addingTimeInterval(3_600),
            items: [],
            catStyle: "calico",
            reducesMotion: false,
            commerceLocked: true
        )
        let encoded = try JSONEncoder().encode(payload)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "languagePreference")
        object.removeValue(forKey: "commerceLocked")
        let oldData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(
            TaptionWatchPayload.self,
            from: oldData
        )
        XCTAssertNil(decoded.languagePreference)
        XCTAssertNil(decoded.commerceLocked)
        XCTAssertEqual(decoded.generatedAt, now)
    }

    func testPositionalTextFollowsResolvedLanguage() {
        XCTAssertEqual(AppLanguagePreference.ResolvedLanguage.korean.text("가", "A"), "가")
        XCTAssertEqual(AppLanguagePreference.ResolvedLanguage.english.text("가", "A"), "A")
        XCTAssertEqual(
            AppLanguagePreference.text("가", "A"),
            AppLanguagePreference.text(korean: "가", english: "A")
        )
    }

    func testMenuOffersEveryPackLanguageAndOldValuesStillRead() {
        XCTAssertEqual(AppLanguagePreference.allCases.count, 15)
        XCTAssertEqual(AppLanguagePreference(rawValue: "korean"), .korean)
        XCTAssertEqual(AppLanguagePreference(rawValue: "automatic"), .automatic)
        XCTAssertEqual(AppLanguagePreference.german.translatedCode, "de")
        XCTAssertNil(AppLanguagePreference.korean.translatedCode)
        XCTAssertEqual(AppLanguagePreference.resolve(rawValue: "ja"), .english, "번역 언어는 영어 경로에서 언어 팩을 찾는다")
    }
}
