import Foundation
import TaptionPlanCore

extension AppModel {
    func confirmPlace(_ placeID: UUID, name: String, floor: Int?) {
        guard let index = snapshot.places.firstIndex(where: {
            $0.id == placeID
        }) else {
            return
        }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanName.isEmpty {
            snapshot.places[index].displayName = cleanName
        }
        snapshot.places[index].floor = floor
        snapshot.places[index].confidence = .high
        snapshot.places[index].isConfirmed = true
        Task { await persist() }
    }

    /// 층수를 전달하지 않은 기존 호출은 기존 기준을 유지하고, 지도 저장 UI는
    /// 사용자가 고른 층수를 기준점으로 남긴다.
    func setFrequentPlaceToCurrentLocation(_ placeID: UUID, floor: Int? = nil) {
        guard let index = snapshot.settings.frequentPlaces.firstIndex(where: {
            $0.id == placeID
        }) else {
            return
        }
        guard let reading = latestSensorReading,
              reading.point != nil else {
            userFacingError = AppLanguagePreference.text(
                korean: "현재 위치를 아직 읽지 못했습니다. 위치 권한을 켠 뒤 잠시 후 다시 시도해 주세요.",
                english: "Current location is not available yet. Turn on location access and try again shortly."
            )
            return
        }
        // 층수는 앱의 추정에서 가져오지 않는다. 추정이 틀린 상태에서 자리를
        // 다시 잡으면 그 틀린 층이 곧 이 건물의 기준으로 굳는다. 층은 아래
        // "이 층으로 보정"에서 사용자가 직접 확인한 값만 받는다.
        let resolvedFloor = floor
            ?? snapshot.settings.frequentPlaces[index].floor
            ?? lastManuallyConfirmedFloor(forPlaceID: placeID)
            ?? 1
        guard FloorCalibrationPrompt.range.contains(resolvedFloor) else {
            userFacingError = AppModelMessage.floorOutOfRange(
                lower: FloorCalibrationPrompt.range.lowerBound,
                upper: FloorCalibrationPrompt.range.upperBound
            ).text()
            return
        }
        snapshot.settings.frequentPlaces[index].setLocation(
            from: reading,
            floor: resolvedFloor
        )
        lastAutoFloorCalibrationKey = nil
        snapshot.settings.floorCalibration = nil
        snapshot.settings.frequentPlaces =
            AppFeatureSettings.mergedFrequentPlaces(
                snapshot.settings.frequentPlaces
            )
        snapshot.places = FrequentPlaceResolutionEngine().applying(
            snapshot.settings.frequentPlaces,
            to: snapshot.places,
            readings: [reading]
        )
        updateFloorEstimate(with: reading)
        scheduleFrequentPlaceDerivedRefresh()
    }

    /// 위치는 그대로 두고 층수만 바꾼다.
    func setFrequentPlaceFloor(_ placeID: UUID, floor: Int) {
        guard FloorCalibrationPrompt.range.contains(floor),
              let index = snapshot.settings.frequentPlaces.firstIndex(where: { $0.id == placeID }),
              snapshot.settings.frequentPlaces[index].floor != floor else { return }
        snapshot.settings.frequentPlaces[index].floor = floor
        scheduleFrequentPlaceDerivedRefresh()
    }

