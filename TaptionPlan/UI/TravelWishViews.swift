import SwiftUI
import TaptionPlanStore

/// 언젠가 갈 여행(버킷리스트) 카드(TVW1112A01): 날짜가 정해진 여행과 달리 종이 바탕에 점선 테두리, 별 표시.
struct TravelWishCard: View {
    let title: String
    let length: String
    let tag: String
    let color: Color
    let isChosen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(tag, systemImage: "star.fill").font(.caption.weight(.semibold)).foregroundStyle(color)
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(length).font(.caption).opacity(0.8)
        }
        .foregroundStyle(TravelInk.plan)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 220, alignment: .leading)
        .background(TravelInk.land, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(isChosen ? color : TravelInk.plan.opacity(0.55), style: StrokeStyle(lineWidth: isChosen ? 2.5 : 1.2, dash: [5, 4]))
        }
    }
}

/// 날짜 없는 여행의 아래 판: 날짜를 정하면 보통 여행이 되어 일정을 넣을 수 있다.
struct TravelWishFooter: View {
    @Bindable var model: AppModel
    let language: MapHomeLanguage
    let entry: TravelTripDirectory.Entry

    @State private var isPicking = false
    @State private var start = Date.now

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Label(language.text("언젠가 갈 여행", "A trip for someday"), systemImage: "star.fill").font(.subheadline.weight(.semibold))
                Text(language.text("날짜를 정하면 일정을 넣을 수 있습니다", "Set dates to start adding plans")).font(.caption).opacity(0.8)
            }
            Spacer(minLength: 0)
            Button(language.text("날짜 정하기", "Set dates")) { isPicking = true }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).frame(height: 44)
                .foregroundStyle(TravelInk.land)
                .background(TravelInk.plan, in: Capsule())
                .accessibilityIdentifier("travelWishSetDates")
        }
        .foregroundStyle(TravelInk.plan)
        .padding(12)
        .background(TravelInk.panel, in: RoundedRectangle(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).stroke(TravelInk.border, style: StrokeStyle(lineWidth: 1, dash: [5, 4])) }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .sheet(isPresented: $isPicking) {
            NavigationStack {
                DatePicker(language.text("첫날", "First day"), selection: $start, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .padding(.horizontal)
                    .navigationTitle(language.text("날짜 정하기", "Set dates"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button(language.text("취소", "Cancel")) { isPicking = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(language.text("정하기", "Set")) {
                                let trip = TravelTripDirectory.scheduled(entry.trip, startDay: TravelModeView.dayKey(start))
                                Task {
                                    if await model.saveTravelTrip(trip) { isPicking = false }
                                }
                            }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
            .preferredColorScheme(.light)
        }
    }
}

/// 고양이 동작 그림(TVW1112A01): 일정 종류와 이동 수단에 맞는 장면을 움직이는 그림으로 만들어 둔다.
@MainActor
final class TravelActorArt {
    private var cache: [String: UIImage] = [:]

    /// 동작마다 쓰는 장면. 관광 전용 장면은 아직 없어 둘러보며 걷는 장면(산책)을 쓴다.
    static func scene(_ pose: TravelPlayhead.Pose) -> HwarangScene {
        switch pose {
        case .walk: .walkLoop
        case .car: .carFront
        case .subway: .subway
        case .train: .train
        case .bus: .bus
        case .airplane: .airplane
        case .boat: .boat
        case .eat: .eat
        case .coffee: .coffee
        case .sleep: .sleep
        case .rest: .restLoaf
        case .shop: .groceries
        case .sight: .stroll
        case .activity: .stretch
        }
    }

    /// 장면 앞 3초를 10장으로 구워 되풀이한다. 한 번 만든 것은 다시 쓴다.
    func image(_ pose: TravelPlayhead.Pose, coat: String) -> UIImage {
        let key = coat + "|" + pose.rawValue
        if let known = cache[key] { return known }
        let scene = Self.scene(pose), length = min(3.0, Double(scene.totalDuration)), count = 10
        let frames = (0..<count).map { index in
            HwarangDiagnostics.frame(scene: scene, sec: length * Double(index) / Double(count), side: 104, small: true, coat: .named(coat))
        }
        let image = UIImage.animatedImage(with: frames, duration: length) ?? frames[0]
        cache[key] = image
        return image
    }
}
