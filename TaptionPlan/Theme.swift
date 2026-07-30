import SwiftUI

extension Color {
    static let tpInk = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let tpSecondary = Color(red: 0.43, green: 0.43, blue: 0.45)
    static let tpBackground = Color(uiColor: .systemGroupedBackground)
    static let tpProject = Color(red: 0.75, green: 0.86, blue: 0.89)
    static let tpExercise = Color(red: 1.00, green: 0.84, blue: 0.81)
    static let tpStudy = Color(red: 0.83, green: 0.78, blue: 0.90)
    static let tpRoutine = Color(red: 0.95, green: 0.90, blue: 0.72)
    static let tpPhoto = Color(red: 0.91, green: 0.84, blue: 0.93)
    static let tpNow = Color(red: 1.00, green: 0.23, blue: 0.19)
}

extension PlanCategory {
    var color: Color {
        switch self {
        case .movement: Color(red: 0.91, green: 0.83, blue: 0.70)
        case .location: Color(red: 0.85, green: 0.91, blue: 0.95)
        case .photo: .tpPhoto
        case .project: .tpProject
        case .exercise: .tpExercise
        case .study: .tpStudy
        case .hobby: Color(red: 0.77, green: 0.91, blue: 0.85)
        case .sleep: Color(red: 0.85, green: 0.87, blue: 0.92)
        case .routine: .tpRoutine
        case .relationship: Color(red: 0.96, green: 0.84, blue: 0.91)
        case .rest: Color(red: 0.86, green: 0.91, blue: 0.89)
        case .travel: Color(red: 0.95, green: 0.71, blue: 0.60)
        case .health: Color(red: 0.78, green: 0.87, blue: 0.76)
        }
    }

    var systemImage: String {
        switch self {
        case .movement: "figure.walk"
        case .location: "mappin.and.ellipse"
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
        }
    }
}