    func setFrequentPlaceLocation(
        _ placeID: UUID,
        latitude: Double,
        longitude: Double,
        floor: Int? = nil
    ) {
        guard let index = snapshot.settings.frequentPlaces.firstIndex(where: {
            $0.id == placeID
        }) else {
            return
        }
        guard floor.map(FloorCalibrationPrompt.range.contains) ?? true else {
            userFacingError = AppModelMessage.floorOutOfRange(
                lower: FloorCalibrationPrompt.range.lowerBound,
                upper: FloorCalibrationPrompt.range.upperBound
            ).text()
            return
        }
        snapshot.settings.frequentPlaces[index].setMapLocation(
            GeoPoint(
                latitude: latitude,
                longitude: longitude,
                altitude: 0,
                horizontalAccuracy: 25,
                verticalAccuracy: -1
            )
        )
        if let floor {
            snapshot.settings.frequentPlaces[index].floor = floor
            snapshot.settings.frequentPlaces[index].floorCapturedAt = nil
        }
        lastAutoFloorCalibrationKey = nil
        snapshot.settings.floorCalibration = nil
        snapshot.settings.frequentPlaces =
            AppFeatureSettings.mergedFrequentPlaces(
                snapshot.settings.frequentPlaces
            )
        scheduleFrequentPlaceDerivedRefresh()
    }

    func clearFrequentPlaceLocation(_ placeID: UUID) {
        guard let index = snapshot.settings.frequentPlaces.firstIndex(where: {
            $0.id == placeID
        }) else {
            return
        }
        if let point = snapshot.settings.frequentPlaces[index].point {
            rememberDismissedPlaceSuggestion(at: point)
        }
        snapshot.settings.frequentPlaces[index].clearLocation()
        lastAutoFloorCalibrationKey = nil
        if let latestSensorReading {
            updateFloorEstimate(with: latestSensorReading)
        } else {
            latestAltitudeEstimate = nil
        }
        scheduleFrequentPlaceDerivedRefresh()
    }

    /// 장소 기준점이 바뀌면 기존 파생 기록을 같은 원본 센서 구간으로
    /// 다시 판정하고, 계산 결과까지 저장해 다음 화면·기기에서도 즉시 쓴다.
    private func scheduleFrequentPlaceDerivedRefresh() {
        let affectedDate = selectedDate
        unlockDerivedClassifications(for: affectedDate)
        liveMergeCacheKey = nil
        liveMergeCacheValue.removeAll(keepingCapacity: true)
        sensorRefreshFingerprints.removeAll()
        Task {
            await refreshSensorTimeline(containing: affectedDate)
            await persist()
        }
    }

    private func unlockDerivedClassifications(for date: Date) {
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(24 * 60 * 60)
        let daySpan = TimeSpan(start: dayStart, end: dayEnd)
        let sleepSpan = SleepAnalysisEngine.overnightSpan(
            containing: date,
            calendar: calendar
        )
        let affects: (TimeSpan) -> Bool = { candidate in
            candidate.intersection(with: daySpan) != nil
                || candidate.intersection(with: sleepSpan) != nil
        }
        snapshot.actuals = snapshot.actuals.map { actual in
            guard actual.source.usesAutomaticClassification,
                  !actual.manuallyCorrected,
                  affects(actual.span(asOf: max(dayEnd, sleepSpan.end))) else {
                return actual
            }
            var value = actual
            value.isClassificationLocked = false
            return value
        }
        snapshot.travel = snapshot.travel.map { segment in
            guard !segment.isConfirmed,
                  affects(segment.span) else {
                return segment
            }
            var value = segment
            value.isClassificationLocked = false
            return value
        }
    }

    /// 스테퍼가 미리 채울 값. 앱이 추정한 층은 절대 쓰지 않는다. 고치려는
    /// 값이 곧 기본값이 되면 사용자는 틀린 층을 그대로 확인하게 된다.
    /// 사용자가 직접 확인한 기준점이 없으면 미리 채울 값도 없다. 이력에 남은
    /// 옛 "수동" 기록은 이 화면이 추정값을 미리 채워 주던 시절의 것이라
    /// 사용자가 골랐다고 믿을 수 없다.
    func lastManuallyConfirmedFloor(forPlaceID placeID: UUID) -> Int? {
        settings.frequentPlaces
            .first { $0.id == placeID }?
            .floorReferencePoints
            .last(where: \.isManual)?
            .floor
    }

