import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// 계획 입력 화면이 추천에 쓰는 맥락. 기기 안에서만 쓰고 저장하지 않는다.
struct PlanTextContext: Equatable, Sendable {
    var categoryName: String
    var middleCategoryName = ""
    var subCategoryName = ""
    var startAt: Date
    var durationMinutes: Int
    var recentTitles: [String] = []
    var isGoal = false
}

struct PlanTextSuggestion: Equatable, Sendable {
    var titles: [String]
    var memo: String

    static let empty = PlanTextSuggestion(titles: [], memo: "")
}

/// 프롬프트를 만들고 모델 결과를 화면에 넣을 수 있게 다듬는다.
enum PlanTextSuggestionFormat {
    static let maxTitles = 3
    static let maxTitleLength = 20
    static let maxMemoLength = 80
    static let maxRecentTitles = 5

    static func instructions(preference: AppLanguagePreference = .current) -> String {
        AppLanguagePreference.text(
            korean: "너는 일정 앱의 입력 도우미다. 사용자가 고를 짧은 일정 제목과 한 줄 메모를 한국어로 제안한다. 맥락에 없는 사실은 지어내지 않는다.",
            english: "You help fill in a planner. Suggest short plan titles and a one-line memo in English. Do not invent facts that are not in the context.",
            preference: preference
        )
    }

    static func prompt(
        for context: PlanTextContext,
        preference: AppLanguagePreference = .current
    ) -> String {
        let start = context.startAt.formatted(date: .omitted, time: .shortened)
        let recent = context.recentTitles
            .prefix(maxRecentTitles)
            .joined(separator: ", ")
        let kind = context.isGoal
            ? AppLanguagePreference.text(korean: "반복 루틴", english: "recurring routine", preference: preference)
            : AppLanguagePreference.text(korean: "일정", english: "plan", preference: preference)
        var lines = [
            AppLanguagePreference.text(korean: "종류: \(kind)", english: "Kind: \(kind)", preference: preference),
            AppLanguagePreference.text(korean: "대분류: \(context.categoryName)", english: "Category: \(context.categoryName)", preference: preference),
            AppLanguagePreference.text(korean: "시작: \(start), 길이: \(context.durationMinutes)분", english: "Start: \(start), length: \(context.durationMinutes) min", preference: preference),
        ]
        if !context.middleCategoryName.isEmpty {
            lines.append(AppLanguagePreference.text(korean: "중분류: \(context.middleCategoryName)", english: "Subcategory: \(context.middleCategoryName)", preference: preference))
        }
        if !context.subCategoryName.isEmpty {
            lines.append(AppLanguagePreference.text(korean: "세부: \(context.subCategoryName)", english: "Detail: \(context.subCategoryName)", preference: preference))
        }
        if !recent.isEmpty {
            lines.append(AppLanguagePreference.text(korean: "최근 제목: \(recent)", english: "Recent titles: \(recent)", preference: preference))
        }
        lines.append(AppLanguagePreference.text(
            korean: "제목 후보 \(maxTitles)개(각 \(maxTitleLength)자 이내)와 메모 한 줄(\(maxMemoLength)자 이내)을 제안해라.",
            english: "Suggest \(maxTitles) titles (under \(maxTitleLength) characters each) and a one-line memo (under \(maxMemoLength) characters).",
            preference: preference
        ))
        return lines.joined(separator: "\n")
    }

    static func cleaned(titles: [String], memo: String) -> PlanTextSuggestion {
        var seen = Set<String>()
        let cleanTitles = titles
            .map { clip(oneLine($0), to: maxTitleLength) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        return PlanTextSuggestion(
            titles: Array(cleanTitles.prefix(maxTitles)),
            memo: clip(oneLine(memo), to: maxMemoLength)
        )
    }

    private static func oneLine(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'“”‘’-•·")))
    }

    private static func clip(_ text: String, to length: Int) -> String {
        text.count > length ? String(text.prefix(length)) : text
    }
}

/// 지원 기기에서만 Apple 온디바이스 모델을 쓴다. 미지원이면 nil을 돌려 화면은 공란으로 둔다.
enum PlanTextSuggester {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    @MainActor
    static func suggest(for context: PlanTextContext) async -> PlanTextSuggestion? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), isAvailable {
            return await FoundationPlanTextSuggester.suggest(for: context)
        }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct PlanTextDraft {
    @Guide(description: "짧은 일정 제목 후보 최대 3개 / up to 3 short plan titles")
    var titles: [String]
    @Guide(description: "한 줄 메모 / one-line memo")
    var memo: String
}

@available(iOS 26.0, *)
enum FoundationPlanTextSuggester {
    @MainActor
    static func suggest(for context: PlanTextContext) async -> PlanTextSuggestion? {
        let session = LanguageModelSession(instructions: PlanTextSuggestionFormat.instructions())
        do {
            let response = try await session.respond(
                to: PlanTextSuggestionFormat.prompt(for: context),
                generating: PlanTextDraft.self
            )
            let result = PlanTextSuggestionFormat.cleaned(
                titles: response.content.titles,
                memo: response.content.memo
            )
            return result == .empty ? nil : result
        } catch {
            return nil
        }
    }
}
#endif
