import CoreMotion
import MapKit
import Photos
import SwiftUI
import UserNotifications

/// 등록지점 범위의 들어옴·나감 판정. 반경의 ±15%는 히스테리시스 구간으로, 이 안에서는 이전 상태를 그대로 둔다.
/// 그래서 경계에서 흔들리는 GPS 값이 "나감·들어옴"을 반복 만들지 않는다.
enum MapHomePlaceZone {
    static let band = 0.15

    enum State: Equatable {
        case inside
        case outside
    }

    /// 한 번의 거리 측정으로 다음 상태를 정한다.
    /// 안쪽 85%보다 가까우면 안, 바깥쪽 115%보다 멀면 밖, 그 사이는 이전 상태 유지.
    static func next(distance: Double, radius: Double, previous: State) -> State {
        guard radius > 0, distance.isFinite else { return previous }
        if distance <= radius * (1 - band) { return .inside }
        if distance >= radius * (1 + band) { return .outside }
        return previous
    }

    /// 장소 판정 샘플: 시각, 장소 중심까지 거리, 움직이는 중인지.
    struct Sample {
        let date: Date
        let distance: Double
        let isMoving: Bool
    }

    /// 도착·출발 확정 결과.
    enum Event: Equatable {
        /// 안으로 들어온 뒤 `dwell` 동안 계속 안에 머물렀다.
        case arrived(Date)
        /// 밖으로 나간 뒤 움직이며 멀어졌다(이동 확인).
        case departed(Date)
    }

    /// 들어옴 후 머무름, 나감 후 이동을 확인해 도착·출발을 확정한다.
    /// - 도착: 안쪽 전환 뒤 `dwell`(기본 5분) 동안 밖으로 나가지 않을 때만.
    /// - 출발: 바깥쪽 전환 뒤 `moveWindow`(기본 10분) 안에 움직이는 측정이 있을 때만.
    static func events(
        samples: [Sample],
        radius: Double,
        dwell: TimeInterval = 5 * 60,
        moveWindow: TimeInterval = 10 * 60
    ) -> [Event] {
        let ordered = samples.sorted { $0.date < $1.date }
        let changes = transitions(
            samples: ordered.map { (date: $0.date, distance: $0.distance) },
            radius: radius
        )
        var events: [Event] = []
        for change in changes {
            let after = ordered.filter { $0.date >= change.date }
            switch change.state {
            case .inside:
                // 다음 바깥쪽 전환 전에 dwell만큼 흘렀는지 본다(샘플이 dwell 이후까지 있어야 한다).
                let nextOut = changes.first { $0.date > change.date && $0.state == .outside }?.date
                let deadline = change.date.addingTimeInterval(dwell)
                let stayed = (nextOut ?? .distantFuture) >= deadline
                    && (after.last?.date ?? change.date) >= deadline
                if stayed { events.append(.arrived(change.date)) }
            case .outside:
                let window = after.filter { $0.date <= change.date.addingTimeInterval(moveWindow) }
                // 멀어졌다는 것만으로는 부족하다. 실제로 움직인 측정이 있어야 출발로 본다.
                let moved = window.contains { $0.isMoving }
                if moved { events.append(.departed(change.date)) }
            }
        }
        return events
    }

    /// 시간 순 측정열에서 상태가 바뀐 시각만 골라 돌려준다. 처음 상태는 밖으로 본다.
    static func transitions(
        samples: [(date: Date, distance: Double)],
        radius: Double
    ) -> [(date: Date, state: State)] {
        var current = State.outside
        var result: [(date: Date, state: State)] = []
        for sample in samples.sorted(by: { $0.date < $1.date }) {
            let updated = next(distance: sample.distance, radius: radius, previous: current)
            if updated != current {
                result.append((sample.date, updated))
                current = updated
            }
        }
        return result
    }
}

/// 걸음 수를 거리로 바꾸는 보폭(m). 기본값은 대표가 알려주는 값으로 바꾼다.
enum MapHomeStride {
    static let storageKey = "mapHomeStrideMeters"
    static let defaultMeters = 20.0 / 26.5
    static let allowedRange = 0.3...1.5

    static var current: Double {
        let stored = UserDefaults.standard.double(forKey: storageKey)
        return allowedRange.contains(stored) ? stored : defaultMeters
    }

    /// 걸어간 거리(m)와 그때의 걸음 수로 보폭을 구한다. 값이 비정상이면 nil.
    static func calibrated(distanceMeters: Double, steps: Int) -> Double? {
        guard steps >= 5, distanceMeters > 0 else { return nil }
        let stride = distanceMeters / Double(steps)
        return allowedRange.contains(stride) ? stride : nil
    }
}

