import Foundation
import WidgetKit
import TaptionPlanCore

extension AppModel {
    func reconcileSensorCollectionLiveActivity(
        isForeground: Bool
    ) async {
        let controller = SensorCollectionLiveActivityController.shared
        let kinds = sensorCollectionKinds
        let projection = liveActivityCurrentProjection() ?? currentLiveActivityProjection()
        await liveActivityController.updateCompactActivity(
            title: projection.title,
            categoryID: projection.categoryID,
            animationFrame: sensorSaveToken % 6
        )
        guard sensorCollectionSessionState == .collecting,
              let sessionID = sensorCollectionSessionID,
              let startedAt = sensorCollectionStartedAt else {
            await controller.removeExpired()
            await controller.stop(
                lastSavedAt: lastSensorSavedAt,
                collectionKinds: kinds,
                saveToken: sensorSaveToken
            )
            return
        }
        _ = try? await controller.reconcile(
            sessionID: sessionID,
            startedAt: startedAt,
            lastSavedAt: lastSensorSavedAt,
            collectionKinds: kinds,
            isCollecting: true,
            isForeground: isForeground,
            intervalSeconds: settings.gpsLoggingPreferences
                .effectiveIntervalSeconds,
            saveToken: sensorSaveToken,
            validSampleKinds: latestSensorReading.map {
                validSensorCollectionKinds(for: $0)
            } ?? [],
            isExternalSample: latestSensorReading?.sourceDevice == .appleWatch,
            latestHeartRate: latestHeartRate,
            heartRateUpdatedAt: latestHeartRateUpdatedAt,
            currentActivityTitle: projection.title,
            currentActivityCategoryID: projection.categoryID,
            currentActivitySystemImage: projection.systemImage,
            currentActivityCatStyle: settings.catStyle.rawValue
        )
        #if DEBUG
        recordRequestedCurrentIslandVerification()
        #endif
    }

    private var sensorCollectionKinds: [String] {
        var kinds = ["location"]
        if let availability = sensorAvailability {
            if availability.motionActivity || availability.deviceMotion {
                kinds.append("motion")
            }
            if availability.relativeAltitude {
                kinds.append("altitude")
            }
            if availability.stepCounting {
                kinds.append("steps")
            }
        }
        if settings.healthEnabled {
            kinds.append("health")
        }
        kinds.append("wifi")
        return kinds
    }

    private func validSensorCollectionKinds(
        for reading: SensorReading
    ) -> [String] {
        var kinds: [String] = []
        if reading.gpsAvailable,
           let point = reading.point,
           (-90...90).contains(point.latitude),
           (-180...180).contains(point.longitude),
           point.horizontalAccuracy.isFinite,
           point.horizontalAccuracy >= 0,
           point.horizontalAccuracy <= 150 {
            kinds.append("location")
        }
        if reading.motion != .unknown
            || reading.deviceMotion != nil
            || reading.deviceMotionSummary != nil {
            kinds.append("motion")
        }
        if reading.relativeAltitudeMeters?.isFinite == true
            || reading.pressureKilopascals?.isFinite == true {
            kinds.append("altitude")
        }
        let hasValidStepCount = reading.stepCount.map { $0 >= 0 } ?? false
        let hasValidWalkingDistance = reading.walkingRunningDistanceMeters.map {
            $0.isFinite && $0 >= 0
        } ?? false
        let hasValidCadence = reading.currentCadenceStepsPerSecond.map {
            $0.isFinite && $0 >= 0
        } ?? false
        if hasValidStepCount || hasValidWalkingDistance || hasValidCadence {
            kinds.append("steps")
        }
        if settings.healthEnabled,
           reading.sourceDevice == .appleWatch {
            kinds.append("health")
        }
        if let ssid = reading.connectedWiFiSSID,
           !ssid.isEmpty {
            kinds.append("wifi")
        }
        return kinds
    }

    func setWidgetPhotosVisible(_ visible: Bool) {
        snapshot.settings.showsPhotosInWidgets =
            visible && permissionState(for: .photos).isGranted
        Task { await persist() }
    }

