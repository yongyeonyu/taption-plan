import Foundation
import XCTest

final class LocalizationCatalogTests: XCTestCase {
    func testEveryCatalogKeyHasAnEnglishValue() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let relativePaths = [
            "TaptionPlan/Localizable.xcstrings",
            "TaptionPlan/InfoPlist.xcstrings",
            "TaptionPlanWidget/Localizable.xcstrings",
            "TaptionPlanWidget/InfoPlist.xcstrings",
            "TaptionPlanWatch/Localizable.xcstrings",
            "TaptionPlanWatch/InfoPlist.xcstrings",
            "TaptionPlanWatchWidget/Localizable.xcstrings",
            "TaptionPlanWatchWidget/InfoPlist.xcstrings",
        ]

        for relativePath in relativePaths {
            let data = try Data(contentsOf: root.appendingPathComponent(relativePath))
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            XCTAssertEqual(object["sourceLanguage"] as? String, "ko", relativePath)
            let strings = try XCTUnwrap(object["strings"] as? [String: Any])
            XCTAssertFalse(strings.isEmpty, relativePath)

            for (key, rawEntry) in strings {
                guard !key.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty else {
                    continue
                }
                let entry = try XCTUnwrap(rawEntry as? [String: Any], key)
                let localizations = try XCTUnwrap(
                    entry["localizations"] as? [String: Any],
                    "\(relativePath): \(key)"
                )
                let english = try XCTUnwrap(
                    localizations["en"] as? [String: Any],
                    "\(relativePath): \(key)"
                )
                let unit = try XCTUnwrap(
                    english["stringUnit"] as? [String: Any],
                    "\(relativePath): \(key)"
                )
                let value = try XCTUnwrap(
                    unit["value"] as? String,
                    "\(relativePath): \(key)"
                )
                XCTAssertFalse(
                    value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "\(relativePath): \(key)"
                )
                XCTAssertEqual(
                    formatTypes(in: value).sorted(),
                    formatTypes(in: key).sorted(),
                    "\(relativePath): \(key)"
                )
            }
        }
    }

    private func formatTypes(in value: String) -> [String] {
        let expression = try! NSRegularExpression(
            pattern: #"%(?:\d+\$)?(?:lld|ld|d|llu|lu|u|@|f)"#
        )
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).compactMap { match in
            guard let range = Range(match.range, in: value) else { return nil }
            return value[range]
                .replacingOccurrences(
                    of: #"%\d+\$"#,
                    with: "%",
                    options: .regularExpression
                )
        }
    }
}