    /// 사용자가 "지금 이 층"이라고 알려 주면 그 자리의 기압을 이 장소의
    /// 기준으로 삼는다. 층 높이는 묻지 않는다. 서로 다른 층 기준이 둘 이상
    /// 모이면 `FrequentPlace.calibrateCurrentFloor` 가 그 차이로 구한다.
    ///
    /// 기압계 한 표본은 흔들린다. 그 한 번으로 영구 기준을 박으면 흔들림이
    /// 이 건물의 모든 층 추정에 남으므로, 짧은 묶음을 모아 중앙값으로 줄인
    /// 뒤에만 기록한다. 묶음이 모자라거나 흔들리면 아무것도 남기지 않는다.
    func calibrateFrequentPlaceFloor(_ placeID: UUID, floor: Int) async {
        guard snapshot.settings.frequentPlaces.contains(where: {
            $0.id == placeID
        }) else {
            return
        }
        guard latestSensorReading?.point != nil else {
            userFacingError = AppLanguagePreference.text(
                korean: "현재 위치를 아직 읽지 못했습니다. 위치 권한을 켠 뒤 잠시 후 다시 시도해 주세요.",
                english: "Current location is not available yet. Turn on location access and try again shortly."
            )
            return
        }
        guard let sensorService else { return }
        guard floorCalibrationSampling == nil else { return }
        floorCalibrationSampling = FloorCalibrationSampling(
            placeID: placeID,
            floor: floor,
            collected: 0,
            target: AltitudeBurstReducer.requestedSampleCount
        )
        let samples = await sensorService.captureAltitudeBurst { collected in
            self.floorCalibrationSampling?.collected = collected
        }
        floorCalibrationSampling = nil
        // 사용자가 화면을 떠났으면 조용히 접는다. 절반만 잰 값으로 기준을
        // 남기지도, 뒤늦게 오류를 띄우지도 않는다.
        guard !Task.isCancelled else { return }
        guard let anchor = latestSensorReading, anchor.point != nil else {
            userFacingError = AppLanguagePreference.text(
                korean: "현재 위치를 아직 읽지 못했습니다. 위치 권한을 켠 뒤 잠시 후 다시 시도해 주세요.",
                english: "Current location is not available yet. Turn on location access and try again shortly."
            )
            return
        }
        switch AltitudeBurstReducer.reduce(samples) {
        case let .tooFewSamples(collected):
            userFacingError = AppLanguagePreference.text(
                korean: collected == 0
                    ? "기압 센서를 읽지 못해 보정을 취소했습니다. 위치 기록을 켠 뒤 다시 시도해 주세요."
                    : "표본이 \(collected)개뿐이라 보정을 취소했습니다. 잠시 후 다시 시도해 주세요.",
                english: collected == 0
                    ? "Calibration was cancelled because the barometer could not be read. Turn on location recording and try again."
                    : "Calibration was cancelled because only \(collected) samples were collected. Try again shortly."
            )
        case let .tooNoisy(spread):
            userFacingError = String(
                format: AppLanguagePreference.text(
                    korean: "고도가 %.1fm나 흔들려 보정을 취소했습니다. 한자리에 선 채로 다시 시도해 주세요.",
                    english: "Altitude fluctuated by %.1f m, so calibration was cancelled. Stay in one place and try again."
                ),
                spread
            )
        case let .reduced(sample, _):
            commitFloorCalibration(
                placeID,
                floor: floor,
                reading: anchor.replacingAltitude(with: sample)
            )
        }
    }