    func refreshWidgetNow() {
        publishWidgetPayload()
    }

    /// 언어를 바꾸면 위젯 내용을 다시 만들어 워치에 바로 보낸다. 위젯 화면 문구는 위젯이 그릴 때
    /// 정하므로 내용이 같아도 타임라인을 다시 읽힌다.
    func languagePreferenceDidChange() {
        lastWidgetPayloadInput = nil
        publishWidgetPayload()
        WidgetCenter.shared.reloadAllTimelines()
    }

    func currentMajorCategory(for plan: PlanRecord) -> (
        id: String,
        title: String,
        systemImage: String
    ) {
        let storedTitle = snapshot.categories.first(where: {
            $0.id == plan.categoryID
        })?.name
            ?? TimelineRowKind.title(forCategoryID: plan.categoryID)
            ?? AppLanguagePreference.text(korean: "활동", english: "Activity")
        let title: String = switch plan.categoryID {
        case "activity": AppLanguagePreference.text(korean: "활동", english: "Activity")
        case "work": AppLanguagePreference.text(korean: "업무", english: "Work")
        case "study": AppLanguagePreference.text(korean: "수업", english: "Study")
        case "hobby": AppLanguagePreference.text(korean: "취미", english: "Hobby")
        case "sleep": AppLanguagePreference.text(korean: "수면", english: "Sleep")
        case "movement": AppLanguagePreference.text(korean: "이동", english: "Movement")
        case "eating": AppLanguagePreference.text(korean: "식사", english: "Eating")
        case "exercise": AppLanguagePreference.text(korean: "운동", english: "Exercise")
        case "unconfirmed": AppLanguagePreference.text(korean: "미확인", english: "Unconfirmed")
        default: storedTitle
        }
        let systemImage = RecordClassificationCatalog.categories.first {
            $0.id == plan.categoryID
        }?.systemImage ?? TimelineRowKind(categoryID: plan.categoryID)?.systemImage
            ?? "sparkles"
        return (plan.categoryID, title, systemImage)
    }

    func currentLiveActivityProjection(at date: Date = .now) -> (
        title: String,
        categoryID: String,
        systemImage: String,
        startedAt: Date
    ) {
        if !TaptionExternalPrivacyStore.isLocked,
           let categoryID = TaptionCurrentActivityPolicy.categoryID(
            actuals: snapshot.actuals,
            plans: snapshot.plans,
            at: date,
            latestSavedAt: lastSensorSavedAt,
            latestReading: latestSensorReading
        ) {
            let systemImage = RecordClassificationCatalog.categories.first {
                $0.id == categoryID
            }?.systemImage ?? TimelineRowKind(categoryID: categoryID)?.systemImage
                ?? "sparkles"
            let title = RecordClassificationCatalog.categories.first {
                $0.id == categoryID
            }?.title ?? TimelineRowKind.title(forCategoryID: categoryID)
                ?? AppLanguagePreference.text(korean: "활동", english: "Activity")
            return (title, categoryID, systemImage, currentActivityStartedAt(at: date))
        }
        return (
            AppLanguagePreference.text(korean: "확인 중", english: "Checking"),
            "unconfirmed",
            "questionmark",
            date
        )
    }

    /// 지금 대분류가 시작된 시각. 같은 대분류가 이어진 구간은 가장 이른 시작을 쓴다.
    /// 워치가 "몇 분째"를 스스로 셀 수 있게 함께 넘긴다.
    private func currentActivityStartedAt(at date: Date) -> Date {
        snapshot.actuals
            .filter { actual in
                actual.startedAt <= date
                    && (actual.endedAt.map { date < $0 } ?? true)
            }
            .map(\.startedAt)
            .min()
            ?? snapshot.plans
                .last { $0.status == .running && $0.span.start <= date }?
                .span.start
            ?? date
    }

