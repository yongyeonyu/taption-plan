import Foundation

/// AI가 보태는 결제 문자 읽기 규칙 하나(PRL1112A01). 저장 꼴(JSON 키)은 앱의 `LedgerMessageRules.Rule` 그대로다.
/// 견본 검사·맞춰 보기·저장은 앱의 `LedgerMessageRules`에 있다.
public struct LedgerMessageRule: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case expense, income, ignore }

    public var id = UUID()
    public var name: String
    /// ICU 정규식. 이름 붙은 묶음: amount(필수, ignore는 없어도 됨)·merchant·month·day·hour·minute·currency.
    public var pattern: String
    public var sample: String
    public var kind: Kind
    public var createdAt = Date()

    public init(id: UUID = UUID(), name: String, pattern: String, sample: String, kind: Kind, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.sample = sample
        self.kind = kind
        self.createdAt = createdAt
    }
}
