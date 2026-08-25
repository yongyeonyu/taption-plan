import Foundation

public struct ActivityDetailDefinition: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let behavior: String
    public let systemImage: String
    public let automaticOnly: Bool

    public init(id: String, title: String, behavior: String, systemImage: String, automaticOnly: Bool = false) {
        self.id = id
        self.title = title
        self.behavior = behavior
        self.systemImage = systemImage
        self.automaticOnly = automaticOnly
    }
}

public struct ActivityMajorDefinition: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let details: [ActivityDetailDefinition]

    public init(id: String, title: String, systemImage: String, details: [ActivityDetailDefinition]) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.details = details
    }
}

public struct ActivityTaxonomy: Codable, Hashable, Sendable {
    public let version: Int
    public let majors: [ActivityMajorDefinition]

    public init(version: Int = 1, majors: [ActivityMajorDefinition]) {
        self.version = version
        self.majors = majors
    }

    public static let `default` = ActivityTaxonomy(version: 1, majors: [
        makeMajor("activity", "활동", "sparkles", [
            makeDetail("activity.rest", "휴식", "stationary", "pause.circle.fill"),
            makeDetail("activity.housework", "집안일", "housework", "washer.fill", true)
        ]),
        makeMajor("work", "업무", "briefcase.fill", [
            makeDetail("work.route", "업무(집 - 회사)", "work", "briefcase.fill"),
            makeDetail("work.rest", "휴식", "stationary", "pause.circle.fill"),
            makeDetail("work.walking", "걷기", "walking", "figure.walk")
        ]),
        makeMajor("study", "수업", "book.fill", [
            makeDetail("study.route", "수업(집 - 학교·학원)", "study", "book.fill"),
            makeDetail("study.rest", "휴식", "stationary", "pause.circle.fill"),
            makeDetail("study.walking", "걷기", "walking", "figure.walk")
        ]),
        makeMajor("hobby", "취미", "paintpalette.fill", [
            makeDetail("hobby.route", "취미(집 - 취미)", "hobby", "paintpalette.fill"),
            makeDetail("hobby.rest", "휴식", "stationary", "pause.circle.fill"),
            makeDetail("hobby.walking", "걷기", "walking", "figure.walk")
        ]),
        makeMajor("sleep", "수면", "moon.zzz.fill", [
            makeDetail("sleep.core", "코어 수면", "core", "moon.zzz.fill", true),
            makeDetail("sleep.deep", "깊은 수면", "deep", "moon.zzz.fill", true),
            makeDetail("sleep.rem", "REM 수면", "rem", "moon.zzz.fill", true)
        ]),
        makeMajor("movement", "이동", "figure.walk.motion", [
            makeDetail("movement.walking", "걷기", "walking", "figure.walk"),
            makeDetail("movement.running", "달리기", "running", "figure.run"),
            makeDetail("movement.car", "자동차", "automotive", "car.fill"),
            makeDetail("movement.subway", "지하철", "subway", "tram.fill"),
            makeDetail("movement.privateVehicle", "자가용", "privateVehicle", "car.fill"),
            makeDetail("movement.bus", "버스", "bus", "bus.fill"),
            makeDetail("movement.ship", "배", "ship", "ferry.fill"),
            makeDetail("movement.airplane", "비행기", "airplane", "airplane"),
            makeDetail("movement.cycling", "자전거", "cycling", "bicycle")
        ]),
        makeMajor("eating", "식사", "fork.knife", [
            makeDetail("eating.meal", "식사", "meal", "fork.knife"),
            makeDetail("eating.cooking", "요리", "cooking", "frying.pan")
        ]),
        makeMajor("exercise", "운동", "figure.strengthtraining.traditional", [
            makeDetail("exercise.workout", "운동", "exercise", "figure.strengthtraining.traditional", true)
        ]),
        makeMajor("unconfirmed", "미확인", "questionmark.circle.fill", [
            makeDetail("unconfirmed.automatic", "미확인", "unconfirmed", "questionmark.circle.fill", true)
        ])
    ])

    public func major(for id: String) -> ActivityMajorDefinition? {
        majors.first { $0.id == id }
    }

    public func detail(for id: String) -> ActivityDetailDefinition? {
        majors.lazy.compactMap { major in major.details.first { $0.id == id } }.first
    }

    public func majorID(forDetailID id: String) -> String? {
        majors.first { major in major.details.contains { $0.id == id } }?.id
    }

    public func detail(majorID: String, behavior: String) -> ActivityDetailDefinition? {
        major(for: majorID)?.details.first { $0.behavior.caseInsensitiveCompare(behavior) == .orderedSame }
    }

    public static func major(_ id: String, title: String, systemImage: String, details: [ActivityDetailDefinition]) -> ActivityMajorDefinition {
        ActivityMajorDefinition(id: id, title: title, systemImage: systemImage, details: details)
    }

    public static func detail(_ id: String, title: String, behavior: String, systemImage: String, _ automaticOnly: Bool = false) -> ActivityDetailDefinition {
        ActivityDetailDefinition(id: id, title: title, behavior: behavior, systemImage: systemImage, automaticOnly: automaticOnly)
    }
}

private func makeMajor(_ id: String, _ title: String, _ image: String, _ details: [ActivityDetailDefinition]) -> ActivityMajorDefinition {
    ActivityMajorDefinition(id: id, title: title, systemImage: image, details: details)
}

private func makeDetail(_ id: String, _ title: String, _ behavior: String, _ image: String, _ automaticOnly: Bool = false) -> ActivityDetailDefinition {
    ActivityDetailDefinition(id: id, title: title, behavior: behavior, systemImage: image, automaticOnly: automaticOnly)
}