    func performQuickAction(
        _ action: WidgetAction,
        planID: UUID,
        at date: Date = .now
    ) async {
        guard let index = snapshot.plans.firstIndex(where: { $0.id == planID }) else {
            userFacingError = AppLanguagePreference.text(
                korean: "선택한 계획을 찾지 못했습니다.",
                english: "Could not find the selected plan."
            )
            return
        }
        let plan = snapshot.plans[index]
        do {
            switch action {
            case .complete, .stopCurrentActivity:
                let result = QuickActionEngine.complete(
                    plan: plan,
                    actuals: snapshot.actuals,
                    at: date,
                    copyPlannedDurationWhenMissing: action == .complete
                )
                snapshot.plans[index] = result.plan
                snapshot.actuals = result.actuals
                let majorCategory = currentMajorCategory(for: result.plan)
                try? await liveActivityController.stop(
                    plan: result.plan,
                    catStyle: snapshot.settings.catStyle,
                    majorCategoryID: majorCategory.id,
                    majorCategoryTitle: majorCategory.title,
                    majorCategorySystemImage: majorCategory.systemImage
                )
            case .postponeThirtyMinutes:
                snapshot.plans[index] = try QuickActionEngine.postpone(plan: plan)
            case .moveToNextFreeTime:
                let occupied = snapshot.plans
                    .filter { $0.id != planID && $0.status != .skipped }
                    .map(\.span)
                    + snapshot.calendarEvents.map(\.span)
                snapshot.plans[index] = try QuickActionEngine.moveToNextFreeTime(
                    plan: plan,
                    occupied: occupied,
                    after: date
                )
            }
            await persist()
        } catch {
            userFacingError = AppLanguagePreference.text(
                korean: "계획을 처리하지 못했습니다. \(error.localizedDescription)",
                english: "Could not process the plan. \(error.localizedDescription)"
            )
        }
    }

    func startPlan(_ planID: UUID, at date: Date = .now) async {
        guard let index = snapshot.plans.firstIndex(where: { $0.id == planID }) else {
            userFacingError = AppLanguagePreference.text(
                korean: "선택한 계획을 찾지 못했습니다.",
                english: "Could not find the selected plan."
            )
            return
        }
        let result = QuickActionEngine.start(
            plan: snapshot.plans[index],
            actuals: snapshot.actuals,
            at: date
        )
        snapshot.plans[index] = result.plan
        snapshot.actuals = result.actuals
        let majorCategory = currentMajorCategory(for: result.plan)
        let projection = currentLiveActivityProjection()
        do {
            _ = try await liveActivityController.start(
                plan: result.plan,
                catStyle: snapshot.settings.catStyle,
                majorCategoryID: majorCategory.id,
                majorCategoryTitle: majorCategory.title,
                majorCategorySystemImage: majorCategory.systemImage,
                compactActivityTitle: projection.title,
                compactActivityCategoryID: projection.categoryID
            )
        } catch LiveActivityError.unavailable {
            // The plan timer still works when Live Activities are disabled.
        } catch {
            userFacingError = AppLanguagePreference.text(
                korean: "Live Activity를 시작하지 못했습니다. \(error.localizedDescription)",
                english: "Could not start the Live Activity. \(error.localizedDescription)"
            )
        }
        await persist()
    }

    func pausePlan(_ planID: UUID, at date: Date = .now) async {
        guard let index = snapshot.plans.firstIndex(where: { $0.id == planID }) else {
            userFacingError = AppLanguagePreference.text(
                korean: "선택한 계획을 찾지 못했습니다.",
                english: "Could not find the selected plan."
            )
            return
        }
        snapshot.plans[index].status = .planned
        snapshot.plans[index].updatedAt = date
        if let actualIndex = snapshot.actuals.lastIndex(where: {
            $0.planID == planID && $0.endedAt == nil
        }) {
            snapshot.actuals[actualIndex].endedAt = max(
                snapshot.actuals[actualIndex].startedAt,
                date
            )
        }
        let majorCategory = currentMajorCategory(for: snapshot.plans[index])
        try? await liveActivityController.stop(
            plan: snapshot.plans[index],
            catStyle: snapshot.settings.catStyle,
            majorCategoryID: majorCategory.id,
            majorCategoryTitle: majorCategory.title,
            majorCategorySystemImage: majorCategory.systemImage
        )
        await persist()
    }

