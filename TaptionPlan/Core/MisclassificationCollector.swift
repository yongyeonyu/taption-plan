import Foundation
import Synchronization
import TaptionPlanCore
import TaptionPlanStore

/// 오분류 교정 표본의 옵트인·곁 파일 저장·요약·초기화·내보내기(MSC1119A01).
/// `Application Support/MisclassificationSamples/samples.jsonl` 한 줄에 표본 하나(JSONL, UTF-8). SQLite·백업·iCloud·스냅숏에는 넣지 않는다.
/// 켜 두지 않으면(기본 꺼짐) 파일조차 만들지 않는다. 판정은 `capture` 안에서 한 번만 한다.
struct MisclassificationCollector {
    struct Summary {
        var total: Int
        var activity: Int
        var travel: Int
        /// 사용자 분류 코드별 건수, 많은 순 5개. 날짜·시각은 세지 않는다.
        var topCorrected: [(code: String, count: Int)]
    }

    static let enabledKey = "misclassificationCollectionEnabled"
    static let maximumSamples = 5_000
    /// 읽고 고쳐 쓰는 사이에 다른 쓰기가 끼지 않게 한다.
    private static let gate = Mutex(())

    let directory: URL
    let defaults: UserDefaults
    let maximumSamples: Int

    init(directory: URL, defaults: UserDefaults = .standard, maximumSamples: Int = Self.maximumSamples) {
        self.directory = directory
        self.defaults = defaults
        self.maximumSamples = max(1, maximumSamples)
    }

    static var live: MisclassificationCollector {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return MisclassificationCollector(directory: base.appendingPathComponent("MisclassificationSamples", isDirectory: true))
    }

    private var fileURL: URL { directory.appendingPathComponent("samples.jsonl") }

    // MARK: 옵트인(기본 꺼짐)

    var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }
    func setEnabled(_ on: Bool) { defaults.set(on, forKey: Self.enabledKey) }

    // MARK: 쓰기

    /// 켜져 있을 때만 표본 한 건을 만들어 붙인다. 꺼져 있으면 아무 파일도 만들지 않고 nil.
    /// 같은 구간을 다시 고쳐도 새 표본을 하나 더 넣는다(날짜 없는 형식이라 합칠 열쇠가 없고, 다른 날 같은 시각의 교정이 사라지지 않게).
    @discardableResult
    func capture(
        kind: MisclassificationSample.Kind,
        span: TimeSpan,
        readings: [SensorReading],
        predicted: String,
        predictedDetail: String?,
        predictedConfidence: String?,
        predictedScore: Double?,
        corrected: String,
        correctedDetail: String?,
        correctedIsCustom: Bool,
        travelDistanceMeters: Double? = nil,
        calendar: Calendar = .autoupdatingCurrent
    ) -> MisclassificationSample? {
        guard isEnabled else { return nil }
        let sample = MisclassificationSample.build(
            kind: kind, span: span, readings: readings,
            predicted: predicted, predictedDetail: predictedDetail,
            predictedConfidence: predictedConfidence, predictedScore: predictedScore,
            corrected: corrected, correctedDetail: correctedDetail, correctedIsCustom: correctedIsCustom,
            ruleVersion: ClassificationRules.version, calendar: calendar,
            knownBehaviors: Self.catalogBehaviors, travelDistanceMeters: travelDistanceMeters
        )
        guard append(sample) else { return nil }
        return sample
    }

    /// 분류표에 있는 behavior 코드. 사람이 만든 이름이 상세 코드 자리로 새지 않게 이것만 통과시킨다.
    static let catalogBehaviors: Set<String> = Set(RecordClassificationCatalog.categories.flatMap(\.details).map(\.behavior))

    private func append(_ sample: MisclassificationSample) -> Bool {
        Self.gate.withLock { _ in
            do {
                var lines = readLines()
                guard let data = try? JSONEncoder.line.encode(sample) else { return false }
                lines.append(data)
                if lines.count > maximumSamples { lines.removeFirst(lines.count - maximumSamples) }
                try write(lines)
                return true
            } catch {
                return false
            }
        }
    }

    // MARK: 읽기

    func samples(limit: Int? = nil) -> [MisclassificationSample] {
        let all = Self.gate.withLock { _ in readLines() }.compactMap { try? JSONDecoder().decode(MisclassificationSample.self, from: $0) }
        guard let limit, limit >= 0, all.count > limit else { return all }
        return Array(all.suffix(limit))
    }

    func summary() -> Summary {
        let all = samples()
        let counts = Dictionary(grouping: all, by: \.corrected).mapValues(\.count)
        let top = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(5).map { (code: $0.key, count: $0.value) }
        return Summary(total: all.count, activity: all.filter { $0.kind == .activity }.count, travel: all.filter { $0.kind == .travel }.count, topCorrected: top)
    }

    /// 내보내기·나중의 `POST /classifier-samples` 본문과 같은 JSON.
    func exportPayload() -> Data { MisclassificationSample.exportData(samples(), ruleVersion: ClassificationRules.version) }

    /// 파일을 지운다. 다음 `capture` 때 다시 만든다.
    func removeAll() {
        Self.gate.withLock { _ in _ = try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: 파일

    /// 깨진 줄은 읽을 때 건너뛴다. 여기서는 줄 단위로만 나눈다.
    private func readLines() -> [Data] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return data.split(separator: UInt8(ascii: "\n")).map { Data($0) }.filter { !$0.isEmpty }
    }

    private func write(_ lines: [Data]) throws {
        var folder = directory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        var body = Data()
        for line in lines { body.append(line); body.append(UInt8(ascii: "\n")) }
        try body.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

private extension JSONEncoder {
    /// 한 줄에 하나라 줄바꿈이 없는 압축 형식.
    static var line: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
