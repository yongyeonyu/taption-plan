import SwiftUI

extension Font {
    static func taption(
        size: CGFloat,
        weight: Font.Weight = .regular
    ) -> Font {
        .system(size: size + 2, weight: weight)
    }
}

extension Color {
    static let tpInk = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let tpSecondary = Color(red: 0.43, green: 0.43, blue: 0.45)
    static let tpBackground = Color(red: 0.97, green: 0.97, blue: 0.98)
    static let tpLine = Color(red: 0.90, green: 0.90, blue: 0.92)

    static let tpProject = Color(red: 190 / 255, green: 218 / 255, blue: 227 / 255)
    static let tpHobby = Color(red: 196 / 255, green: 233 / 255, blue: 218 / 255)
    static let tpExercise = Color(red: 254 / 255, green: 213 / 255, blue: 207 / 255)
    static let tpMovement = Color(red: 232 / 255, green: 211 / 255, blue: 179 / 255)
    static let tpStudy = Color(red: 211 / 255, green: 199 / 255, blue: 230 / 255)
    static let tpSleep = Color(red: 217 / 255, green: 221 / 255, blue: 234 / 255)
    static let tpRoutine = Color(red: 243 / 255, green: 230 / 255, blue: 184 / 255)
    static let tpRelationship = Color(red: 244 / 255, green: 215 / 255, blue: 231 / 255)
    static let tpRest = Color(red: 220 / 255, green: 233 / 255, blue: 226 / 255)
    static let tpTravel = Color(red: 241 / 255, green: 181 / 255, blue: 152 / 255)
    static let tpHealthArea = Color(red: 200 / 255, green: 223 / 255, blue: 195 / 255)
    static let tpEvent = Color(red: 245 / 255, green: 221 / 255, blue: 238 / 255)
    static let tpWeather = Color(red: 221 / 255, green: 234 / 255, blue: 248 / 255)
    static let tpPhoto = Color(red: 231 / 255, green: 215 / 255, blue: 238 / 255)
    static let tpPlace = Color(red: 216 / 255, green: 232 / 255, blue: 242 / 255)
    static let tpTransit = Color(red: 243 / 255, green: 223 / 255, blue: 192 / 255)

    static let tpProjectDark = Color(red: 74 / 255, green: 144 / 255, blue: 176 / 255)
    static let tpHobbyDark = Color(red: 63 / 255, green: 169 / 255, blue: 124 / 255)
    static let tpExerciseDark = Color(red: 226 / 255, green: 96 / 255, blue: 76 / 255)
    static let tpMovementDark = Color(red: 157 / 255, green: 117 / 255, blue: 61 / 255)
    static let tpStudyDark = Color(red: 123 / 255, green: 94 / 255, blue: 167 / 255)
    static let tpSleepDark = Color(red: 98 / 255, green: 106 / 255, blue: 131 / 255)
    static let tpRoutineDark = Color(red: 162 / 255, green: 122 / 255, blue: 22 / 255)
    static let tpRelationshipDark = Color(red: 180 / 255, green: 91 / 255, blue: 136 / 255)
    static let tpRestDark = Color(red: 77 / 255, green: 128 / 255, blue: 104 / 255)
    static let tpTravelDark = Color(red: 217 / 255, green: 123 / 255, blue: 47 / 255)
    static let tpHealthDark = Color(red: 95 / 255, green: 141 / 255, blue: 91 / 255)
    static let tpEventDark = Color(red: 157 / 255, green: 93 / 255, blue: 134 / 255)
    static let tpWeatherDark = Color(red: 79 / 255, green: 120 / 255, blue: 151 / 255)
    static let tpPhotoDark = Color(red: 142 / 255, green: 90 / 255, blue: 168 / 255)
    static let tpPlaceDark = Color(red: 53 / 255, green: 124 / 255, blue: 165 / 255)
    static let tpTransitDark = Color(red: 154 / 255, green: 106 / 255, blue: 45 / 255)
    static let tpNow = Color(red: 1.00, green: 59 / 255, blue: 48 / 255)