    private func commitFloorCalibration(
        _ placeID: UUID,
        floor: Int,
        reading: SensorReading
    ) {
        guard let index = snapshot.settings.frequentPlaces.firstIndex(where: {
            $0.id == placeID
        }) else {
            return
        }
        snapshot.settings.frequentPlaces[index].calibrateCurrentFloor(
            to: floor,
            from: reading
        )
        appendFloorCalibrationEvent(
            FloorCalibrationEvent(
                placeID: placeID,
                placeName: snapshot.settings.frequentPlaces[index].name,
                floor: floor,
                seaLevelAltitudeMeters: reading.point?.altitude,
                isAutomatic: false,
                capturedAt: reading.timestamp
            )
        )
        lastAutoFloorCalibrationKey = nil
        snapshot.settings.floorCalibration = nil
        snapshot.settings.frequentPlaces =
            AppFeatureSettings.mergedFrequentPlaces(
                snapshot.settings.frequentPlaces
            )
        // 기준이 바뀌면 직전 고도와의 연속성 판정은 무효다. 새 기준의 첫
        // 추정이 스파이크로 걸리면 화면이 옛 층에 그대로 머문다.
        altitudeGatePlaceID = nil
        updateFloorEstimate(with: reading)
        Task {
            await persist()
            await reapplyStoredFloors(forPlaceID: placeID)
            await refreshSensorTimeline(containing: selectedDate)
        }
    }

    /// 잘못 들어간 기준점 하나를 지운다. 이 장소의 위치와 나머지 기준은
    /// 그대로 둔다.
    func deleteFrequentPlaceFloorReference(_ placeID: UUID, floor: Int) {
        guard let index = snapshot.settings.frequentPlaces.firstIndex(where: {
            $0.id == placeID
        }), snapshot.settings.frequentPlaces[index].removeFloorReference(
            floor: floor
        ) else {
            return
        }
        lastAutoFloorCalibrationKey = nil
        snapshot.settings.floorCalibration = nil
        altitudeGatePlaceID = nil
        if let latestSensorReading {
            updateFloorEstimate(with: latestSensorReading)
        } else {
            latestAltitudeEstimate = nil
        }
        Task {
            await persist()
            await reapplyStoredFloors(forPlaceID: placeID)
            await refreshSensorTimeline(containing: selectedDate)
        }
    }

    /// 기준점을 고치면 그 기준으로 매긴 지난 기록도 다시 매겨야 한다. 원본
    /// 표본은 그대로 두고 파생된 층수만 다시 구한다. 기록이 스스로 근거를
    /// 지녔으면 보관 기간과 무관하게 다시 매기고, 옛 기록은 7일 보관분과
    /// 기록에 남은 대표 GPS 고도 순으로 보완한다.
    func reapplyStoredFloors(forPlaceID placeID: UUID) async {
        guard let place = settings.frequentPlaces.first(where: {
            $0.id == placeID
        }) else {
            return
        }
        let legacy = snapshot.places.filter {
            $0.placeKey == place.stablePlaceKey && $0.floorEvidence == nil
        }
        var readings: [SensorReading] = []
        if let sensorService,
           let start = legacy.map(\.span.start).min(),
           let end = legacy.map(\.span.end).max() {
            readings = (try? await sensorService.archivedReadings(
                in: TimeSpan(start: start, end: end)
            )) ?? []
        }
        let engine = FrequentPlaceResolutionEngine()
        let recomputedPlaces = engine.reapplyingFloors(
            of: place,
            to: snapshot.places,
            readings: readings
        )
        let recomputedTransitions = engine.reapplyingFloors(
            of: place,
            to: snapshot.floorTransitions
        )
        var changed = false
        if recomputedPlaces != snapshot.places {
            snapshot.places = recomputedPlaces
            changed = true
        }
        if recomputedTransitions != snapshot.floorTransitions {
            snapshot.floorTransitions = recomputedTransitions
            changed = true
        }
        guard changed else { return }
        await persist()
    }

    private func appendFloorCalibrationEvent(_ event: FloorCalibrationEvent) {
        snapshot.settings.floorCalibrationHistory.append(event)
        let overflow = snapshot.settings.floorCalibrationHistory.count - 100
        if overflow > 0 {
            snapshot.settings.floorCalibrationHistory.removeFirst(overflow)
        }
    }

