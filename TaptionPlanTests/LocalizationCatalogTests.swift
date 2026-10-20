import Foundation
import XCTest

final class LocalizationCatalogTests: XCTestCase {
    func testEveryCatalogKeyHasAnEnglishValue() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        // 실기기 실행에서는 소스 트리(.xcstrings)를 읽을 수 없다. 그때는 컴파일된 번들의 한국어·영어 표를 대조한다.
        guard FileManager.default.fileExists(
            atPath: root.appendingPathComponent("TaptionPlan/Localizable.xcstrings").path
        ) else {
            try verifyCompiledTables()
            return
        }
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

    /// 컴파일된 번들(앱·앱 확장·워치 앱)의 `ko`/`en` 문자열 표를 대조한다: 모든 한국어 키에 영어 값이 있고 비어 있지 않으며
    /// 형식 지정자가 같다. 확인한 표가 하나도 없으면 실패한다(아무것도 검증하지 않고 통과하는 것을 막는다).
    private func verifyCompiledTables() throws {
        var bundles = [Bundle.main]
        for directory in [Bundle.main.builtInPlugInsURL, Bundle.main.bundleURL.appendingPathComponent("Watch")] {
            guard let directory,
                  let children = try? FileManager.default.contentsOfDirectory(
                      at: directory, includingPropertiesForKeys: nil
                  ) else { continue }
            bundles += children.filter { ["appex", "app"].contains($0.pathExtension) }.compactMap(Bundle.init(url:))
        }
        var verifiedTables = 0
        for bundle in bundles {
            for table in ["Localizable", "InfoPlist"] {
                guard let koURL = bundle.url(forResource: table, withExtension: "strings", subdirectory: nil, localization: "ko"),
                      let enURL = bundle.url(forResource: table, withExtension: "strings", subdirectory: nil, localization: "en"),
                      let ko = NSDictionary(contentsOf: koURL) as? [String: String],
                      let en = NSDictionary(contentsOf: enURL) as? [String: String] else { continue }
                verifiedTables += 1
                for key in ko.keys where !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let label = "\(bundle.bundleURL.lastPathComponent) \(table): \(key)"
                    let value = try XCTUnwrap(en[key], label)
                    XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, label)
                    XCTAssertEqual(formatTypes(in: value).sorted(), formatTypes(in: key).sorted(), label)
                }
            }
        }
        XCTAssertGreaterThan(verifiedTables, 0, "컴파일된 ko/en 문자열 표를 하나도 찾지 못했다")
    }

    private func formatTypes(in value: String) -> [String] {
        let expression = try! NSRegularExpression(
            pattern: #"%(\d+\$)?(?:\.\d+)?(lld|ld|d|llu|lu|u|@|f)"#
        )
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).compactMap { match in
            guard let typeRange = Range(match.range(at: 2), in: value) else {
                return nil
            }
            return String(value[typeRange])
        }
    }
}