    init(hex: String) {
        let clean = hex
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&value)
        let red: Double
        let green: Double
        let blue: Double
        switch clean.count {
        case 3:
            red = Double((value >> 8) * 17) / 255
            green = Double((value >> 4 & 0xF) * 17) / 255
            blue = Double((value & 0xF) * 17) / 255
        default:
            red = Double(value >> 16 & 0xFF) / 255
            green = Double(value >> 8 & 0xFF) / 255
            blue = Double(value & 0xFF) / 255
        }
        self.init(red: red, green: green, blue: blue)
    }
}

/// 기록 시간표와 바로 아래 범례·아이콘이 함께 쓰는 단일 색상표.
/// 해시 팔레트는 서로 다른 항목이 같은 칸에 충돌할 수 있으므로, 자동 기록과
/// 내장 카테고리는 고정 색을 갖는다.
enum RecordTimelinePalette {
    static let categoryHexes: [String: String] = [
        "calendar": "#52525B", "location": "#0284C7",
        "movement": "#D97706", "sleep": "#4F46E5",
        "activity": "#16A34A", "appUsage": "#0891B2",
        "weather": "#0EA5E9", "photo": "#9333EA", "memo": "#6B7280",
        "unconfirmed": "#CBD5E1",
        "project": "#0F766E", "exercise": "#DC2626", "study": "#4338CA",
        "hobby": "#059669", "routine": "#CA8A04",
        "relationship": "#DB2777", "rest": "#64748B",
        "travel": "#EA580C", "health": "#0D9488", "event": "#C026D3",
        "work": "#2563EB", "family": "#E11D48", "parenting": "#F97316",
        "finance": "#65A30D", "housing": "#78716C", "career": "#7C3AED",
        "creative": "#BE185D", "pet": "#A16207", "community": "#15803D",
        "student": "#0369A1", "exam": "#B45309", "military": "#3F6212",
        "athlete": "#B91C1C", "pregnancy": "#C2418C",
        "caregiver": "#6D28D9", "government": "#334155", "food": "#C2410C",
    ]

    static let sleepStageHexes: [String: String] = [
        SleepStage.inBed.rawValue: "#94A3B8",
        SleepStage.awake.rawValue: "#F59E0B",
        SleepStage.core.rawValue: "#3B82F6",
        SleepStage.deep.rawValue: "#312E81",
        SleepStage.rem.rawValue: "#D946EF",
        SleepStage.asleepUnspecified.rawValue: "#14B8A6",
    ]

    static let travelHexes: [String: String] = [
        TravelMode.walking.rawValue: "#65A30D",
        TravelMode.running.rawValue: "#DC2626",
        TravelMode.cycling.rawValue: "#0891B2",
        TravelMode.bus.rawValue: "#F97316",
        TravelMode.subway.rawValue: "#7C3AED",
        TravelMode.taxi.rawValue: "#EAB308",
        TravelMode.car.rawValue: "#2563EB",
        TravelMode.train.rawValue: "#BE123C",
        TravelMode.airplane.rawValue: "#0EA5E9",
        TravelMode.ship.rawValue: "#0F766E",
    ]

    static let dayPhaseHexes: [String: String] = [
        DayPhase.sleep.rawValue: "#4338CA",
        DayPhase.commuteToWork.rawValue: "#EA580C",
        DayPhase.commuteToSchool.rawValue: "#0284C7",
        DayPhase.commuteToAcademy.rawValue: "#7C3AED",
        DayPhase.activityDeparture.rawValue: "#65A30D",
        DayPhase.work.rawValue: "#1E3A8A",
        DayPhase.study.rawValue: "#2563EB",
        DayPhase.commuteHomeFromWork.rawValue: "#DC2626",
        DayPhase.commuteHomeFromSchool.rawValue: "#0891B2",
        DayPhase.commuteHomeFromAcademy.rawValue: "#DB2777",
        DayPhase.activityReturn.rawValue: "#15803D",
        DayPhase.evening.rawValue: "#CA8A04",
    ]

    static func categoryColor(_ id: String, fallbackHex: String? = nil) -> Color {
        Color(hex: categoryHexes[id] ?? fallbackHex ?? "#475569")
    }

