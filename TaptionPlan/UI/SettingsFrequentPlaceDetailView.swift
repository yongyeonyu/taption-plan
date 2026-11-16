import MapKit
import SwiftUI

struct UserTransitLocationsSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    @State private var selectedLocation: UserTransitLocation?

    var body: some View {
        NavigationStack {
            List {
Group {

                if model.settings.userTransitLocations.isEmpty {
                    Text("등록된 역·정류장이 없습니다.")
                        .foregroundStyle(Color.tpSecondary)
                } else {
                    Section("등록된 위치") {
                        ForEach(model.settings.userTransitLocations) { location in
                            Button {
                                selectedLocation = location
                            } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(location.name)
                                            .foregroundStyle(Color.tpInk)
                                        Text(location.kind.title)
                                            .font(.taptionFixed(size: 12))
                                            .foregroundStyle(Color.tpSecondary)
                                    }
                                } icon: {
                                    Image(systemName: location.kind.systemImage)
                                        .foregroundStyle(Color.tpTransitDark)
                                }
                            }
                        }
                    }
                }
            
}
.listRowBackground(Color.tpSurface)
}
.tpListStyle()
            .navigationTitle("사용자 등록 위치")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
            }
        }
        .sheet(item: $selectedLocation) { location in
            UserTransitLocationNameEditor(model: model, location: location)
        }
    }
}

