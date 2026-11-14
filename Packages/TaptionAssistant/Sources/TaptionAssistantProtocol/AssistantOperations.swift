import Foundation

// 동작 등록부(ACT1114A07). 새 동작은 (1) 서버 `server/trip-relay/src/actions.js`에 `.add(...)`,
// (2) 여기 패키지에 읽기 형 하나(`spec`·`init?(fields:)`)와 묶음 배열의 한 줄, (3) 앱에 그 형의 `apply(host:)` extension.
// 토글·알림 수·안내문·로그 이름은 `spec`에서 만들어진다. 서버와 이름·칸이 같은지는 `server/trip-relay/test/fixtures/actions.json`으로 앱 시험이 본다.

/// 앱이 아는 등록부 동작. 목록은 컴파일 때 정해지는 값이라 등록 차례에 기대는 것이 없다(RMN1114A25).
public enum AssistantOperations {
    /// 등록부 동작 전부. 여기 차례가 「AI가 할 수 있는 일」과 안내문의 차례다.
    public static let all: [any AssistantOperationReading.Type] = ledger + plans + records + photos + catalog + system + direct

    private static let byName = Dictionary(all.map { ($0.spec.name, $0) }, uniquingKeysWith: { first, _ in first })

    public static func spec(_ name: String) -> AssistantOperationSpec? { byName[name]?.spec }

    /// 형식·버전을 보고, 그 동작의 칸만 남겨 읽는다.
    public static func parse(_ fields: AssistantFields) -> AssistantParsedOperation? {
        guard fields.raw("format") == "bokki-command", fields.values["version"] == .number(1),
              let name = fields.name, let type = byName[name] else { return nil }
        var kept = fields
        kept.values = fields.values.filter { type.spec.fields.contains($0.key) && $0.value != .null }
        return type.init(fields: kept).map { AssistantParsedOperation(name: name, values: kept.values, operation: $0) }
    }

    /// 연결 안내에 붙는 줄들.
    public static func guide(command: String) -> String {
        // 칸이 없는 동작의 안내는 `}`로 시작한다.
        all.map { "  \(command)\"\($0.spec.name)\"\($0.spec.fields.isEmpty ? "" : ",")\($0.spec.guide)" }.joined(separator: "\n")
    }
}

extension AssistantFields {
    /// 정해진 이름 가운데 하나. 글이 아니거나 목록에 없으면 nil.
    public func choice(_ name: String, among names: [String]) -> String? {
        raw(name).flatMap { names.contains($0) ? $0 : nil }
    }
}