    /// 자동 층 보정은 사용자 조작 없이 이 경로로만 쌓인다.
    @discardableResult
    func recordFloorCalibration(
        placeID: UUID,
        floor: Int,
        reading: SensorReading,
        seaLevelAltitudeMeters: Double?
    ) -> Bool {
        guard reading.point != nil,
              let index = snapshot.settings.frequentPlaces.firstIndex(where: {
                  $0.id == placeID
              }) else {
            return false
        }
        // 사용자가 확인한 기준과 같은 높이를 다른 층이라고 주장하는 자동
        // 보정은 거절된다. 그때는 이력도 알림도 남기지 않는다.
        guard snapshot.settings.frequentPlaces[index].addFloorCalibration(
            from: reading,
            floor: floor
        ) else {
            return false
        }
        appendFloorCalibrationEvent(
            FloorCalibrationEvent(
                placeID: placeID,
                placeName: snapshot.settings.frequentPlaces[index].name,
                floor: floor,
                seaLevelAltitudeMeters: seaLevelAltitudeMeters,
                isAutomatic: true,
                capturedAt: reading.timestamp
            )
        )
        snapshot.settings.frequentPlaces =
            AppFeatureSettings.mergedFrequentPlaces(
                snapshot.settings.frequentPlaces
            )
        Task {
            await persist()
            await refreshSensorTimeline(containing: selectedDate)
        }
        return true
    }

