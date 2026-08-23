import SwiftUI
import UIKit

extension Font {
    static func taption(
        size: CGFloat,
        weight: Font.Weight = .regular
    ) -> Font {
        .system(size: size + 2, weight: weight)
    }
}

extension Color {
    // Tokyo postcard palette: a cool sky, warm paper and soft botanical
    // accents keep the timeline calm without lowering text contrast.
    static let tpInk = Color(red: 38 / 255, green: 54 / 255, blue: 75 / 255)
    static let tpSecondary = Color(red: 104 / 255, green: 120 / 255, blue: 139 / 255)
    static let tpBackground = Color(red: 247 / 255, green: 246 / 255, blue: 244 / 255)
    static let tpSurface = Color(red: 255 / 255, green: 253 / 255, blue: 248 / 255)
    static let tpSurfaceBlue = Color(red: 241 / 255, green: 248 / 255, blue: 252 / 255)
    static let tpSurfacePink = Color(red: 255 / 255, green: 242 / 255, blue: 245 / 255)
    static let tpSurfaceSage = Color(red: 241 / 255, green: 248 / 255, blue: 240 / 255)
    static let tpSurfaceLavender = Color(red: 247 / 255, green: 243 / 255, blue: 251 / 255)
    static let tpSurfaceCream = Color(red: 255 / 255, green: 249 / 255, blue: 236 / 255)
    static let tpSky = Color(red: 185 / 255, green: 221 / 255, blue: 237 / 255)
    static let tpLine = Color(red: 221 / 255, green: 231 / 255, blue: 235 / 255)
    static let tpHoliday = Color(red: 0.86, green: 0.27, blue: 0.30)
    static let tpSaturday = Color(red: 0.24, green: 0.47, blue: 0.77)
    static let tpAccent = Color(red: 0.21, green: 0.57, blue: 0.70)

    // The original product guide's ten-color set, softened by the postcard
    // surfaces above. Map Home uses these as accents rather than repainting
    // every legacy surface.
    static let tpReferenceBlue = Color(hex: "#2D9BF0")
    static let tpReferenceRose = Color(hex: "#F15C80")
    static let tpReferenceMint = Color(hex: "#48B38C")
    static let tpReferenceGray = Color(hex: "#777777")
    static let tpReferenceGold = Color(hex: "#E1C453")
    static let tpReferencePurple = Color(hex: "#B965C8")
    static let tpReferenceCyan = Color(hex: "#45CFD5")
    static let tpReferenceSand = Color(hex: "#D7A77F")
    static let tpReferenceBlush = Color(hex: "#FBBEBE")
    static let tpReferenceLeaf = Color(hex: "#8ED97E")

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

    var hexRGBString: String? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return nil
        }
        return String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }
}

/// 지도 홈·기록·설정이 같은 색을 쓰도록 묶은 자동 기록의 여덟 대분류 팔레트다.
enum CanonicalCategoryPalette {
    static let orderedIDs = [
        "activity", "work", "study", "hobby",
        "sleep", "movement", "exercise", "unconfirmed",
    ]

    static let hexes: [String: String] = [
        "activity": "#29A383",
        "work": "#2563EB",
        "study": "#00A2C7",
        "hobby": "#8B5CF6",
        "sleep": "#5B5BD6",
        "movement": "#F76B15",
        "exercise": "#DC2626",
        "unconfirmed": "#94A3B8",
    ]

    static func hex(_ id: String) -> String {
        hexes[id] ?? hexes["activity"]!
    }

    static func color(_ id: String) -> Color {
        Color(hex: hex(id))
    }
}

/// 기록 시간표와 바로 아래 범례·아이콘이 함께 쓰는 단일 색상표.
/// 해시 팔레트는 서로 다른 항목이 같은 칸에 충돌할 수 있으므로, 자동 기록과
/// 내장 카테고리는 고정 색을 갖는다.
enum RecordTimelinePalette {
    static let categoryHexes: [String: String] = [
        "calendar": "#52525B", "location": "#0284C7",
        "appUsage": "#0891B2", "weather": "#0EA5E9",
        "photo": "#9333EA", "memo": "#6B7280",
        "project": "#0F766E", "routine": "#CA8A04",
        "relationship": "#DB2777", "rest": "#7E868F",
        "travel": "#EA580C", "health": "#0D9488", "event": "#C026D3",
        "family": "#E11D48", "parenting": "#F97316",
        "finance": "#65A30D", "housing": "#78716C", "career": "#7C3AED",
        "creative": "#BE185D", "pet": "#A16207", "community": "#15803D",
        "student": "#0369A1", "exam": "#B45309", "military": "#3F6212",
        "athlete": "#B91C1C", "pregnancy": "#C2418C",
        "caregiver": "#6D28D9", "government": "#334155", "food": "#C2410C",
    ].merging(CanonicalCategoryPalette.hexes, uniquingKeysWith: { _, canonical in
        canonical
    })

