import Foundation
import Testing
@testable import SeasonPackKit

struct ManifestTests {
    @Test func parsesTheBundledChristmasSeedAndValidates() {
        let pack = Fixture.seedPack("christmas")
        #expect(pack.manifest.event.windows.count == 1)
        #expect(pack.manifest.menuIcons?.count == 1)
        #expect(pack.manifest.audio?.first?.license.source.hasPrefix("https://") == true)
        #expect(pack.manifest.lyrics?.first?.cues.count == 9)
        #expect(pack.source == .seed)
    }

    @Test func unknownKeysAndUnknownKindsAreIgnoredNotFatal() throws {
        let extra: [String: Any] = [
            "futureThing": ["x": 1],
            "menuIcons": [[
                "id": "i", "icon": "img.a", "anchor": ["dx": 1, "dy": 2], "mystery": true,
                "menu": ["sections": [["items": [
                    ["id": "ok", "kind": "text", "text": ["ko": "안녕", "en": "hi"]],
                    ["id": "future", "kind": "hologram"],
                    ["id": "bad", "kind": "link", "url": "http://insecure.example/x"],
                ]]]],
            ]],
        ]
        let built = Fixture.pack(extra: extra)
        let manifest = try JSONDecoder().decode(SeasonPackManifest.self, from: built.manifest)
        #expect(SeasonPackValidation.validate(manifest, files: built.files, appBuild: 5).isValid)
        let menu = SeasonPackMenuModel(manifest.menuIcons![0].menu, language: "ko")
        #expect(menu.sections.flatMap(\.items).map(\.id) == ["ok"]) // 모르는 kind·http 링크는 그 항목만 사라진다
    }

    @Test func missingRequiredKeyDropsOnlyThatPack() {
        let json = Data(#"{"format":"bokki-season-pack","schema":1,"id":"x","version":1,"assets":[]}"#.utf8)
        #expect((try? JSONDecoder().decode(SeasonPackManifest.self, from: json)) == nil) // event 없음
    }

    @Test func oversizedFileAndHashMismatchAreRejected() {
        let big = Data(repeating: 7, count: SeasonPackLimits.imageBytes + 1)
        let oversized = Fixture.pack(fileBytes: big)
        #expect(!SeasonPackValidation.validate(Fixture.manifest(oversized.manifest), files: oversized.files, appBuild: 1).isValid)

        let good = Fixture.pack()
        let tampered = ["a.png": Data("tampered!!".utf8)]
        #expect(SeasonPackValidation.validate(Fixture.manifest(good.manifest), files: tampered, appBuild: 1) == .invalid("bytes a.png"))
        let sameSize = ["a.png": Data("PNG-BYTES".utf8)]
        #expect(SeasonPackValidation.validate(Fixture.manifest(good.manifest), files: sameSize, appBuild: 1) == .invalid("sha256 a.png"))
        #expect(!SeasonPackValidation.validate(Fixture.manifest(good.manifest), files: [:], appBuild: 1).isValid)
    }

    @Test func newerRequiredBuildIsDeferredNotInstalled() {
        let built = Fixture.pack(requiresAppBuild: 9)
        #expect(SeasonPackValidation.validate(Fixture.manifest(built.manifest), files: built.files, appBuild: 8) == .deferred)
        #expect(SeasonPackValidation.validate(Fixture.manifest(built.manifest), files: built.files, appBuild: 9).isValid)
    }

    @Test func overlappingWindowsAndReservedIDsAreRejected() {
        let overlap = Fixture.pack(windows: [Fixture.window(12, 19, 12, 30), Fixture.window(12, 25, 1, 2)])
        #expect(SeasonPackValidation.validate(Fixture.manifest(overlap.manifest), files: overlap.files, appBuild: 1) == .invalid("windows overlap"))
        let reserved = Fixture.pack(id: "memos")
        #expect(!SeasonPackValidation.validate(Fixture.manifest(reserved.manifest), files: reserved.files, appBuild: 1).isValid)
        let year = Fixture.pack(windows: [Fixture.window(1, 1, 1, 5, year: 2026), Fixture.window(1, 3, 1, 8, year: 2027)])
        #expect(SeasonPackValidation.validate(Fixture.manifest(year.manifest), files: year.files, appBuild: 1).isValid)
    }

    @Test func unknownAssetReferenceAndBadPathsAreRejected() {
        let ref = Fixture.pack(extra: ["slots": ["house": ["base": "nope"]]])
        #expect(!SeasonPackValidation.validate(Fixture.manifest(ref.manifest), files: ref.files, appBuild: 1).isValid)
        #expect(SeasonPackValidation.isRelativePath("audio/jingle-bells.m4a"))
        for bad in ["../x.png", "/abs.png", "A.png", ".hidden", "a b.png", "a//b.png", "a/b/c/d.png"] {
            #expect(!SeasonPackValidation.isRelativePath(bad), "\(bad)")
        }
    }

    @Test func textResolvesLanguageThenEnglishThenKorean() {
        let text = SeasonPackText(["ko": "안녕", "en": "Hello", "ja": "こんにちは"])
        #expect(text.resolve(language: "ja") == "こんにちは")
        #expect(text.resolve(language: "zh-Hans") == "Hello")
        #expect(text.resolve(language: "en-GB") == "Hello")
        #expect(SeasonPackText(["ko": "안녕"]).resolve(language: "fr") == "안녕")
        #expect(SeasonPackText.ui("한", "en", language: "ko") == "한")
        #expect(SeasonPackText.ui("한", "en", language: "de") == "en")
    }

    @Test func indexParsesAndRejectsOtherFormats() {
        let ok = Data(#"{"format":"bokki-season-packs","schema":1,"packs":[{"id":"christmas","version":1,"manifest":"packs/season/christmas/1/manifest.json","requiresAppBuild":1,"updatedAt":"2026-11-19T21:00:00+09:00"}]}"#.utf8)
        #expect(SeasonPackIndex.decode(ok)?.packs.count == 1)
        #expect(SeasonPackIndex.decode(Data(#"{"format":"other","schema":1,"packs":[]}"#.utf8)) == nil)
        #expect(SeasonPackIndex.decode(Data("not json".utf8)) == nil)
    }
}
