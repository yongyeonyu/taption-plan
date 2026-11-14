import Foundation
import TaptionPlanCore

extension AppModel {
    func setMapCategoryColor(_ hex: String, for categoryID: String) {
        if let categoryUUID = UUID(uuidString: categoryID),
           let index = snapshot.settings.mapUserActivityCategories.firstIndex(where: { $0.id == categoryUUID }) {
            guard snapshot.settings.mapUserActivityCategories[index].hex != hex else { return }
            snapshot.settings.mapUserActivityCategories[index].hex = hex
            Task { await persist() }
            return
        }
        var values = snapshot.settings.mapCategoryColors
        values[categoryID] = hex
        let normalized = AppFeatureSettings.normalizedMapCategoryColors(values)
        guard normalized != snapshot.settings.mapCategoryColors else { return }
        snapshot.settings.mapCategoryColors = normalized
        Task { await persist() }
    }

    @discardableResult
    func addMapUserActivityCategory(
        title: String,
        systemImage: String,
        hex: String,
        animation: MapUserActivityAnimation? = nil
    ) -> Bool {
        guard acceptsDataMutation() else { return false }
        guard MapUserActivityIconCatalog.available(
            for: snapshot.settings.mapUserActivityCategories
        ).contains(systemImage) else {
            userFacingError = AppLanguagePreference.text(
                korean: "이미 사용 중인 행동분류 아이콘입니다.",
                english: "This activity category icon is already in use."
            )
            return false
        }
        let next = AppFeatureSettings.normalizedMapUserActivityCategories(
            snapshot.settings.mapUserActivityCategories + [
                MapUserActivityCategory(
                    id: UUID(),
                    title: title,
                    systemImage: systemImage,
                    hex: hex,
                    animation: animation
                ),
            ]
        )
        guard next != snapshot.settings.mapUserActivityCategories else {
            return false
        }
        snapshot.settings.mapUserActivityCategories = next
        MapHomeCustomAnimations.register(next)
        Task { await persist() }
        return true
    }

    @discardableResult
    func updateMapUserActivityCategory(
        id: UUID,
        title: String,
        systemImage: String,
        hex: String,
        animation: MapUserActivityAnimation?
    ) -> Bool {
        guard acceptsDataMutation() else { return false }
        let categories = snapshot.settings.mapUserActivityCategories
        guard let index = categories.firstIndex(where: { $0.id == id }) else { return false }
        let others = categories.filter { $0.id != id }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !others.contains(where: { $0.title.localizedCaseInsensitiveCompare(cleanTitle) == .orderedSame }) else {
            userFacingError = AppLanguagePreference.text(
                korean: "같은 이름의 행동분류가 있습니다.",
                english: "An activity category with this name already exists."
            )
            return false
        }
        guard !others.contains(where: { $0.systemImage == systemImage }) else {
            userFacingError = AppLanguagePreference.text(
                korean: "이미 사용 중인 행동분류 아이콘입니다.",
                english: "This activity category icon is already in use."
            )
            return false
        }
        var edited = categories
        edited[index] = MapUserActivityCategory(
            id: id, title: cleanTitle, systemImage: systemImage, hex: hex, animation: animation
        )
        let next = AppFeatureSettings.normalizedMapUserActivityCategories(edited)
        guard next.count == categories.count else { return false }
        guard next != categories else { return true }
        snapshot.settings.mapUserActivityCategories = next
        MapHomeCustomAnimations.register(next)
        Task { await persist() }
        return true
    }

    /// 분류 목록에서만 뺀다. 기록은 분류 이름을 값으로 들고 있어 그대로 남는다.
    func deleteMapUserActivityCategory(id: UUID) {
        guard acceptsDataMutation() else { return }
        let next = snapshot.settings.mapUserActivityCategories.filter { $0.id != id }
        guard next.count != snapshot.settings.mapUserActivityCategories.count else { return }
        snapshot.settings.mapUserActivityCategories = next
        MapHomeCustomAnimations.register(next)
        Task { await persist() }
    }