    static let sleepStageHexes: [String: String] = [
        SleepStage.inBed.rawValue: "#8B8D98",
        SleepStage.awake.rawValue: "#D5A300",
        SleepStage.core.rawValue: "#3E63DD",
        SleepStage.deep.rawValue: "#4A3F8F",
        SleepStage.rem.rawValue: "#D6409F",
        SleepStage.asleepUnspecified.rawValue: "#12A594",
    ]

    static let travelHexes: [String: String] = [
        TravelMode.walking.rawValue: "#29A383",
        TravelMode.running.rawValue: "#E54666",
        TravelMode.cycling.rawValue: "#00A2C7",
        TravelMode.bus.rawValue: "#F76B15",
        TravelMode.subway.rawValue: "#8E4EC6",
        TravelMode.taxi.rawValue: "#D5A300",
        TravelMode.car.rawValue: "#3E63DD",
        TravelMode.train.rawValue: "#D6409F",
        TravelMode.airplane.rawValue: "#0C7792",
        TravelMode.ship.rawValue: "#12A594",
    ]

    static let dayPhaseHexes: [String: String] = [
        DayPhase.unconfirmed.rawValue: CanonicalCategoryPalette.hex("unconfirmed"),
        DayPhase.sleep.rawValue: CanonicalCategoryPalette.hex("sleep"),
        DayPhase.movement.rawValue: CanonicalCategoryPalette.hex("movement"),
        DayPhase.exercise.rawValue: CanonicalCategoryPalette.hex("exercise"),
        DayPhase.hobby.rawValue: CanonicalCategoryPalette.hex("hobby"),
        DayPhase.activity.rawValue: CanonicalCategoryPalette.hex("activity"),
        DayPhase.appointment.rawValue: "#8E4EC6",
        DayPhase.commuteToWork.rawValue: "#E8792F",
        DayPhase.commuteToSchool.rawValue: "#0090FF",
        DayPhase.commuteToAcademy.rawValue: "#7C66DC",
        DayPhase.activityDeparture.rawValue: "#46A758",
        DayPhase.work.rawValue: CanonicalCategoryPalette.hex("work"),
        DayPhase.study.rawValue: CanonicalCategoryPalette.hex("study"),
        DayPhase.commuteHomeFromWork.rawValue: "#E54D2E",
        DayPhase.commuteHomeFromSchool.rawValue: "#12A594",
        DayPhase.commuteHomeFromAcademy.rawValue: "#D6409F",
        DayPhase.activityReturn.rawValue: "#56A68A",
        DayPhase.evening.rawValue: "#D5A300",
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
            case .good: "#29A383"
            case .moderate: "#D5A300"
            case .bad: "#F76B15"
            case .veryBad: "#E54666"
            case nil: "#00A2C7"
            }
        case .location: "#0090FF"
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
            .background(
                LinearGradient(
                    colors: [Color.tpSurface, Color.tpSurfaceBlue.opacity(0.58)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: radius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Color.tpLine.opacity(0.72), lineWidth: 0.7)
            }
            .shadow(color: Color.tpSky.opacity(0.16), radius: 4, y: 2)
    }

    /// A lightweight pastel surface for the record and timeline cards. It
    /// avoids material blur so continuous timeline gestures stay on budget.
    func tpCardSurface(
        radius: CGFloat = 14,
        tint: Color = .tpSurfaceBlue
    ) -> some View {
        self
            .background(
                LinearGradient(
                    colors: [Color.tpSurface, tint.opacity(0.62)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: radius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Color.tpLine.opacity(0.68), lineWidth: 0.7)
            }
    }
}