private struct UserTransitLocationNameEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let location: UserTransitLocation
    @State private var name: String

    init(model: AppModel, location: UserTransitLocation) {
        self.model = model
        self.location = location
        _name = State(initialValue: location.name)
    }

    var body: some View {
        NavigationStack {
            Form {
Group {

                Section {
                    Label(location.kind.title, systemImage: location.kind.systemImage)
                    TextField("이름", text: $name)
                } header: {
                    Text("등록된 위치 이름")
                }
            
}
.listRowBackground(Color.tpSurface)
}
.tpListStyle()
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("이름 편집")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        model.renameUserTransitLocation(location.id, name: name)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct FrequentPlaceDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let placeID: UUID

    @State private var name = ""
    @State private var radiusMeters = FrequentPlace.defaultRadiusMeters
    @State private var floorPrompt = FloorCalibrationPrompt()
    @State private var minimumDwellMinutes = 10
    @State private var isAutomaticRecordingEnabled = true
    @State private var showsDeleteConfirmation = false
    @State private var referenceDeletionFloor: Int?
    @State private var calibrationTask: Task<Void, Never>?
    @State private var showsMapPicker = false

    private var place: FrequentPlace? {
        model.settings.frequentPlaces.first { $0.id == placeID }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    if let place {
                        identitySection(place)
                        locationSection(place)
                        detectionSection
                        altitudeSection(place)
                        dangerSection(place)
                    } else {
                        ContentUnavailableView(
                            "장소를 찾을 수 없습니다",
                            systemImage: "mappin.slash"
                        )
                    }
                }
                .padding(16)
            }
            .background(Color.tpBackground.ignoresSafeArea())
            .navigationTitle("자주가는 곳 설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        model.updateFrequentPlaceDetails(
                            placeID,
                            name: name,
                            radiusMeters: radiusMeters,
                            minimumDwellMinutes: minimumDwellMinutes,
                            isAutomaticRecordingEnabled: isAutomaticRecordingEnabled
                        )
                        dismiss()
                    }
                    .fontWeight(.bold)
                    .disabled(place == nil)
                }
            }
            .onAppear(perform: loadPlace)
            // 화면을 떠나면 재던 표본은 버린다. 절반만 잰 값으로 기준을
            // 남기지 않는다.
            .onDisappear {
                calibrationTask?.cancel()
                calibrationTask = nil
            }
            .confirmationDialog(
                "이 기준점을 지울까요?",
                isPresented: Binding(
                    get: { referenceDeletionFloor != nil },
                    set: { if !$0 { referenceDeletionFloor = nil } }
                ),
                presenting: referenceDeletionFloor
            ) { floor in
                Button(
                    "\(FloorLabel.korean(floor)) 기준 삭제",
                    role: .destructive
                ) {
                    model.deleteFrequentPlaceFloorReference(
                        placeID,
                        floor: floor
                    )
                    referenceDeletionFloor = nil
                }
                Button("취소", role: .cancel) { referenceDeletionFloor = nil }
            } message: { floor in
                Text("\(FloorLabel.korean(floor)) 기준점을 지웁니다. 이 장소의 위치와 다른 층 기준은 그대로 남습니다.")
            }
            .alert(
                "자주가는 곳 삭제",
                isPresented: $showsDeleteConfirmation
            ) {
                Button("취소", role: .cancel) {}
                Button("삭제", role: .destructive) {
                    model.deleteFrequentPlace(placeID)
                    dismiss()
                }
            } message: {
                Text("이 장소의 자동 위치·층수 기록 기준을 삭제합니다.")
            }
            .sheet(isPresented: $showsMapPicker) {
                FrequentPlaceMapPicker(
                    initialPoint: place?.point
                ) { coordinate in
                    model.setFrequentPlaceLocation(
                        placeID,
                        latitude: coordinate.latitude,
                        longitude: coordinate.longitude
                    )
                }
            }
        }
    }

    private func loadPlace() {
        guard let place else { return }
        name = place.name
        radiusMeters = place.radiusMeters
        // 앱이 추정한 층은 미리 채우지 않는다. 고치려는 값이 기본값이 되면
        // 사용자는 틀린 층을 그대로 확인해 영구 기준으로 만든다.
        floorPrompt = FloorCalibrationPrompt(
            lastConfirmedFloor: model.lastManuallyConfirmedFloor(
                forPlaceID: placeID
            )
        )
        minimumDwellMinutes = place.kind == .restaurant
            ? max(15, place.minimumDwellMinutes)
            : place.minimumDwellMinutes
        isAutomaticRecordingEnabled = place.isAutomaticRecordingEnabled
    }

    private func identitySection(_ place: FrequentPlace) -> some View {
        VStack(alignment: .leading, spacing: TaptionMenuMetrics.sectionSpacing) {
            Label {
                Text("기본 정보")
                    .font(.taption(size: 12, weight: .bold))
            } icon: {
                Image(systemName: place.kind.systemImage)
                    .foregroundStyle(Color.tpPlaceDark)
            }

            TextField("장소 이름", text: $name)
                .font(.taption(size: 12, weight: .semibold))
                .textFieldStyle(.roundedBorder)

            Text("이름은 시간표의 위치 라벨과 위젯에 표시됩니다.")
                .font(.taption(size: 9))
                .foregroundStyle(Color.tpSecondary)
        }
        .detailCard()
    }

    private func locationSection(_ place: FrequentPlace) -> some View {
        VStack(alignment: .leading, spacing: TaptionMenuMetrics.sectionSpacing) {
            Label {
                Text("위치 기준")
                    .font(.taption(size: 12, weight: .bold))
            } icon: {
                Image(systemName: "mappin.and.ellipse")
                    .foregroundStyle(Color.tpPlaceDark)
            }

            if let point = place.point {
                Text(
                    "위도 \(point.latitude, specifier: "%.5f") · 경도 \(point.longitude, specifier: "%.5f")"
                )
                .font(.taption(size: 10, weight: .semibold))
                .foregroundStyle(Color.tpInk)
            } else {
                Text("아직 현재 위치가 지정되지 않았습니다.")
                    .font(.taption(size: 10))
                    .foregroundStyle(Color.tpSecondary)
            }

            Button {
                model.setFrequentPlaceToCurrentLocation(placeID)
            } label: {
                Label(
                    place.point == nil ? "현재 위치로 지정" : "현재 위치로 다시 지정",
                    systemImage: "location.fill"
                )
                .font(.taption(size: 10, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .foregroundStyle(.white)
                .background(Color.tpPlaceDark, in: RoundedRectangle(cornerRadius: TaptionRadius.control))
            }
            .buttonStyle(.plain)
            .frame(minHeight: TaptionMenuMetrics.minimumHitSize)
            .contentShape(Rectangle())

            Button {
                showsMapPicker = true
            } label: {
                Label("지도에서 지정", systemImage: "map.fill")
                    .font(.taption(size: 10, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .foregroundStyle(Color.tpPlaceDark)
                    .background(
                        Color.tpPlace,
                        in: RoundedRectangle(cornerRadius: TaptionRadius.control)
                    )
            }
            .buttonStyle(.plain)
            .frame(minHeight: TaptionMenuMetrics.minimumHitSize)
            .contentShape(Rectangle())

            Text("이 자리를 장소의 기준점으로 삼습니다. 층수는 아래 '현재 층수'에서 알려 주면 되고, 머무는 동안의 고도 변화는 자동으로 따라갑니다.")
                .font(.taption(size: 9))
                .foregroundStyle(Color.tpSecondary)

            if place.point != nil {
                Button(role: .destructive) {
                    model.clearFrequentPlaceLocation(placeID)
                } label: {
                    Label("위치 기준 삭제", systemImage: "trash")
                        .font(.taption(size: 9, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                }
            .buttonStyle(.plain)
            .frame(minHeight: TaptionMenuMetrics.minimumHitSize)
            .contentShape(Rectangle())
            }
        }
        .detailCard()
    }

    private var detectionSection: some View {
        VStack(alignment: .leading, spacing: TaptionMenuMetrics.sectionSpacing) {
            Label {
                Text("자동 감지 범위")
                    .font(.taption(size: 12, weight: .bold))
            } icon: {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(Color.tpPlaceDark)
            }
            Toggle("자동 위치 기록", isOn: $isAutomaticRecordingEnabled)
                .font(.taption(size: 10, weight: .semibold))
                .tint(Color.tpPlaceDark)
            Text("끄면 이 장소는 자동 분석에서 제외되고 수동 지정만 유지됩니다.")
                .font(.taption(size: 9))
                .foregroundStyle(Color.tpSecondary)

            Divider()

            HStack {
                Text("반경")
                Spacer()
                Text("\(Int(radiusMeters.rounded()))m")
                    .fontWeight(.bold)
                    .foregroundStyle(Color.tpPlaceDark)
            }
            .font(.taption(size: 10))
            // 지도 위에 범위 원을 그려 보여 준다. 슬라이더를 움직이면 원이 함께 커지고 작아진다.
            if let point = place?.point {
                MapHomePlaceRangeMap(
                    center: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
                    radiusMeters: radiusMeters,
                    tint: UIColor(Color.tpPlaceDark)
                )
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous))
            }
            Slider(value: $radiusMeters, in: 30...500, step: 10)
                .tint(Color.tpPlaceDark)
            HStack {
                Text("30m · 건물 내부")
                Spacer()
                Text("500m · 넓은 구역")
            }
            .font(.taption(size: 8))
            .foregroundStyle(Color.tpSecondary)
            Text("GPS 오차와 건물 규모에 맞춰 위치로 인식할 범위를 정합니다.")
                .font(.taption(size: 9))
                .foregroundStyle(Color.tpSecondary)

            HStack {
                Text("최소 체류")
                Spacer()
                Text("\(minimumDwellMinutes)분")
                    .fontWeight(.bold)
                    .foregroundStyle(Color.tpPlaceDark)
            }
            .font(.taption(size: 10))
            Slider(
                value: Binding(
                    get: { Double(minimumDwellMinutes) },
                    set: { minimumDwellMinutes = Int($0.rounded()) }
                ),
                in: (place?.kind == .restaurant ? 15 : 5)...120,
                step: 5
            )
            .tint(Color.tpPlaceDark)
            Text(
                place?.kind == .restaurant
                    ? "15분보다 짧은 방문은 식사로 기록하지 않습니다."
                    : "이 시간보다 짧은 방문은 일반 장소로 남깁니다."
            )
                .font(.taption(size: 9))
                .foregroundStyle(Color.tpSecondary)
        }
        .detailCard()
    }

    private var sampling: FloorCalibrationSampling? {
        guard let sampling = model.floorCalibrationSampling,
              sampling.placeID == placeID else {
            return nil
        }
        return sampling
    }

    private func altitudeSection(_ place: FrequentPlace) -> some View {
        VStack(alignment: .leading, spacing: TaptionMenuMetrics.sectionSpacing) {
            Label {
                Text("현재 층수")
                    .font(.taption(size: 12, weight: .bold))
            } icon: {
                Image(systemName: "building.2.crop.circle")
                    .foregroundStyle(Color.tpPlaceDark)
            }
            Stepper(
                value: Binding(
                    get: { floorPrompt.floor },
                    set: { floorPrompt.select($0) }
                ),
                in: FloorCalibrationPrompt.range
            ) {
                HStack {
                    Text("지금 있는 층")
                    Spacer()
                    Text(FloorLabel.korean(floorPrompt.floor))
                        .fontWeight(.bold)
                        .foregroundStyle(Color.tpPlaceDark)
                }
                .font(.taption(size: 10))
            }
            .tint(Color.tpPlaceDark)
            .disabled(sampling != nil)

            calibrateButton

            Text(calibrationGuidance)
                .font(.taption(size: 9))
                .foregroundStyle(Color.tpSecondary)

            Divider()

            if !place.floorReferencePoints.isEmpty {
                floorReferenceList(place)
            }
            if place.floorReferencePoints.count > 1 {
                Text(
                    "이 건물 층 높이 · \(place.floorHeightMeters, specifier: "%.1f")m · 기준 \(place.floorReferencePoints.count)개 층"
                )
            }
            if let reading = model.latestSensorReading,
               let relative = reading.relativeAltitudeMeters {
                Text("현재 센서 · 상대고도 \(relative, specifier: "%.1f")m")
            }
            if let estimate = model.latestAltitudeEstimate {
                Text(
                    "현재 추정 · \(estimate.floor)층 · 해발 "
                        + "\(Int(estimate.seaLevelAltitudeMeters.rounded()))m"
                )
                .fontWeight(.semibold)
                .foregroundStyle(Color.tpPlaceDark)
            } else if place.point == nil {
                Text("현재 위치를 지정하면 이 장소의 층 추정이 시작됩니다.")
            }
        }
        .font(.taption(size: 9))
        .foregroundStyle(Color.tpSecondary)
        .detailCard()
    }

    /// 한 번 눌러 값을 확인하고, 다시 눌러야 잰다. 미리 채워 둔 값을 한 번에
    /// 확정할 수 있으면 고치려던 층이 그대로 기준으로 굳는다.
    private var calibrateButton: some View {
        Button {
            if floorPrompt.canCommit {
                let floor = floorPrompt.floor
                floorPrompt.disarm()
                calibrationTask = Task {
                    await model.calibrateFrequentPlaceFloor(
                        placeID,
                        floor: floor
                    )
                }
            } else {
                floorPrompt.arm()
            }
        } label: {
            Group {
                if let sampling {
                    HStack(spacing: TaptionSpacing.snug) {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.white)
                        Text("재는 중 · \(sampling.collected)/\(sampling.target)")
                    }
                } else if floorPrompt.canCommit {
                    Label(
                        "\(FloorLabel.korean(floorPrompt.floor)) 맞습니다 · 다시 눌러 보정",
                        systemImage: "checkmark.circle.fill"
                    )
                } else {
                    Label("이 층으로 보정", systemImage: "building.2.fill")
                }
            }
            .font(.taption(size: 10, weight: .bold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundStyle(.white)
            .background(
                floorPrompt.canCommit ? Color.tpInk : Color.tpPlaceDark,
                in: RoundedRectangle(cornerRadius: TaptionRadius.control)
            )
        }
        .buttonStyle(.plain)
        .frame(minHeight: TaptionMenuMetrics.minimumHitSize)
        .contentShape(Rectangle())
        .disabled(sampling != nil)
    }

    private var calibrationGuidance: String {
        if sampling != nil {
            return "한자리에 선 채로 기다려 주세요. 다 재기 전에는 아무것도 기록되지 않습니다."
        }
        if floorPrompt.canCommit {
            return "다시 누르면 약 12초 동안 기압을 재서 이 층을 이 건물의 기준으로 남깁니다."
        }
        return "지금 있는 층을 맞춘 뒤 누르세요. 한 번 더 눌러 확인해야 기록합니다. 층 높이는 서로 다른 층에서 두 번 이상 알려 줄 때 그 차이로 앱이 스스로 맞춥니다."
    }

    private func floorReferenceList(_ place: FrequentPlace) -> some View {
        VStack(alignment: .leading, spacing: TaptionSpacing.tight) {
            Text("이 건물 층 기준")
                .font(.taption(size: 9, weight: .bold))
                .foregroundStyle(Color.tpSecondary)
            ForEach(place.floorReferencePoints, id: \.floor) { reference in
                HStack(spacing: TaptionSpacing.snug) {
                    Text(FloorLabel.korean(reference.floor))
                        .font(.taption(size: 9.5, weight: .bold))
                        .foregroundStyle(Color.tpInk)
                    Text(reference.isManual ? "직접 확인" : "자동")
                        .font(.taption(size: 8))
                    Spacer(minLength: 4)
                    Text(
                        reference.capturedAt,
                        format: .dateTime.month().day().hour().minute()
                    )
                    .font(.taption(size: 8))
                    Button {
                        referenceDeletionFloor = reference.floor
                    } label: {
                        Image(systemName: "trash")
                            .font(.taption(size: 9, weight: .semibold))
                            .foregroundStyle(Color(red: 0.78, green: 0.24, blue: 0.24))
                            .padding(.leading, 4)
                            .frame(
                                minWidth: TaptionMenuMetrics.minimumHitSize,
                                minHeight: TaptionMenuMetrics.minimumHitSize
                            )
                    }
                    .accessibilityLabel("층 기준 삭제")
                    .buttonStyle(.plain)
                }
            }
            Text("틀린 기준점은 지울 수 있습니다. 나머지 기준과 이 장소의 위치는 그대로 남습니다.")
                .font(.taption(size: 8.5))
        }
    }

    private func dangerSection(_ place: FrequentPlace) -> some View {
        Group {
            if place.kind == .custom || place.kind == .restaurant {
                Button(role: .destructive) {
                    showsDeleteConfirmation = true
                } label: {
                    Label(
                        place.kind == .restaurant ? "식당 삭제" : "자주가는 곳 삭제",
                        systemImage: "trash"
                    )
                        .font(.taption(size: 10, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                .frame(minHeight: TaptionMenuMetrics.minimumHitSize)
                .contentShape(Rectangle())
                .background(
                    Color(red: 1, green: 0.93, blue: 0.93),
                    in: RoundedRectangle(cornerRadius: TaptionRadius.field)
                )
            }
        }
    }

}

private struct FrequentPlaceMapPicker: View {
    @Environment(\.dismiss) private var dismiss
    let initialPoint: GeoPoint?
    let onSave: (CLLocationCoordinate2D) -> Void

    var body: some View {
        NavigationStack {
            MapHomePlacePinPicker(
                point: initialPoint,
                fallback: nil,
                tint: Color.tpPlaceDark,
                language: .current,
                height: nil
            ) { coordinate in
                onSave(coordinate)
                dismiss()
            }
            .padding(12)
            .navigationTitle("지도에서 지정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
            }
        }
    }
}

private extension View {
    func detailCard() -> some View {
        self
            .padding(TaptionMenuMetrics.contentInset)
            .background(Color.tpCard, in: RoundedRectangle(cornerRadius: TaptionRadius.card, style: .continuous))
    }
}