    @discardableResult
    func addMapSticker(
        title: String,
        memo: String? = nil,
        systemImage: String = "star.fill",
        colorHex: String = "#F28FA9",
        placement: MapStickerPlacement,
        point: GeoPoint?,
        planID: UUID?,
        occurredAt: Date
    ) -> UUID? {
        guard acceptsDataMutation() else { return nil }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return nil }
        guard placement == .schedule || point != nil else { return nil }
        let sticker = MapSticker(
            title: cleanTitle,
            memo: cleanOptionalMapStickerMemo(memo),
            systemImage: systemImage,
            colorHex: colorHex,
            placement: placement,
            point: point,
            planID: planID,
            occurredAt: occurredAt
        )
        snapshot.stickers.append(sticker)
        Task { await persist() }
        return sticker.id
    }

    @discardableResult
    func updateMapSticker(
        _ stickerID: UUID,
        title: String,
        memo: String? = nil,
        systemImage: String,
        colorHex: String,
        placement: MapStickerPlacement,
        point: GeoPoint?,
        planID: UUID?,
        occurredAt: Date
    ) -> Bool {
        guard acceptsDataMutation() else { return false }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty,
              placement == .schedule || point != nil,
              let index = snapshot.stickers.firstIndex(where: { $0.id == stickerID })
        else { return false }
        var sticker = snapshot.stickers[index]
        sticker.title = cleanTitle
        sticker.memo = cleanOptionalMapStickerMemo(memo)
        sticker.systemImage = systemImage
        sticker.colorHex = colorHex
        sticker.placement = placement
        sticker.point = point
        sticker.planID = planID
        sticker.occurredAt = occurredAt
        sticker.updatedAt = .now
        snapshot.stickers[index] = sticker
        Task { await persist() }
        return true
    }

    private func cleanOptionalMapStickerMemo(_ text: String?) -> String? {
        guard let text else { return nil }
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanText.isEmpty ? nil : cleanText
    }

    func deleteMapSticker(_ stickerID: UUID) {
        guard acceptsDataMutation() else { return }
        guard snapshot.stickers.contains(where: { $0.id == stickerID }) else {
            return
        }
        snapshot.settings.cloudDeletedRecordKeys.insert(
            CloudBackupRecordKey.sticker(stickerID)
        )
        snapshot.stickers.removeAll { $0.id == stickerID }
        Task { await persist() }
    }

    func confirmTravel(_ travelID: UUID, mode: TravelMode) {
        confirmTravel([travelID], mode: mode)
    }

    func confirmTravel(_ travelIDs: [UUID], mode: TravelMode) {
        let ids = Set(travelIDs)
        let previousSegments = snapshot.travel.filter { ids.contains($0.id) }
        var corrections = snapshot.settings.movementCorrections
        var didChange = false
        for index in snapshot.travel.indices
        where ids.contains(snapshot.travel[index].id) {
            let wasChanged = snapshot.travel[index].mode != mode
            corrections = MovementCorrectionEngine.recording(
                mode: mode,
                for: snapshot.travel[index],
                places: snapshot.places,
                existing: corrections
            )
            snapshot.travel[index].mode = mode
            snapshot.travel[index].confidence = .high
            snapshot.travel[index].isConfirmed = true
            if mode != .subway { snapshot.travel[index].subwayRoute = nil }
            snapshot.travel[index].evidence.removeAll {
                $0.hasPrefix("사용자 확인") || $0 == "사용자 교정"
                    || (mode != .subway && $0.hasPrefix("사용자 확정 경로 ·"))
            }
            snapshot.travel[index].evidence.append(
                wasChanged ? "사용자 확인 · 수단 수정" : "사용자 확인"
            )
            didChange = true
        }
        guard didChange else { return }
        snapshot.settings.movementCorrections = corrections
        snapshot.settings.transitBoardingDecisions = TransitBoardingDecisionEngine.removingConfirmations(
            for: previousSegments, from: snapshot.settings.transitBoardingDecisions)
        snapshot.settings.predictedRouteDecisions.removeAll {
            !$0.isDeleted && $0.route.travelID.map(ids.contains) == true
        }
        Task { await persist() }
    }

    /// 탈것 탑승 질문의 답(BCF1114A01). 수단을 사용자 확인으로 굳히고, 버스 노선을 골랐으면 근거와 기록 이름에 남긴다.
    func confirmRide(_ travelID: UUID, mode: TravelMode, busRoute: BusRouteCheck.Route?) {
        guard let segment = snapshot.travel.first(where: { $0.id == travelID }) else { return }
        if mode == .bus, let busRoute { BusRouteCheck.remember(segment, routes: [busRoute]) }
        confirmTravel(travelID, mode: mode)
        if let index = snapshot.travel.firstIndex(where: { $0.id == travelID }) {
            snapshot.travel[index].evidence.removeAll { $0.hasPrefix("노선 ") }
            if mode == .bus, let busRoute { snapshot.travel[index].evidence.append("노선 " + busRoute.number) }
        }
        applyBusRecordTitles(in: segment.span, asOf: max(segment.span.end, .now))
    }

    /// 번호·노선을 정해 준다(RDQ1114A01). 버스는 그 번호 하나로, 지하철은 정해 준 노선으로 이름표에 남긴다.
    func confirmRideLine(_ travelID: UUID, line: String) {
        guard let segment = snapshot.travel.first(where: { $0.id == travelID }) else { return }
        if segment.mode == .subway {
            SubwayLineChoice.remember(segment, line: line)
            confirmTravel(travelID, mode: .subway)
        } else {
            confirmRide(travelID, mode: .bus, busRoute: BusRouteCheck.Route(number: line, kind: ""))
        }
    }

    @discardableResult
    func confirmTransitBoarding(_ candidate: TransitBoardingCandidate) async -> Bool {
        await saveTransitBoardingDecision(for: candidate, mode: candidate.mode)
    }

    @discardableResult
    func savePredictedRouteDecision(_ route: MapPredictedRoute, deleting: Bool) async -> Bool {
        guard acceptsDataMutation(), route.isValid, !Task.isCancelled else { return false }
        activeDataMutationCount += 1
        defer { activeDataMutationCount -= 1 }
        let generation = dataDeletionGeneration
        do {
            while acceptsDataMutation(), generation == dataDeletionGeneration {
                try Task.checkCancellation()
                let revision = snapshotRevision
                var value = snapshotForPersistence()
                value.settings.predictedRouteDecisions.removeAll { $0.matches(route) }
                value.settings.predictedRouteDecisions.append(.init(route: route,
                    isDeleted: deleting, updatedAt: .now))
                if !deleting, let travelID = route.travelID,
                   let index = value.travel.firstIndex(where: { $0.id == travelID }) {
                    value.travel[index].isConfirmed = true
                    value.travel[index].confidence = .high
                    let evidence = "사용자 확정 경로 · 예상 좌표 기반"
                    if !value.travel[index].evidence.contains(evidence) { value.travel[index].evidence.append(evidence) }
                }
                value.updatedAt = .now
                guard try await saveToRepository(value, expectedRevision: revision),
                      revision == snapshotRevision else { continue }
                value.memos = snapshot.memos
                snapshot = value
                schedulePostSaveRefresh()
                publishWidgetPayload()
                return true
            }
        } catch is CancellationError {
            return false
        } catch {
            userFacingError = AppLanguagePreference.text(
                korean: "경로를 저장하지 못했습니다. 다시 시도해 주세요.",
                english: "Could not save the route. Please try again."
            )
            TaptionPlanDiagnosticsLogger.shared.record("predicted_route_save_failed", level: .error,
                fields: ["action": deleting ? "delete" : "confirm", "error_type": String(describing: type(of: error))])
        }
        return false
    }

    @discardableResult
    func deleteTransitBoardingCandidate(_ candidate: TransitBoardingCandidate) async -> Bool {
        await saveTransitBoardingDecision(for: candidate, mode: nil)
    }

    private func saveTransitBoardingDecision(
        for candidate: TransitBoardingCandidate,
        mode: TravelMode?
    ) async -> Bool {
        guard acceptsDataMutation(), !Task.isCancelled else { return false }
        activeDataMutationCount += 1
        defer { activeDataMutationCount -= 1 }
        let generation = dataDeletionGeneration
        let ids = Set(candidate.travelSegmentIDs)
        let decision = TransitBoardingDecision(
            candidateKey: candidate.id, placeID: candidate.placeID,
            kind: candidate.kind, point: candidate.point, span: candidate.span,
            mode: mode, travelSegmentIDs: candidate.travelSegmentIDs,
            subwayRoutes: mode == .subway
                ? candidate.subwayRoutes.filter { ids.contains($0.travelSegmentID) } : nil)
        do {
            // Rebase on sensor/other edits that arrive while the repository write is waiting.
            while acceptsDataMutation(), generation == dataDeletionGeneration {
                try Task.checkCancellation()
                guard mode == nil || snapshot.travel.contains(where: { ids.contains($0.id) }) else {
                    userFacingError = AppLanguagePreference.text(
                        korean: "이동 기록이 변경되었습니다. 지도의 탑승 후보를 다시 선택해 주세요.",
                        english: "The movement record has changed. Select the boarding candidate on the map again."
                    )
                    return false
                }
                let revision = snapshotRevision
                var value = snapshotForPersistence()
                if let mode {
                    for segment in value.travel where ids.contains(segment.id) {
                        value.settings.movementCorrections = MovementCorrectionEngine.recording(
                            mode: mode, for: segment,
                            places: value.places, existing: value.settings.movementCorrections)
                    }
                    value.travel = value.travel.map { segment in
                        guard ids.contains(segment.id) else { return segment }
                        return TransitBoardingDecisionEngine.applying([decision], to: [segment]).first ?? segment
                    }
                }
                value.settings.transitBoardingDecisions.removeAll {
                    $0.candidateKey == decision.candidateKey
                }
                value.settings.transitBoardingDecisions.append(decision)
                value.settings.transitBoardingDecisions.sort { $0.updatedAt < $1.updatedAt }
                if value.settings.transitBoardingDecisions.count > 200 {
                    value.settings.transitBoardingDecisions.removeFirst(
                        value.settings.transitBoardingDecisions.count - 200)
                }
                value.updatedAt = .now
                guard try await saveToRepository(value, expectedRevision: revision),
                      revision == snapshotRevision else { continue }
                value.memos = snapshot.memos
                snapshot = value
                schedulePostSaveRefresh()
                publishWidgetPayload()
                return true
            }
        } catch is CancellationError {
            return false
        } catch {
            userFacingError = AppLanguagePreference.text(
                korean: mode == nil
                    ? "탑승 후보를 삭제하지 못했습니다. 다시 시도해 주세요."
                    : "탑승 경로를 저장하지 못했습니다. 다시 시도해 주세요.",
                english: mode == nil
                    ? "Could not delete the boarding candidate. Please try again."
                    : "Could not save the boarding route. Please try again."
            )
            TaptionPlanDiagnosticsLogger.shared.record("transit_boarding_save_failed", level: .error,
                fields: ["error": String(describing: type(of: error))])
        }
        return false
    }

    func forgetTravelConfirmation(_ travelID: UUID) {
        forgetTravelConfirmations([travelID])
    }

    func forgetTravelConfirmations(_ travelIDs: [UUID]) {
        let ids = Set(travelIDs)
        let previousSegments = snapshot.travel.filter { ids.contains($0.id) }
        var corrections = snapshot.settings.movementCorrections
        var earliestStart: Date?
        for index in snapshot.travel.indices
        where ids.contains(snapshot.travel[index].id) {
            let segment = snapshot.travel[index]
            let correction = MovementCorrectionEngine.correction(
                for: segment,
                places: snapshot.places,
                in: corrections
            )
            corrections = MovementCorrectionEngine.removingCorrection(
                for: segment,
                places: snapshot.places,
                from: corrections
            )
            snapshot.travel[index].mode = correction?.inferredMode ?? segment.mode
            snapshot.travel[index].confidence =
                correction?.inferredConfidence ?? .medium
            snapshot.travel[index].isConfirmed = false
            snapshot.travel[index].subwayRoute = nil
            snapshot.travel[index].evidence.removeAll {
                $0.hasPrefix("사용자 확인") || $0 == "사용자 교정"
                    || $0.hasPrefix("사용자 확정 경로 ·")
            }
            earliestStart = min(earliestStart ?? segment.span.start, segment.span.start)
        }
        guard let earliestStart else { return }
        snapshot.settings.movementCorrections = corrections
        snapshot.settings.transitBoardingDecisions = TransitBoardingDecisionEngine.removingConfirmations(
            for: previousSegments, from: snapshot.settings.transitBoardingDecisions)
        snapshot.settings.predictedRouteDecisions.removeAll {
            !$0.isDeleted && $0.route.travelID.map(ids.contains) == true
        }
        Task {
            await persist()
            await refreshSensorTimeline(containing: earliestStart)
            await persistDeviceLocalSnapshot()
        }
    }
}