    func skipPlan(_ planID: UUID) async {
        guard let index = snapshot.plans.firstIndex(where: { $0.id == planID }) else {
            userFacingError = AppLanguagePreference.text(
                korean: "선택한 계획을 찾지 못했습니다.",
                english: "Could not find the selected plan."
            )
            return
        }
        snapshot.plans[index] = QuickActionEngine.skip(plan: snapshot.plans[index])
        await persist()
    }

    /// 지금 대분류가 바뀌는 순간을 놓치지 않도록 짧은 주기로 확인한다.
    /// 저장·센서 콜백은 몇 초씩 몰아서 오기 때문에, 계획이 끝나고 다음 대분류로 넘어가는
    /// 경계에서는 아무 이벤트도 오지 않아 아일랜드·잠금화면·워치가 이전 활동에 머물렀다.
    func startCurrentActivitySyncIfNeeded() {
        currentActivitySyncTask?.cancel()
        currentActivitySyncTask = nil
        guard isSceneActive else { return }

        currentActivitySyncTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        for: .seconds(CurrentActivitySyncPolicy.intervalSeconds)
                    )
                } catch {
                    return
                }
                guard let self, !Task.isCancelled, self.isSceneActive else {
                    return
                }
                await self.publishCurrentActivityIfChanged()
            }
        }
    }

    func stopCurrentActivitySync() {
        currentActivitySyncTask?.cancel()
        currentActivitySyncTask = nil
    }

    /// 대분류가 바뀐 경우에만 아일랜드·잠금화면·워치로 밀어 준다.
    func publishCurrentActivityIfChanged(now: Date = .now) async {
        let projection = currentLiveActivityProjection(at: now)
        let key = (categoryID: projection.categoryID, title: projection.title)
        if let last = lastPublishedCurrentActivity,
           last == key {
            return
        }
        lastPublishedCurrentActivity = key
        await reconcileSensorCollectionLiveActivity(isForeground: isSceneActive)
        publishWatchPayload(now: now)
        TaptionPlanDiagnosticsLogger.shared.record(
            "current_activity_published",
            fields: [
                "category": projection.categoryID,
                "title": projection.title,
            ]
        )
    }

    func applyPendingWidgetCommands(
        repositoryAlreadyLoaded: Bool
    ) async {
        guard let commands = try? TaptionWidgetSharedStore.takeCommands(),
              !commands.isEmpty else {
            return
        }
        if !repositoryAlreadyLoaded,
           commands.contains(where: {
               $0.appliedToSharedRepository == true
           }),
           let reloaded = try? await repository.load() {
            snapshot = reloaded
        }
        for command in commands {
            guard command.appliedToSharedRepository != true else {
                continue
            }
            do {
                snapshot = try TaptionWidgetCommandEngine.apply(
                    command,
                    to: snapshot
                )
            } catch {
                userFacingError = AppLanguagePreference.text(
                    korean: "위젯 요청을 반영하지 못했습니다. \(error.localizedDescription)",
                    english: "Could not apply the widget request. \(error.localizedDescription)"
                )
            }
        }
    }

    private func normalizedWidgetPayload(
        _ payload: TaptionWidgetPayload
    ) -> TaptionWidgetPayload {
        var normalized = payload
        normalized.generatedAt = .distantPast
        // updatedAt is an envelope timestamp. The source fingerprint and
        // item values carry the actual widget content, so a sensor-only save
        // must not force another app-group write.
        normalized.sourceSnapshotUpdatedAt = nil
        // Recompute-free identity: the fingerprint intentionally includes
        // movement end times, while the comparison below canonicalizes an
        // open movement edge to distantPast.
        normalized.sourceFingerprint = nil
        if let center = payload.displayCenterDate {
            let minute = floor(center.timeIntervalSinceReferenceDate / 60)
            normalized.displayCenterDate = Date(
                timeIntervalSinceReferenceDate: minute * 60
            )
        }
        // Open-ended automatic records use "now" as their presentation end.
        // Ignore that moving edge while comparing payload content.
        normalized.items = payload.items.map { item in
            var item = item
            let isOpenEndedLane =
                item.resolvedLane == .activity
                    || item.resolvedLane == .sleep
                    || item.resolvedLane == .movement
            if isOpenEndedLane,
               item.endsAt >= payload.generatedAt.addingTimeInterval(-120),
               item.endsAt <= payload.generatedAt.addingTimeInterval(120) {
                item.endsAt = .distantPast
            }
            return item
        }
        return normalized
    }

    func publishWidgetPayload(
        hidesSensitiveContent: Bool? = nil
    ) {
        let calendar = Calendar.autoupdatingCurrent
        let now = Date.now
        let hidesSensitiveContent = hidesSensitiveContent
            ?? TaptionExternalPrivacyStore.isLocked
        // 같은 기록·같은 분·같은 잠금이면 위젯 payload를 다시 만들지 않는다(PRF1101A01).
        let input = [Double(snapshotContentRevision), (now.timeIntervalSinceReferenceDate / 60).rounded(.down),
                     hidesSensitiveContent ? 1 : 0]
        guard input != lastWidgetPayloadInput else { return publishWatchPayload(now: now, calendar: calendar) }
        lastWidgetPayloadInput = input
        let payload = TaptionWidgetPayloadFactory.make(
            from: snapshot,
            now: now,
            calendar: calendar,
            hidesSensitiveContent: hidesSensitiveContent
        )
        let identity = normalizedWidgetPayload(payload)
        if lastWidgetPayloadIdentity == identity {
            widgetPayloadSkipCount += 1
            let uptime = ProcessInfo.processInfo.systemUptime
            if uptime - lastWidgetSkipLogUptime >= 5 {
                lastWidgetSkipLogUptime = uptime
                TaptionPlanDiagnosticsLogger.shared.record(
                    "widget_payload_skipped",
                    fields: [
                        "reason": "unchanged",
                        "count": String(widgetPayloadSkipCount),
                    ]
                )
            }
            publishWatchPayload(now: now, calendar: calendar)
            return
        }
        do {
            try TaptionWidgetSharedStore.writePayload(payload)
            lastWidgetPayloadIdentity = identity
            let locationCount = payload.items.filter { $0.resolvedLane == .location }.count
            let movementCount = payload.items.filter { $0.resolvedLane == .movement }.count
            Self.integrationLogger.notice(
                "Widget ground-truth publish: snapshotUpdated=\(self.snapshot.updatedAt.timeIntervalSince1970, privacy: .public), generated=\(payload.generatedAt.timeIntervalSince1970, privacy: .public), fingerprint=\(payload.sourceFingerprint ?? "none", privacy: .public), items=\(payload.items.count, privacy: .public), locations=\(locationCount, privacy: .public), movements=\(movementCount, privacy: .public)"
            )
            TaptionPlanDiagnosticsLogger.shared.record(
                "widget_payload_published",
                fields: [
                    "items": String(payload.items.count),
                    "locations": String(locationCount),
                    "movements": String(movementCount),
                ]
            )
            requestImmediateWidgetRefresh()
        } catch {
            lastWidgetPayloadInput = nil
            Self.integrationLogger.error(
                "Widget ground-truth publish failed: \(error.localizedDescription, privacy: .public)"
            )
            userFacingError = AppLanguagePreference.text(
                korean: "위젯 데이터를 갱신하지 못했습니다. \(error.localizedDescription)",
                english: "Could not update widget data. \(error.localizedDescription)"
            )
            TaptionPlanDiagnosticsLogger.shared.record(
                "widget_payload_failed",
                level: .error,
                fields: ["error": String(describing: type(of: error))]
            )
        }
        publishWatchPayload(now: now, calendar: calendar)
    }

    func setExternalPrivacyLocked(_ isLocked: Bool) {
        TaptionExternalPrivacyStore.setLocked(isLocked)
        publishWidgetPayload(hidesSensitiveContent: isLocked)
    }

    func concealExternalSurfaces() async {
        setExternalPrivacyLocked(true)
        await liveActivityController.concealAll()
    }

    /// The iPhone snapshot is the only Watch settings source. This method is
    /// intentionally separate from widget serialization so a settings toggle
    /// reaches the Watch immediately, before disk or iCloud work finishes.
    func publishWatchPayload(
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        let hidesSensitiveContent = TaptionExternalPrivacyStore.isLocked
        let dayStart = calendar.startOfDay(for: now)
        let weekStart = calendar.dateInterval(
            of: .weekOfYear,
            for: dayStart
        )?.start ?? dayStart
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)
            ?? weekStart.addingTimeInterval(7 * 86_400)
        let categoriesByID = Dictionary(
            snapshot.categories.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let activeActualsByPlanID = Dictionary(
            snapshot.actuals.compactMap { actual -> (UUID, ActualRecord)? in
                guard let planID = actual.planID,
                      actual.endedAt == nil else { return nil }
                return (planID, actual)
            },
            uniquingKeysWith: { current, candidate in
                current.startedAt >= candidate.startedAt
                    ? current
                    : candidate
            }
        )
        // Watch payloads are a live execution queue, not a copy of the
        // historical timeline.  Keep a currently-running item even when it
        // started before this moment, include upcoming items through the
        // current week, and omit ended/completed/skipped records entirely.
        let watchItems = (hidesSensitiveContent ? [] : snapshot.plans)
            .filter { plan in
                guard plan.span.end > now,
                      plan.span.start < weekEnd else {
                    return false
                }
                return plan.status == .planned || plan.status == .running
            }
            .sorted { $0.span.start < $1.span.start }
            .map { plan in
                let category = categoriesByID[plan.categoryID]
                let activeActual = activeActualsByPlanID[plan.id]
                return TaptionWatchPlanItem(
                    id: plan.id,
                    title: plan.title,
                    categoryID: plan.categoryID,
                    startsAt: plan.span.start,
                    endsAt: plan.span.end,
                    status: plan.status.rawValue,
                    actualStartedAt: activeActual?.startedAt,
                    categoryName: category?.name,
                    categoryHex: category?.lightHex,
                    isGoal: GoalRecordPolicy.isGoal(plan),
                    parentID: plan.parentID
                )
            }
        let stopsWatchCollection = isCommerceLocked || !AppleWatchLink.isEnabled()
        let commandCapabilities = hidesSensitiveContent || isCommerceLocked
            ? []
            : TaptionWatchCommandCapabilityStore.reconcile(
                planIDs: Set(watchItems.map(\.id)),
                now: now
            )
        if hidesSensitiveContent || isCommerceLocked {
            TaptionWatchCommandCapabilityStore.clear()
        }
        let watchPayload = TaptionWatchPayload(
            generatedAt: now,
            viewportStart: now,
            viewportEnd: weekEnd,
            items: watchItems,
            catStyle: snapshot.settings.catStyle.rawValue,
            reducesMotion: snapshot.settings.reduceMotion,
            todaySummary: hidesSensitiveContent
                ? nil
                : TaptionWatchDaySummaryFactory.make(
                    plans: snapshot.plans,
                    actuals: snapshot.actuals,
                    categories: Array(categoriesByID.values),
                    at: now,
                    calendar: calendar
                ),
            currentActivity: hidesSensitiveContent
                ? nil
                : watchCurrentActivity(now: now),
            accelerationSettings: TaptionWatchAccelerationSettings(
                profile: stopsWatchCollection
                    ? .off
                    : snapshot.settings.watchAccelerationProfile
            ),
            dataSyncProfile: stopsWatchCollection
                ? .off
                : snapshot.settings.watchDataSyncProfile,
            locationTrackingEnabled: stopsWatchCollection
                ? false
                : snapshot.settings.locationEnabled,
            locationPermissionState:
                snapshot.settings.permissions[.location]?.rawValue,
            activitySuggestion: hidesSensitiveContent
                ? nil
                : pendingWatchActivitySuggestion.flatMap {
                    now.timeIntervalSince($0.endedAt) <= 2 * 3_600 ? $0 : nil
                },
            commandCapabilities: commandCapabilities,
            commerceLocked: isCommerceLocked,
            languagePreference: AppLanguagePreference.current.watchPayloadValue
        )
        var identity = watchPayload
        identity.generatedAt = .distantPast
        // The live viewport starts at "now" for rendering. It is not payload
        // content, otherwise every sensor callback would queue another Watch
        // transfer even when the execution queue is unchanged.
        identity.viewportStart = dayStart
        if lastWatchPayloadIdentity == identity {
            watchPayloadSkipCount += 1
            let uptime = ProcessInfo.processInfo.systemUptime
            if uptime - lastWatchSkipLogUptime >= 5 {
                lastWatchSkipLogUptime = uptime
                TaptionPlanDiagnosticsLogger.shared.record(
                    "watch_payload_skipped",
                    fields: [
                        "reason": "unchanged",
                        "count": String(watchPayloadSkipCount),
                    ]
                )
            }
            return
        }
        do {
            try watchConnectivityService.update(payload: watchPayload)
            lastWatchPayloadIdentity = identity
            TaptionPlanDiagnosticsLogger.shared.record(
                "watch_settings_queued",
                fields: [
                    "acceleration": snapshot.settings
                        .watchAccelerationProfile.displayName,
                    "data_sync": snapshot.settings
                        .watchDataSyncProfile.displayName,
                    "location": String(snapshot.settings.locationEnabled),
                ]
            )
        } catch {
            TaptionPlanDiagnosticsLogger.shared.record(
                "watch_settings_publish_failed",
                level: .error,
                fields: ["error": String(describing: type(of: error))]
            )
        }
    }

    /// 워치로 보낼 지금 대분류. 두 언어를 함께 보내 워치가 자기 언어 설정으로 고른다.
    private func watchCurrentActivity(now: Date) -> TaptionWatchCurrentActivity? {
        let projection = currentLiveActivityProjection(at: now)
        guard projection.categoryID != "unconfirmed" else { return nil }
        // 장소 → 대분류 → 상세 순서. 등록 지점 안에서 걸으면 그 곳의 대분류다.
        let placeCategory = watchPlaceCategoryForWalking(title: projection.title, categoryID: projection.categoryID, at: now)
        let categoryID = placeCategory ?? projection.categoryID
        let action = TaptionLiveActivityStickmanAction.resolve(
            categoryID: categoryID,
            title: placeCategory == nil ? projection.title : ""
        )
        let poseName = placeCategory == "work"
            ? TaptionHwarangPose.laptopWalk.rawValue
            : TaptionHwarangPose.resolve(categoryID: categoryID, title: projection.title)?.rawValue
        return TaptionWatchCurrentActivity(
            categoryID: categoryID,
            koreanTitle: action.koreanTitle,
            englishTitle: action.englishTitle,
            startedAt: projection.startedAt,
            poseName: poseName
        )
    }

    private func watchPlaceCategoryForWalking(title: String, categoryID: String, at date: Date) -> String? {
        let probe = MapHomeTimeRailSegment(startMinute: 0, endMinute: 1, categoryID: categoryID, title: title)
        guard MapHomePlaceFirstPolicy.isWalking(probe) else { return nil }
        let kinds = settings.frequentPlaces.reduce(into: [String: FrequentPlaceKind]()) { $0[$1.stablePlaceKey] = $1.kind }
        return snapshot.places
            .first { $0.span.start <= date && date <= $0.span.end }
            .flatMap { kinds[$0.placeKey] }
            .flatMap(MapHomePlaceFirstPolicy.categoryID(for:))
    }

    /// payload가 바뀌었을 때만 불린다. 잇따른 변경을 0.3초 묶어 모든 위젯을 한 번만 다시 읽힌다
    /// (예전: 바로 schedule+전체, 0.7초 뒤 또 schedule+전체로 4번, PRF1101A01).
    private func requestImmediateWidgetRefresh() {
        widgetReloadFollowupTask?.cancel()
        widgetReloadFollowupTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            WidgetCenter.shared.reloadAllTimelines()
            Self.integrationLogger.notice("Widget timeline reload requested")
        }
    }
}
