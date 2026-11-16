import Foundation
import SwiftUI

enum MapHomeStickmanAction: String, CaseIterable, Hashable, Sendable {
    case activity
    case computer
    case company
    case school
    case reading
    case hobby
    case sleeping
    case deepSleep, remSleep
    case recovery, medication
    case restStarfish, restCroissant, restDonut, restLoaf, restBox
    case movement
    case eating
    case exercise
    case unconfirmed
    case mapReading
    case walkInPlace
    case workWalking
    case meeting
    case dishes
    case coffee
    case walking
    case running
    case car
    case subway
    case train
    case privateVehicle
    case bus
    case ship
    case airplane
    case cycling
    case health
    case shower
    case housework
    case nap, cooking, groceries, laundry, friends, date, family, phoneCall
    case meditation, hospital, salon, bookReading, game, music, video, petCare

    var isMoving: Bool {
        switch self {
        case .movement, .walking, .running, .car, .subway, .train,
             .privateVehicle, .bus, .ship, .airplane, .cycling:
            true
        default:
            false
        }
    }

    /// 대표 지시: 행동 분류마다 화랑이 장면이 전부 달라야 한다.
    var hwarangScene: HwarangScene {
        switch self {
        case .running: .runLoop
        case .cycling: .bicycle
        case .train: .train
        case .movement, .walking: .stroll
        case .car, .privateVehicle: .carFront
        case .subway: .subway
        case .bus: .bus
        case .ship: .boat
        case .airplane: .airplane
        case .shower: .shower
        case .housework: .robotVacuum
        case .nap: .nap
        case .cooking: .cook
        case .groceries: .groceries
        case .laundry: .laundry
        case .friends: .friends
        case .date: .date
        case .family: .family
        case .phoneCall: .phoneCall
        case .meditation: .meditate
        case .hospital: .hospital
        case .salon: .salon
        case .bookReading: .readBook
        case .game: .game
        case .music: .music
        case .video: .video
        case .petCare: .petCare
        case .sleeping: .sleep
        case .deepSleep: .sleepBelly
        case .recovery: .recoverySuperman
        case .medication: .medicated
        case .restStarfish: .restStarfish
        case .restCroissant: .restCroissant
        case .restDonut: .restDonut
        case .restLoaf: .restLoaf
        case .restBox: .restBox
        case .remSleep: .sleepEyeMask
        case .eating: .eat
        case .computer, .company: .work
        case .reading, .school: .study
        case .hobby: .yarn
        case .exercise: .wheel
        case .health: .stretch
        case .activity: .groom
        case .unconfirmed: .confused
        case .mapReading: .atlas
        case .meeting: .meeting
        case .dishes: .dishes
        case .coffee: .coffee
        case .walkInPlace: .walkLoop
        case .workWalking: .walkLaptop
        }
    }

    /// 설정 키: 재생 때 탈것을 탄 화랑이를 보여 줄지.
    static let vehicleDisplayKey = "mapHome.showsVehicleRides"
    static let runningSpeedMetersPerSecond = 2.2

    /// 지도 마커 장면. 탈것 표시가 꺼져 있으면 속도에 따라 걷거나 뛰기만 한다.
    func markerScene(speedMetersPerSecond: Double?, showsVehicles: Bool) -> HwarangScene {
        guard isMoving else { return hwarangScene }
        if self == .running { return .runLoop }
        if showsVehicles, hwarangScene.isVehicleScene { return hwarangScene }
        return (speedMetersPerSecond ?? 0) >= Self.runningSpeedMetersPerSecond ? .runLoop : .walkLoop
    }

    var animatesPresentation: Bool {
        switch self {
        case .computer, .company, .school, .reading, .hobby, .sleeping, .deepSleep, .remSleep, .recovery, .medication, .restStarfish, .restCroissant, .restDonut, .restLoaf, .restBox, .eating,
             .activity, .exercise, .health, .unconfirmed, .shower, .housework,
             .nap, .cooking, .groceries, .laundry, .friends, .date, .family, .phoneCall,
             .meditation, .hospital, .salon, .bookReading, .game, .music, .video, .petCare, .mapReading, .walkInPlace, .workWalking, .meeting, .dishes, .coffee:
            true
        default:
            isMoving
        }
    }

    var title: String {
        func t(_ korean: UIPhrase, _ english: UIPhrase) -> String {
            AppLanguagePreference.text(korean: korean, english: english)
        }
        switch self {
        case .activity: return t("활동", "Activity")
        case .train: return t("기차", "Train")
        case .shower: return t("샤워", "Shower")
        case .housework: return t("집안일", "Housework")
        case .nap: return t("낮잠", "Nap")
        case .cooking: return t("요리", "Cooking")
        case .groceries: return t("장보기", "Groceries")
        case .laundry: return t("빨래", "Laundry")
        case .friends: return t("친구 만남", "Friends")
        case .date: return t("데이트", "Date")
        case .family: return t("가족", "Family")
        case .phoneCall: return t("통화", "Phone call")
        case .meditation: return t("명상", "Meditation")
        case .hospital: return t("병원", "Hospital")
        case .salon: return t("미용실", "Hair salon")
        case .bookReading: return t("독서", "Reading")
        case .game: return t("게임", "Games")
        case .music: return t("음악", "Music")
        case .video: return t("영상 보기", "Watching videos")
        case .petCare: return t("반려동물 돌보기", "Pet care")
        case .computer: return t("업무", "Work")
        case .company: return t("회사에서 업무", "Working at the office")
        case .school: return t("학교에서 학습", "Studying at school")
        case .reading: return t("수업", "Class")
        case .hobby: return t("취미", "Hobby")
        case .sleeping: return t("수면", "Sleep")
        case .deepSleep: return t("깊은 수면", "Deep sleep")
        case .recovery: return t("회복", "Recovery")
        case .medication: return t("투약", "Medication")
        case .restStarfish: return t("휴식", "Rest")
        case .restCroissant: return t("회사에서 휴식", "Break at the office")
        case .restDonut: return t("학교에서 휴식", "Break at school")
        case .restLoaf: return t("취미 휴식", "Hobby break")
        case .restBox: return t("집에서 휴식", "Rest at home")
        case .mapReading: return t("지도 보기", "Reading a map")
        case .meeting: return t("회의", "Meeting")
        case .dishes: return t("설거지", "Dishes")
        case .coffee: return t("커피·티타임", "Coffee & tea")
        case .walkInPlace: return t("제자리 걷기", "Walking in place")
        case .workWalking: return t("회사에서 걷기", "Walking at the office")
        case .remSleep: return t("REM 수면", "REM sleep")
        case .movement: return t("이동", "Movement")
        case .eating: return t("식사", "Meal")
        case .exercise: return t("운동", "Exercise")
        case .unconfirmed: return t("미확인", "Unconfirmed")
        case .walking: return t("걷기", "Walking")
        case .running: return t("달리기", "Running")
        case .car: return t("자동차", "Car")
        case .subway: return t("지하철 탑승", "Subway ride")
        case .privateVehicle: return t("자가용", "Private car")
        case .bus: return t("버스 탑승", "Bus ride")
        case .ship: return t("배", "Ship")
        case .airplane: return t("비행기", "Airplane")
        case .cycling: return t("자전거", "Cycling")
        case .health: return t("건강", "Health")
        }
    }
}
