import SwiftUI

/// 가계부 항목의 컬러 아이콘(대표 지시 2026-11-21). 고속도로 방패처럼 색이 든 표지로, 가맹점 이름·장소·메모에서 종류를 알아본다.
/// 병원과 약국, 버스와 지하철, 자동차·주유·주차장, 배, 비행기, 식사와 커피숍을 나눈다.
/// 나눌 수 없으면 그 통화의 기호(₩ 등)를 보이고, 그 가맹점 이름은 「가맹점 이름 보내기」를 켠 사용자에 한해 서버로 모인다(`LedgerMerchantCollector`).
enum LedgerMerchantKind: String, CaseIterable, Sendable {
    case hospital, pharmacy, bus, subway, car, fuel, parking, ship, airplane, meal, coffee, bank

    var symbol: String {
        switch self {
        case .hospital: "cross.fill"
        case .pharmacy: "pills.fill"
        case .bus: "bus.fill"
        case .subway: "tram.fill"
        case .car: "car.fill"
        case .fuel: "fuelpump.fill"
        case .parking: "parkingsign"
        case .ship: "ferry.fill"
        case .airplane: "airplane"
        case .meal: "fork.knife"
        case .coffee: "cup.and.saucer.fill"
        case .bank: "building.columns.fill"
        }
    }

    /// 종류마다 겹치지 않는 색(앱 분류 팔레트와 같은 결의 채도).
    var tintHex: String {
        switch self {
        case .hospital: "#DC2626"
        case .pharmacy: "#16A34A"
        case .bus: "#2F80ED"
        case .subway: "#7C5CE0"
        case .car: "#64748B"
        case .fuel: "#D97706"
        case .parking: "#4F46E5"
        case .ship: "#0E7490"
        case .airplane: "#38A9E8"
        case .meal: "#F76B15"
        case .coffee: "#8B5A2B"
        case .bank: "#475D8A"
        }
    }

    var tint: Color { Color(hex: tintHex) }

    // 키워드는 소문자·공백 없는 글에서 찾는다. 먼저 맞는 종류가 이긴다: 「카페리」가 커피숍이, 「현대오일뱅크」가 은행이 되지 않게 배·주유를 앞에 둔다.
    private static let fuelWords = ["주유", "오일뱅크", "에스오일", "s-oil", "soil", "gs칼텍스", "칼텍스", "sk에너지", "알뜰주유", "충전소", "gasstation", "fuel"]
    private static let parkingWords = ["주차", "파킹", "parking"]
    private static let airplaneWords = ["항공", "airlines", "airline", "에어부산", "에어서울", "에어프레미아", "진에어", "티웨이", "이스타", "플라이강원"]
    private static let shipWords = ["여객선", "카페리", "크루즈", "선박", "배편", "ferry"]
    private static let subwayWords = ["지하철", "도시철도", "서울교통공사", "전철", "subway"]
    private static let busWords = ["버스", "시내버스", "고속버스", "시외버스", "마을버스", "광역버스"]
    private static let carWords = ["택시", "카카오t", "쏘카", "그린카", "렌터카", "렌트카", "대리운전", "세차", "카센터", "정비", "자동차", "taxi"]
    private static let pharmacyWords = ["약국", "pharmacy"]
    private static let hospitalWords = ["병원", "의원", "클리닉", "치과", "한의원", "정형외과", "내과", "외과", "이비인후과", "피부과", "안과", "소아과", "산부인과", "비뇨기과", "의료원", "hospital", "clinic", "dental"]
    private static let coffeeWords = ["카페", "커피", "스타벅스", "이디야", "투썸", "빽다방", "메가mgc", "메가커피", "컴포즈", "할리스", "폴바셋", "블루보틀", "공차", "탐앤탐스", "엔제리너스", "cafe", "coffee", "starbucks"]
    private static let mealWords = ["식당", "음식", "한식", "중식", "일식", "양식", "분식", "치킨", "피자", "국밥", "삼겹", "고기", "갈비", "초밥", "스시", "돈까스", "돈가스", "맥도날드", "롯데리아", "버거킹", "맘스터치", "서브웨이",
                                   "김밥", "족발", "보쌈", "횟집", "순대", "설렁탕", "곱창", "라멘", "우동", "냉면", "칼국수", "짜장", "짬뽕", "만두", "샤브", "뷔페", "배달의민족", "요기요", "쿠팡이츠", "반점", "포차",
                                   "주점", "이자카야", "호프", "restaurant", "pizza", "burger", "sushi", "ramen"]
    private static let bankWords = ["은행", "뱅크", "bank"]

    /// 이름·장소·메모로 종류를 알아본다. 모르면 nil. 분류가 식사·카페로 정해져 있으면 그 분류를 따른다.
    static func classify(title: String, place: String? = nil, note: String? = nil, category: LedgerCategory = .other, isTransfer: Bool = false) -> LedgerMerchantKind? {
        let text = [title, place, note].compactMap { $0 }.joined(separator: " ").lowercased().replacingOccurrences(of: " ", with: "")
        func has(_ words: [String]) -> Bool { words.contains { text.contains($0) } }
        if !isTransfer, has(fuelWords) { return .fuel }
        if has(parkingWords) { return .parking }
        if has(airplaneWords) { return .airplane }
        if has(shipWords) { return .ship }
        if has(subwayWords) { return .subway }
        if has(busWords) { return .bus }
        if has(carWords) { return .car }
        if has(pharmacyWords) { return .pharmacy }
        if has(hospitalWords) { return .hospital }
        if has(coffeeWords) { return .coffee }
        if has(mealWords) { return .meal }
        if has(bankWords) { return .bank }
        switch category {
        case .cafe: return .coffee
        case .food: return .meal
        default: return nil
        }
    }

    static func classify(_ entry: LedgerEntry) -> LedgerMerchantKind? {
        classify(title: entry.title, place: entry.place, note: entry.note, category: entry.category, isTransfer: entry.transfer != nil)
    }
}

/// 통화 기호. 한국어·원화는 ₩.
enum LedgerCurrencySymbol {
    private static let symbols: [String: String] = [
        "KRW": "₩", "USD": "$", "JPY": "¥", "EUR": "€", "CNY": "¥", "TWD": "NT$", "HKD": "HK$", "THB": "฿", "VND": "₫",
        "SGD": "S$", "PHP": "₱", "IDR": "Rp", "GBP": "£", "AUD": "A$", "CAD": "C$",
    ]

    static func symbol(for currency: String) -> String { symbols[currency] ?? currency }
}

/// 색이 든 둥근 표지 안에 흰 그림.
struct LedgerMerchantBadge: View {
    let kind: LedgerMerchantKind
    var size: CGFloat = 28

    var body: some View {
        Circle().fill(kind.tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: kind.symbol)
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// 종류를 알 수 없을 때: 그 통화의 기호를 담은 표지.
struct LedgerCurrencyBadge: View {
    let currency: String
    var size: CGFloat = 28

    var body: some View {
        let symbol = LedgerCurrencySymbol.symbol(for: currency)
        Circle().fill(Color.tpSecondary.opacity(0.16))
            .frame(width: size, height: size)
            .overlay {
                Text(symbol)
                    .font(.system(size: size * (symbol.count > 2 ? 0.34 : 0.5), weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(Color.tpSecondary)
            }
            .accessibilityHidden(true)
    }
}