    func showFloorCalibrationNotice(_ text: String) {
        calibrationNoticeTask?.cancel()
        floorCalibrationNotice = text
        calibrationNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.floorCalibrationNotice = nil
        }
    }

    /// 자주가는 곳의 이름과 감지 범위를 저장합니다. 건물의 층 높이는 여기서
    /// 받지 않습니다. 사용자가 알려 준 현재 층수에서 앱이 직접 구합니다.
    func updateFrequentPlaceDetails(
        _ placeID: UUID,
        name: String,
        radiusMeters: Double,
        minimumDwellMinutes: Int,
        isAutomaticRecordingEnabled: Bool
    ) {
        guard let index = snapshot.settings.frequentPlaces.firstIndex(where: {
            $0.id == placeID
        }) else {
            return
        }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanName.isEmpty {
            snapshot.settings.frequentPlaces[index].name = cleanName
        }
        snapshot.settings.frequentPlaces[index].radiusMeters = min(
            max(radiusMeters, 30),
            500
        )
        let minimumDwell = snapshot.settings.frequentPlaces[index].kind == .restaurant
            ? 15
            : minimumDwellMinutes
        snapshot.settings.frequentPlaces[index].minimumDwellMinutes = min(
            max(minimumDwell, 1),
            240
        )
        snapshot.settings.frequentPlaces[index]
            .isAutomaticRecordingEnabled = isAutomaticRecordingEnabled
        snapshot.settings.frequentPlaces[index].updatedAt = .now
        snapshot.settings.frequentPlaces =
            AppFeatureSettings.mergedFrequentPlaces(
                snapshot.settings.frequentPlaces
            )
        if let latestSensorReading {
            updateFloorEstimate(with: latestSensorReading)
        }
        Task {
            await persist()
            await refreshSensorTimeline(containing: selectedDate)
        }
    }

    func addCustomFrequentPlace(name: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            userFacingError = AppLanguagePreference.text(
                korean: "장소 이름을 입력해 주세요.",
                english: "Enter a place name."
            )
            return
        }
        guard !snapshot.settings.frequentPlaces.contains(where: {
            $0.name.localizedCaseInsensitiveCompare(cleanName) == .orderedSame
        }) else {
            userFacingError = AppLanguagePreference.text(
                korean: "같은 이름의 자주가는 곳이 이미 있습니다.",
                english: "A frequent place with the same name already exists."
            )
            return
        }
        snapshot.settings.frequentPlaces.append(
            FrequentPlace(kind: .custom, name: cleanName)
        )
        Task { await persist() }
    }

    /// 식당은 이름·좌표·반경을 독립적으로 여러 곳 저장할 수 있는 자주가는
    /// 곳 유형입니다. 체류를 식사로 바꾸는 기준은 위치 분석의 15분 이상
    /// 체류로 고정하고, 이 목록은 기존 장소 영속화 경로를 함께 사용합니다.
    func addRestaurant(name: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            userFacingError = AppLanguagePreference.text(
                korean: "식당 이름을 입력해 주세요.",
                english: "Enter a restaurant name."
            )
            return
        }
        guard !snapshot.settings.frequentPlaces.contains(where: {
            $0.name.localizedCaseInsensitiveCompare(cleanName) == .orderedSame
        }) else {
            userFacingError = AppLanguagePreference.text(
                korean: "같은 이름의 자주가는 곳이 이미 있습니다.",
                english: "A frequent place with the same name already exists."
            )
            return
        }
        snapshot.settings.frequentPlaces.append(
            FrequentPlace(
                kind: .restaurant,
                name: cleanName,
                minimumDwellMinutes: 15
            )
        )
        Task { await persist() }
    }

    @discardableResult
    func addUserTransitLocation(
        name: String,
        kind: UserTransitLocationKind,
        latitude: Double,
        longitude: Double,
        floor: Int? = nil
    ) -> UUID? {
        guard acceptsDataMutation() else { return nil }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            userFacingError = AppLanguagePreference.text(
                korean: "위치 이름을 입력해 주세요.",
                english: "Enter a location name."
            )
            return nil
        }
        guard abs(latitude) <= 90, abs(longitude) <= 180 else {
            userFacingError = AppLanguagePreference.text(
                korean: "위치 좌표를 확인해 주세요.",
                english: "Check the location coordinates."
            )
            return nil
        }
        guard floor.map(FloorCalibrationPrompt.range.contains) ?? true else {
            userFacingError = AppModelMessage.floorOutOfRange(
                lower: FloorCalibrationPrompt.range.lowerBound,
                upper: FloorCalibrationPrompt.range.upperBound
            ).text()
            return nil
        }
        let location = UserTransitLocation(
            name: cleanName,
            kind: kind,
            point: GeoPoint(
                latitude: latitude,
                longitude: longitude,
                altitude: 0,
                horizontalAccuracy: 25,
                verticalAccuracy: -1
            ),
            floor: floor
        )
        snapshot.settings.userTransitLocations.append(location)
        Task { await persist() }
        return location.id
    }

    func deleteUserTransitLocation(_ id: UUID) {
        snapshot.settings.userTransitLocations.removeAll { $0.id == id }
        Task { await persist() }
    }

    func renameUserTransitLocation(_ locationID: UUID, name: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty,
              let index = snapshot.settings.userTransitLocations.firstIndex(
                  where: { $0.id == locationID }
              ) else {
            return
        }
        snapshot.settings.userTransitLocations[index].name = cleanName
        Task { await persist() }
    }

    func setUserTransitLocationFloor(_ locationID: UUID, floor: Int?) {
        guard floor.map(FloorCalibrationPrompt.range.contains) ?? true,
              let index = snapshot.settings.userTransitLocations.firstIndex(
                  where: { $0.id == locationID }
              ) else {
            return
        }
        guard snapshot.settings.userTransitLocations[index].floor != floor else {
            return
        }
        snapshot.settings.userTransitLocations[index].floor = floor
        Task { await persist() }
    }

    func renameFrequentPlace(_ placeID: UUID, name: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        guard let index = snapshot.settings.frequentPlaces.firstIndex(where: {
            $0.id == placeID
        }) else {
            return
        }
        snapshot.settings.frequentPlaces[index].name = cleanName
        snapshot.settings.frequentPlaces[index].updatedAt = .now
        Task {
            await persist()
            await refreshSensorTimeline(containing: selectedDate)
        }
    }

    func deleteFrequentPlace(_ placeID: UUID) {
        guard let target = snapshot.settings.frequentPlaces.first(where: {
            $0.id == placeID
        }) else {
            return
        }
        if let point = target.point {
            rememberDismissedPlaceSuggestion(at: point)
        }
        guard target.kind == .custom || target.kind == .restaurant else {
            snapshot.settings.frequentPlaces =
                snapshot.settings.frequentPlaces.map { place in
                    guard place.id == placeID else { return place }
                    return FrequentPlace(kind: place.kind)
                }
            Task { await persist() }
            return
        }
        snapshot.settings.frequentPlaces.removeAll { $0.id == placeID }
        Task { await persist() }
    }

    // MARK: - 등록하지 않은 자주 가는 곳

    /// 설정 화면을 열 때만 다시 구한다. 저장된 체류만 읽으므로 새 위치 수집도,
    /// 새 권한도 필요 없다.
    func refreshFrequentPlaceSuggestion() {
        frequentPlaceSuggestion = UnregisteredPlaceSuggestionEngine()
            .suggestion(
                places: snapshot.places,
                frequentPlaces: snapshot.settings.frequentPlaces,
                dismissed: snapshot.settings.dismissedPlaceSuggestions
            )
    }

    /// 제안한 자리를 사용자가 고른 종류로 등록한다. 좌표는 이미 모은 체류에서
    /// 나오므로 사용자는 종류만 고르면 된다. 이름과 반경은 이어서 열리는 기존
    /// 설정 화면에서 고친다.
    @discardableResult
    func registerFrequentPlaceSuggestion(
        as kind: FrequentPlaceKind
    ) -> UUID? {
        guard acceptsDataMutation() else { return nil }
        guard let suggestion = frequentPlaceSuggestion else { return nil }
        let reading = SensorReading(
            timestamp: suggestion.lastVisitedAt,
            point: suggestion.point
        )
        let index: Int
        if kind != .custom, kind != .restaurant,
           let empty = snapshot.settings.frequentPlaces.firstIndex(where: {
               $0.kind == kind && $0.point == nil
           }) {
            index = empty
        } else {
            // 이름을 지어내지 않는다. 역지오코딩이 붙여 준 이름이 없으면
            // 좌표를 그대로 넣고 사용자가 고치게 둔다.
            snapshot.settings.frequentPlaces.append(
                FrequentPlace(
                    kind: kind,
                    name: suggestion.suggestedName
                        ?? Self.coordinateLabel(suggestion.point)
                )
            )
            index = snapshot.settings.frequentPlaces.count - 1
        }
        let floor = snapshot.settings.frequentPlaces[index].floor ?? 1
        snapshot.settings.frequentPlaces[index].setLocation(
            from: reading,
            floor: floor
        )
        snapshot.settings.frequentPlaces =
            AppFeatureSettings.mergedFrequentPlaces(
                snapshot.settings.frequentPlaces
            )
        let placeID = snapshot.settings.frequentPlaces[index].id
        snapshot.places = FrequentPlaceResolutionEngine().applying(
            snapshot.settings.frequentPlaces,
            to: snapshot.places,
            readings: [reading]
        )
        frequentPlaceSuggestion = nil
        Task {
            await persist()
            await refreshSensorTimeline(containing: selectedDate)
        }
        return placeID
    }

    /// 거절은 영구히 기억한다. 같은 곳을 매주 다시 묻는 것이 한 번도 묻지
    /// 않는 것보다 나쁘다.
    func dismissFrequentPlaceSuggestion() {
        guard let suggestion = frequentPlaceSuggestion else { return }
        rememberDismissedPlaceSuggestion(at: suggestion.point)
        frequentPlaceSuggestion = nil
        Task { await persist() }
    }

    static func coordinateLabel(_ point: GeoPoint) -> String {
        String(
            format: "%.5f, %.5f",
            point.latitude,
            point.longitude
        )
    }

    /// 자주가는 곳에서 지운 자리도 같은 목록에 넣는다. 지우자마자 "등록할
    /// 까요?"가 다시 뜨면 지운 것이 지워지지 않은 셈이다.
    private func rememberDismissedPlaceSuggestion(at point: GeoPoint) {
        let radius = UnregisteredPlaceSuggestionEngine().dismissalRadiusMeters
        guard !snapshot.settings.dismissedPlaceSuggestions.contains(where: {
            distanceMeters($0.point, point) <= radius
        }) else {
            return
        }
        snapshot.settings.dismissedPlaceSuggestions.append(
            DismissedPlaceSuggestion(point: point)
        )
        if let suggestion = frequentPlaceSuggestion,
           distanceMeters(suggestion.point, point) <= radius {
            frequentPlaceSuggestion = nil
        }
    }

    func confirmFloorTransition(
        _ transitionID: UUID,
        toFloor: Int?
    ) {
        guard let index = snapshot.floorTransitions.firstIndex(where: {
            $0.id == transitionID
        }) else {
            return
        }
        snapshot.floorTransitions[index].toFloor = toFloor
        snapshot.floorTransitions[index].confidence = .high
        if !snapshot.floorTransitions[index].isUserConfirmed {
            snapshot.floorTransitions[index].evidence.append(
                FloorTransition.userConfirmedEvidence
            )
        }
        if let toFloor,
           let placeIndex = snapshot.places.firstIndex(where: {
               $0.placeKey == snapshot.floorTransitions[index].placeKey
                   && $0.span.contains(
                       snapshot.floorTransitions[index].span.end
                   )
           }) {
            snapshot.places[placeIndex].floor = toFloor
            snapshot.places[placeIndex].confidence = .high
            snapshot.places[placeIndex].isConfirmed = true
        }
        Task { await persist() }
    }

    func photoThumbnailData(
        localIdentifier: String,
        size: CGSize
    ) async throws -> Data {
        try await photoService.thumbnailJPEG(
            localIdentifier: localIdentifier,
            size: size
        )
    }

    nonisolated static func migrateLegacyFloorCalibration(
        in snapshot: inout TaptionDataSnapshot
    ) {
        guard let calibration = snapshot.settings.floorCalibration else {
            return
        }
        defer { snapshot.settings.floorCalibration = nil }
        guard calibration.isCaptured,
              let point = calibration.referencePoint,
              let index = snapshot.settings.frequentPlaces.firstIndex(where: {
                  $0.kind == .home
              }) else {
            return
        }
        let existingPoint =
            snapshot.settings.frequentPlaces[index].point
        if let existingPoint,
           distanceMeters(existingPoint, point)
            > snapshot.settings.frequentPlaces[index].radiusMeters {
            return
        }
        if existingPoint == nil {
            snapshot.settings.frequentPlaces[index].point = point
        }
        if snapshot.settings.frequentPlaces[index].floor == nil {
            snapshot.settings.frequentPlaces[index].floor =
                calibration.referenceFloor
        }
        snapshot.settings.frequentPlaces[index]
            .referenceRelativeAltitudeMeters =
                snapshot.settings.frequentPlaces[index]
                    .referenceRelativeAltitudeMeters
                ?? calibration.referenceRelativeAltitudeMeters
        snapshot.settings.frequentPlaces[index]
            .referencePressureKilopascals =
                snapshot.settings.frequentPlaces[index]
                    .referencePressureKilopascals
                ?? calibration.referencePressureKilopascals
        snapshot.settings.frequentPlaces[index]
            .referenceAltimeterSessionID =
                snapshot.settings.frequentPlaces[index]
                    .referenceAltimeterSessionID
                ?? calibration.referenceAltimeterSessionID
        snapshot.settings.frequentPlaces[index].floorCapturedAt =
            snapshot.settings.frequentPlaces[index].floorCapturedAt
            ?? calibration.capturedAt
        snapshot.settings.frequentPlaces[index].updatedAt =
            calibration.capturedAt ?? .now
    }
}
