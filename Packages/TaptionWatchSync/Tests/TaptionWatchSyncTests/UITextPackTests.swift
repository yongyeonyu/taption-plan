import XCTest
@testable import TaptionWatchSync

final class UITextPackTests: XCTestCase {
    private func phrase(_ template: String, _ text: String, _ arguments: [String]) -> UIPhrase {
        UIPhrase(text: text, template: template, arguments: arguments)
    }

    func testLiteralLooksUpByKoreanAndEnglish() {
        let table = ["가|A": "あ"]
        let result = UITextPack.translate(korean: "가", english: "A") { table[$0] }
        XCTAssertEqual(result, "あ")
    }

    func testMissingKeyFallsBackToEnglish() {
        XCTAssertEqual(UITextPack.translate(korean: "가", english: "A") { _ in nil }, "A")
    }

    func testEnglishOnlyTableIsSecondChoice() {
        let table = ["|A": "あ"]
        XCTAssertEqual(UITextPack.translate(korean: "가", english: "A") { table[$0] }, "あ")
    }

    func testVariablesUseEnglishArgumentsAndMayReorder() {
        let table = ["{0}부터 {1}까지|from {0} to {1}": "{1}まで{0}から"]
        let result = UITextPack.translate(
            korean: phrase("{0}부터 {1}까지", "1부터 2까지", ["1", "2"]),
            english: phrase("from {0} to {1}", "from 1 to 2", ["1", "2"])
        ) { table[$0] }
        XCTAssertEqual(result, "2まで1から")
    }

    func testTranslationMayDropEnglishPluralTail() {
        let result = UITextPack.fill("{0}日", with: ["3", "s"])
        XCTAssertEqual(result, "3日")
    }

    func testPlaceholderInsideArgumentIsNotReplacedTwice() {
        XCTAssertEqual(UITextPack.fill("{0} {1}", with: ["{1}", "b"]), "{1} b")
    }

    func testKoreanAndEnglishBundlesSkipLookup() {
        XCTAssertNil(UITextPack.translatedCode(preferred: "ko"))
        XCTAssertNil(UITextPack.translatedCode(preferred: "en"))
        XCTAssertNil(UITextPack.translatedCode(preferred: "en-GB"))
        XCTAssertNil(UITextPack.translatedCode(preferred: "Base"))
        XCTAssertNil(UITextPack.translatedCode(preferred: nil))
        XCTAssertEqual(UITextPack.translatedCode(preferred: "ja"), "ja")
        XCTAssertEqual(UITextPack.translatedCode(preferred: "zh-Hant"), "zh-Hant")
    }

    func testResolvedLanguageKeepsKoreanAndEnglishResults() {
        let count = 3
        XCTAssertEqual(AppLanguagePreference.ResolvedLanguage.korean.text("\(count)개", "\(count) items"), "3개")
        XCTAssertEqual(AppLanguagePreference.ResolvedLanguage.english.text("\(count)개", "\(count) items"), "3 items")
        let korean = "값", english = "Value"
        XCTAssertEqual(AppLanguagePreference.ResolvedLanguage.english.text(korean, english), "Value")
        XCTAssertEqual(AppLanguagePreference.ResolvedLanguage.korean.text(korean, english), "값")
    }
}

final class AppRegionTests: XCTestCase {
    func testCurrencyFollowsLanguageAndMatchingRegion() {
        let cases: [(String, String?, String)] = [
            ("ko", "KR", "KRW"), ("ko", "US", "KRW"), ("en", "US", "USD"), ("en", "KR", "USD"),
            ("en", "GB", "GBP"), ("es", "MX", "MXN"), ("es", "ES", "EUR"), ("de", "CH", "CHF"),
            ("de", "DE", "EUR"), ("ja", "JP", "JPY"), ("ja", nil, "JPY"), ("ja", "KR", "JPY"),
            ("zh-Hans", "CN", "CNY"), ("zh-Hant", "TW", "TWD"), ("zh-Hant", "HK", "HKD"),
            ("zh-Hans", "TW", "CNY"), ("pt-BR", "BR", "BRL"), ("pt-BR", "PT", "EUR"),
            ("fr", "FR", "EUR"), ("it", "IT", "EUR"), ("vi", "VN", "VND"), ("id", "ID", "IDR"),
            ("th", "TH", "THB"), ("hi", "IN", "INR"),
        ]
        for (language, region, currency) in cases {
            XCTAssertEqual(
                AppRegion(languageCode: language, deviceRegion: region).currencyCode,
                currency,
                "\(language) \(region ?? "-")"
            )
        }
    }

    func testOverseasMeansNotWon() {
        XCTAssertFalse(AppRegion(languageCode: "ko", deviceRegion: "KR").isOverseas)
        XCTAssertTrue(AppRegion(languageCode: "en", deviceRegion: "KR").isOverseas)
    }

    func testMoneyKeepsKoreanFormatAndNumbers() {
        XCTAssertEqual(AppRegion(languageCode: "ko", deviceRegion: "KR").moneyText(1_234_567.4), "1,234,567원")
        let usd = AppRegion(languageCode: "en", deviceRegion: "US")
        XCTAssertEqual(usd.moneyText(15.5), "$15.50")
        XCTAssertEqual(usd.currencyUnit, "$")
        XCTAssertTrue(usd.usesDecimalCurrency)
        XCTAssertFalse(AppRegion(languageCode: "ja", deviceRegion: "JP").usesDecimalCurrency)
    }

    func testAmountReadsLocalDecimalSeparator() {
        XCTAssertEqual(AppRegion(languageCode: "de", deviceRegion: "DE").amount(from: "15,5"), 15.5)
        XCTAssertEqual(AppRegion(languageCode: "en", deviceRegion: "US").amount(from: "15.5"), 15.5)
    }

    func testUnitsFollowRegion() {
        let korea = AppRegion(languageCode: "ko", deviceRegion: "KR")
        XCTAssertEqual(korea.distanceText(meters: 4_200), "4.2 km")
        XCTAssertEqual(korea.distanceText(meters: 4_200, compact: true), "4.2km")
        XCTAssertEqual(korea.distanceText(meters: 300), "300 m")
        XCTAssertEqual(korea.temperature(celsius: 20), 20)
        let america = AppRegion(languageCode: "en", deviceRegion: "US")
        XCTAssertEqual(america.distanceText(meters: 1_609.344), "1.0 mi")
        XCTAssertEqual(america.temperature(celsius: 20), 68)
        XCTAssertEqual(america.speedText(metersPerSecond: 10), "22.4 mph")
        let britain = AppRegion(languageCode: "en", deviceRegion: "GB")
        XCTAssertTrue(britain.usesMiles)
        XCTAssertEqual(britain.temperature(celsius: 20), 20)
        XCTAssertFalse(AppRegion(languageCode: "de", deviceRegion: "DE").usesMiles)
    }
}