    static func detailColor(_ kind: RecordClockDetailKind, token: String) -> Color {
        let hex = switch kind {
        case .dayPhase: dayPhaseHexes[token]
        case .sleepStage: sleepStageHexes[token]
        case .travel: travelHexes[token]
        case .weather:
            switch WeatherClockToken.airGrade(token) {
            case .good: "#16A34A"
            case .moderate: "#CA8A04"
            case .bad: "#EA580C"
            case .veryBad: "#DC2626"
            case nil: "#0EA5E9"
            }
        case .location: "#0284C7"
        }
        return Color(hex: hex ?? "#475569")
    }
}

extension CategoryIcon {
    var systemImage: String {
        switch self {
        case .briefcase: "briefcase"
        case .building: "building.2"
        case .book: "book"
        case .graduation: "graduationcap"
        case .target: "target"
        case .award: "medal"
        case .stroller: "stroller"
        case .family: "person.2"
        case .shield: "shield"
        case .health: "heart.text.square"
        case .exercise: "dumbbell"
        case .sleep: "moon.zzz"
        case .performance: "theatermasks"
        case .music: "music.note"
        case .travel: "airplane"
        case .location: "mappin.and.ellipse"
        case .photo: "photo"
        case .home: "house"
        case .meal: "fork.knife"
        case .cafe: "cup.and.saucer"
        case .pet: "pawprint"
        case .shopping: "bag"
        case .nature: "leaf"
        case .calendar: "calendar"
        case .event: "sparkles"
        case .memo: "note.text"
        case .movement: "figure.walk.motion"
        case .activity: "figure.run"
        case .relationship: "heart"
        case .work: "desktopcomputer"
        case .community: "person.3"
        case .student: "person.crop.rectangle"
        case .exam: "checkmark.seal"
        case .military: "shield.lefthalf.filled"
        case .athlete: "figure.strengthtraining.traditional"
        case .pregnancy: "figure.and.child.holdinghands"
        case .caregiver: "hands.sparkles"
        case .government: "building.columns"
        case .food: "takeoutbag.and.cup.and.straw"
        }
    }
}

extension PlanCategory {
    var color: Color {
        switch self {
        case .movement: .tpMovement
        case .location: .tpPlace
        case .activity: .tpHealthArea
        case .photo: .tpPhoto
        case .project: .tpProject
        case .exercise: .tpExercise
        case .study: .tpStudy
        case .hobby: .tpHobby
        case .sleep: .tpSleep
        case .routine: .tpRoutine
        case .relationship: .tpRelationship
        case .rest: .tpRest
        case .travel: .tpTravel
        case .health: .tpHealthArea
        case .event: .tpEvent
        }
    }

    var darkColor: Color {
        switch self {
        case .movement: .tpMovementDark
        case .location: .tpPlaceDark
        case .activity: .tpHealthDark
        case .photo: .tpPhotoDark
        case .project: .tpProjectDark
        case .exercise: .tpExerciseDark
        case .study: .tpStudyDark
        case .hobby: .tpHobbyDark
        case .sleep: .tpSleepDark
        case .routine: .tpRoutineDark
        case .relationship: .tpRelationshipDark
        case .rest: .tpRestDark
        case .travel: .tpTravelDark
        case .health: .tpHealthDark
        case .event: .tpEventDark
        }
    }

    var systemImage: String {
        switch self {
        case .movement: "figure.walk"
        case .location: "mappin.and.ellipse"
        case .activity: "figure.run"
        case .photo: "photo"
        case .project: "briefcase"
        case .exercise: "figure.run"
        case .study: "book"
        case .hobby: "paintpalette"
        case .sleep: "moon.zzz"
        case .routine: "house"
        case .relationship: "person.2"
        case .rest: "cup.and.saucer"
        case .travel: "airplane"
        case .health: "heart.text.square"
        case .event: "sparkles"
        }
    }
}

extension View {
    func draftCard(radius: CGFloat = 14) -> some View {
        self
            .background(Color.white, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
    }
}