/// 보폭 보정: 시작 → 정해진 거리를 걷기 → 종료 → 거리 입력으로 보폭을 저장한다. 직접 입력도 된다.
struct MapHomeStrideCalibrationSheet: View {
    let language: MapHomeLanguage
    @AppStorage(MapHomeStride.storageKey) private var strideMeters = MapHomeStride.defaultMeters
    @State private var pedometer = CMPedometer()
    @State private var isMeasuring = false
    @State private var steps = 0
    @State private var distanceText = "10"
    @State private var manualCentimeters = ""
    @State private var message: String?

    private var currentStride: Double {
        MapHomeStride.allowedRange.contains(strideMeters) ? strideMeters : MapHomeStride.defaultMeters
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(language.text("보폭 보정", "Stride calibration"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(22)), weight: .bold))
                Text(language.text(
                    "현재 보폭 \(String(format: "%.0f", currentStride * 100))cm · 걸음 수 × 보폭으로 걸음 환산 거리를 계산합니다.",
                    "Stride \(String(format: "%.0f", currentStride * 100)) cm · used for step-based distance."
                ))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .medium))
                .foregroundStyle(Color.tpSecondary)

                VStack(alignment: .leading, spacing: 10) {
                    Text(language.text("1. 시작을 누르고 정한 거리를 걸은 뒤 종료를 누르세요.", "1. Tap Start, walk a known distance, then tap Stop."))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                    Text(language.text("\(steps)걸음", "\(steps) steps"))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(34)), weight: .bold))
                        .monospacedDigit()
                    Button(isMeasuring ? language.text("종료", "Stop") : language.text("시작", "Start")) {
                        isMeasuring ? stop() : start()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isMeasuring ? Color.tpHoliday : Color.tpAccent)
                    HStack {
                        Text(language.text("2. 걸은 거리", "2. Distance walked"))
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                        TextField("10", text: $distanceText)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        Text("m")
                        Spacer()
                        Button(language.text("보폭 저장", "Save")) { saveMeasured() }
                            .buttonStyle(.bordered)
                            .disabled(isMeasuring || steps < 5)
                    }
                }
                .padding(14)
                .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                HStack {
                    Text(language.text("직접 입력", "Manual"))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                    TextField("75", text: $manualCentimeters)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text("cm")
                    Spacer()
                    Button(language.text("저장", "Save")) { saveManual() }.buttonStyle(.bordered)
                }
                if let message {
                    Text(message).font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .medium)).foregroundStyle(Color.tpAccent)
                }
            }
            .padding(22)
        }
        .background(Color.tpBackground)
        .onDisappear { pedometer.stopUpdates() }
    }

    private func start() {
        guard CMPedometer.isStepCountingAvailable() else {
            message = language.text("이 기기에서는 걸음 수를 쓸 수 없습니다.", "Step counting is unavailable on this device.")
            return
        }
        steps = 0
        message = nil
        isMeasuring = true
        pedometer.startUpdates(from: Date()) { data, error in
            Task { @MainActor in
                if let data {
                    steps = data.numberOfSteps.intValue
                } else if error != nil {
                    // 동작·피트니스 권한이 없거나 측정이 막혔을 때 멈추고 이유를 보여 준다.
                    pedometer.stopUpdates()
                    isMeasuring = false
                    message = language.text(
                        "걸음 측정을 할 수 없어요. 설정에서 동작 및 피트니스 권한을 허용해 주세요.",
                        "Steps unavailable. Allow Motion & Fitness in Settings."
                    )
                }
            }
        }
    }

    private func stop() {
        pedometer.stopUpdates()
        isMeasuring = false
    }

    private func number(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
    }

    private func saveMeasured() {
        guard let distance = number(distanceText),
              let stride = MapHomeStride.calibrated(distanceMeters: distance, steps: steps) else {
            message = language.text("거리나 걸음 수가 맞지 않습니다(보폭 30~150cm).", "Distance or steps look wrong (stride 30–150 cm).")
            return
        }
        strideMeters = stride
        message = language.text("보폭 \(String(format: "%.0f", stride * 100))cm로 저장했습니다.", "Saved \(String(format: "%.0f", stride * 100)) cm.")
    }

    private func saveManual() {
        guard let centimeters = number(manualCentimeters), MapHomeStride.allowedRange.contains(centimeters / 100) else {
            message = language.text("30~150cm 사이로 입력해 주세요.", "Enter 30–150 cm.")
            return
        }
        strideMeters = centimeters / 100
        message = language.text("보폭 \(String(format: "%.0f", centimeters))cm로 저장했습니다.", "Saved \(String(format: "%.0f", centimeters)) cm.")
    }
}

/// 땅 타일(집 주변 땅 따먹기). 화면이 지저분해 보여 대표 결정으로 숨긴다. 보상 데이터는 그대로 둔다.
enum MapHomeLandFeature {
    static let isVisible = false
}
