import Foundation

/// AI 말풍선이 없을 때 화랑이가 하는 말(BUB1110A02, 3순위). 지금 동작의 대분류마다 몇 개를 두고
/// 30분마다 바꾼다. 같은 30분 안에서는 다시 그려도 같은 말이라 깜빡이지 않는다.
/// 대분류를 알 수 없는 동작(미확인 등)은 nil이라 예전처럼 동작 이름을 쓴다.
enum MapHomeDefaultBubblePool {
    enum Group: String, CaseIterable {
        case work, rest, movement, eating, activity, sleep
    }

    static let block: TimeInterval = 30 * 60

    static func group(for action: MapHomeStickmanAction) -> Group? {
        if action.isMoving { return .movement }
        switch action {
        case .computer, .company, .school, .reading, .meeting, .workWalking, .bookReading: return .work
        case .sleeping, .deepSleep, .remSleep, .nap: return .sleep
        case .eating, .coffee: return .eating
        case .restStarfish, .restCroissant, .restDonut, .restLoaf, .restBox, .recovery, .medication, .shower,
             .meditation, .music, .video, .game, .petCare, .phoneCall: return .rest
        case .activity, .exercise, .hobby, .housework, .dishes, .cooking, .groceries, .laundry, .friends, .date,
             .family, .hospital, .salon, .health, .mapReading, .walkInPlace: return .activity
        default: return nil
        }
    }

    static func phrases(_ group: Group, language: MapHomeLanguage) -> [String] {
        switch group {
        case .work: [
            language.text("열일 모드 가동 중 💻", "Deep work mode 💻"),
            language.text("차근차근 집중해 봐요!", "One step at a time!"),
            language.text("중간에 스트레칭도 잊지 마세요 ☕", "Don't forget to stretch ☕"),
            language.text("오늘 할 일 부수러 갑시다!", "Let's crush today's list!"),
        ]
        case .rest: [
            language.text("집이 제일 편해 🛋️", "Nothing beats home 🛋️"),
            language.text("포근하게 충전하는 시간 💤", "Cozy recharge time 💤"),
            language.text("푹 쉬는 것도 일이에요", "Resting is work too"),
            language.text("오늘 하루도 고생 많으셨어요", "You did great today"),
        ]
        case .movement: [
            language.text("어디로 향하는 길일까요? 🚗", "Where are we headed? 🚗"),
            language.text("조심히 이동하세요!", "Travel safe!"),
            language.text("가벼운 발걸음으로 👟", "Light steps 👟"),
            language.text("안전 운전 필수!", "Drive safe!"),
        ]
        case .eating: [
            language.text("맛있게 냠냠 🍽️", "Enjoy your meal 🍽️"),
            language.text("밥이 보약이에요!", "Good food, good mood!"),
            language.text("든든하게 챙겨드세요 🍱", "Eat well 🍱"),
            language.text("맛있는 식사 시간!", "Mealtime!"),
        ]
        case .activity: [
            language.text("활기차게 움직이는 중!", "On the move and lively!"),
            language.text("오늘도 부지런히 움직이시네요 🏃", "Busy as ever today 🏃"),
            language.text("기분 좋은 템포로!", "Nice and steady!"),
        ]
        case .sleep: [
            language.text("쿨쿨... 꿈나라 여행 중 🌙", "Zzz… off to dreamland 🌙"),
            language.text("좋은 꿈 꾸세요 💤", "Sweet dreams 💤"),
        ]
        }
    }

    /// 그 시각의 문구. 30분 칸과 대분류로 고르므로 기기·실행마다 같다(무작위 생성기를 쓰지 않는다).
    static func phrase(for action: MapHomeStickmanAction, at time: Date, language: MapHomeLanguage) -> String? {
        guard let group = group(for: action) else { return nil }
        let list = phrases(group, language: language)
        let slot = Int((time.timeIntervalSinceReferenceDate / block).rounded(.down))
        let salt = group.rawValue.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        let index = ((slot &+ salt) % list.count + list.count) % list.count
        return list[index]
    }
}
