import Foundation
import TaptionPlanCore

extension AppModel {
    @discardableResult
    func archiveRawDeviceData<T: Encodable>(
        source: RawDeviceDataSource,
        kind: String,
        payload: T,
        capturedAt: Date = .now
    ) async -> Bool {
        guard let rawDeviceDataArchive else { return false }
        do {
            let envelope = try RawDeviceDataEnvelope(
                capturedAt: capturedAt,
                source: source,
                kind: kind,
                payload: payload
            )
            try await rawDeviceDataArchive.append(envelope)
            return true
        } catch {
            Self.integrationLogger.error(
                "Raw device data archive failed: \(kind, privacy: .public) \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    private func archiveWeatherRawContexts(
        _ contexts: [WeatherContext],
        kind: String
    ) async {
        guard let rawDeviceDataArchive else { return }
        let changes = WeatherTimelineEngine.changedRawContexts(
            contexts,
            relativeTo: snapshot.weather
        )
        guard !changes.isEmpty else { return }
        do {
            let envelopes = try changes.map { context in
                try RawDeviceDataEnvelope(
                    capturedAt: context.observedAt,
                    source: .gps,
                    kind: kind,
                    payload: context
                )
            }
            try await rawDeviceDataArchive.append(envelopes)
        } catch {
            Self.integrationLogger.error(
                "Weather raw archive failed: \(kind, privacy: .public) \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func restoreRawWeather(in span: TimeSpan) async {
        guard let rawDeviceDataArchive,
              let envelopes = try? await rawDeviceDataArchive.envelopes(
                  in: span
              ) else {
            return
        }
        guard !Task.isCancelled, acceptsDataMutation() else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let contexts = envelopes
            .filter {
                $0.source == .gps
                    && ($0.kind == "weather-context"
                        || $0.kind == "weather-forecast-hourly")
            }
            .compactMap { envelope -> WeatherContext? in
                guard let data = envelope.payloadJSON.data(using: .utf8) else {
                    return nil
                }
                if let byteCount = envelope.payloadByteCount,
                   byteCount != data.count {
                    return nil
                }
                if let checksum = envelope.payloadChecksum,
                   checksum != TaptionPlanCanonicalStorage.checksum(data) {
                    return nil
                }
                return try? decoder.decode(WeatherContext.self, from: data)
            }
        guard !contexts.isEmpty else { return }
        snapshot.weather = WeatherTimelineEngine.coalesced(
            snapshot.weather + contexts
        )
        TaptionPlanDiagnosticsLogger.shared.record(
            "weather_raw_restored",
            fields: [
                "envelopes": String(envelopes.count),
                "contexts": String(contexts.count),
                "from": String(span.start.timeIntervalSince1970),
                "through": String(span.end.timeIntervalSince1970),
            ]
        )
    }

    private func weatherPreviewRange(from date: Date) -> TimeSpan {
        let start = WeatherTimelineEngine.hourBucket(for: date)
        let calendar = Calendar.autoupdatingCurrent
        let end = calendar.date(
            byAdding: .day,
            value: Self.weatherPreviewMaximumDays,
            to: start
        ) ?? start.addingTimeInterval(
            TimeInterval(Self.weatherPreviewMaximumDays) * 24 * 60 * 60
        )
        return TimeSpan(start: start, end: end)
    }

    /// 자정이 지나면 전날 날씨를 그날의 GPS 위치 기준으로 고정해 저장한다(WTH1020C01). 새 위치 점이 들어올 때와 앞으로 올 때
    /// 확인하고(iOS가 앱 실행을 허용한 때에만 동작), 아직 고정하지 않은 지난 날(최대 3일)을 오래된 날부터 처리한다.
    /// 실패하면 30분 뒤에 다시 시도하고, 받은 시간이 하나도 없는 날은 고정한 것으로 치지 않는다.
    func scheduleWeatherDayFixIfNeeded(now: Date = .now) {
        guard weatherFixTask == nil,
              settings.locationEnabled || settings.weatherEnabled,
              lastWeatherFixAttemptAt.map({ now.timeIntervalSince($0) >= Self.weatherFixRetryInterval }) ?? true
        else { return }
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: now)
        let fixedThrough = UserDefaults.standard.object(forKey: Self.weatherFixedThroughDayKey) as? Double
        let earliest = calendar.date(byAdding: .day, value: -Self.weatherFixBackfillDays, to: today) ?? today
        let first = max(earliest, fixedThrough.map {
            calendar.date(byAdding: .day, value: 1, to: Date(timeIntervalSince1970: $0)) ?? today
        } ?? earliest)
        guard first < today else { return }
        lastWeatherFixAttemptAt = now
        weatherFixTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.weatherFixTask = nil }
            var day = first
            while day < today, !Task.isCancelled {
                guard await self.fixPastDayWeather(day, now: now) else { break }
                UserDefaults.standard.set(day.timeIntervalSince1970, forKey: Self.weatherFixedThroughDayKey)
                day = calendar.date(byAdding: .day, value: 1, to: day) ?? today
            }
        }
    }

    /// 한 날을 고정한다. 하나 이상의 시간을 받아 저장하면 true.
    private func fixPastDayWeather(_ dayStart: Date, now: Date) async -> Bool {
        let calendar = Calendar.autoupdatingCurrent
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return false }
        let readings = await sensorReadings(in: TimeSpan(start: dayStart, end: dayEnd))
        let home = settings.frequentPlaces.first { $0.kind == .home }?.point
        let hours = WeatherDayFixEngine.hourLocations(
            dayStart: dayStart, dayEnd: dayEnd, readings: readings, home: home, calendar: calendar
        )
        guard !hours.isEmpty else { return false }
        var fixed: [WeatherContext] = []
        for group in WeatherDayFixEngine.groups(hours) {
            do {
                let contexts = try await weatherService.historicalHourlyContexts(
                    latitude: group.point.latitude,
                    longitude: group.point.longitude,
                    from: group.start,
                    through: group.end
                )
                for var context in contexts {
                    context.isForecast = false
                    context.point = group.point
                    context.placeName = "GPS"
                    fixed.append(context)
                }
            } catch is CancellationError {
                return false
            } catch {
                recordWeatherFailure(WeatherFailureKind.kind(for: error), at: now)
                if (error as? WeatherContextServiceError) == .authenticationFailed { break }
            }
        }
        guard !fixed.isEmpty, acceptsDataMutation() else { return false }
        await archiveWeatherRawContexts(fixed, kind: "weather-fixed-hourly")
        snapshot.weather = WeatherDayFixEngine.replacing(snapshot.weather, withFixed: fixed, calendar: calendar)
        TaptionPlanDiagnosticsLogger.shared.record(
            "weather_day_fixed",
            fields: [
                "day": String(dayStart.timeIntervalSince1970),
                "hours": String(fixed.count),
                "locations": String(WeatherDayFixEngine.groups(hours).count),
            ]
        )
        _ = await persistDeviceLocalSnapshot()
        return true
    }

    func refreshFutureWeatherPreviewIfNeeded() async {
        guard isSceneActive,
              settings.locationEnabled || settings.weatherEnabled,
              liveWeatherRefreshTask == nil else {
            return
        }
        let point = latestSensorReading?.point
            ?? snapshot.weather
                .max { $0.observedAt < $1.observedAt }?.point
        guard let point else { return }

        await refreshFutureWeatherIfNeeded(at: point)
    }

    private func refreshFutureWeatherIfNeeded(
        at point: GeoPoint,
        now: Date = .now
    ) async {
        guard isSceneActive,
              settings.locationEnabled || settings.weatherEnabled,
              liveWeatherRefreshTask == nil else {
            return
        }

        let movedToNewLocation = lastFutureWeatherPoint.map {
            distanceMeters($0, point) >= 1_000
        } ?? true
        let refreshDue = lastFutureWeatherRefreshAt.map {
            now.timeIntervalSince($0) >= Self.weatherPreviewRefreshInterval
        } ?? true
        guard movedToNewLocation || refreshDue else { return }

        let range = weatherPreviewRange(from: now)
        do {
            let fetched = try await weatherService.hourlyContexts(
                latitude: point.latitude,
                longitude: point.longitude,
                from: range.start,
                through: range.end
            )
            let futureStart = max(now, range.start)
            var contexts = fetched.filter {
                $0.observedAt >= futureStart && $0.observedAt < range.end
            }
            guard isSceneActive,
                  acceptsDataMutation(),
                  !Task.isCancelled else { return }
            guard !contexts.isEmpty else {
                TaptionPlanDiagnosticsLogger.shared.record(
                    "weather_preview_empty",
                    level: .notice,
                    fields: [
                        "from": String(range.start.timeIntervalSince1970),
                        "through": String(range.end.timeIntervalSince1970),
                    ]
                )
                return
            }
            lastFutureWeatherRefreshAt = now
            lastFutureWeatherPoint = point
            for index in contexts.indices {
                contexts[index].isForecast = true
                contexts[index].point = point
                contexts[index].placeName = "현재 위치"
            }
            await archiveWeatherRawContexts(
                contexts,
                kind: "weather-forecast-hourly"
            )
            snapshot.weather = WeatherTimelineEngine.replacing(
                snapshot.weather,
                forecast: contexts,
                forecastRange: range
            )
            TaptionPlanDiagnosticsLogger.shared.record(
                "weather_preview_refreshed",
                fields: [
                    "contexts": String(contexts.count),
                    "from": String(range.start.timeIntervalSince1970),
                    "through": String(range.end.timeIntervalSince1970),
                ]
            )
            await persistDeviceLocalSnapshot()
        } catch is CancellationError {
            return
        } catch {
            recordWeatherFailure(WeatherFailureKind.kind(for: error), at: now)
            TaptionPlanDiagnosticsLogger.shared.record(
                "weather_preview_failed",
                level: .error,
                fields: [
                    "error": String(describing: type(of: error)),
                    "from": String(range.start.timeIntervalSince1970),
                    "through": String(range.end.timeIntervalSince1970),
                ]
            )
        }
    }

    func refreshCurrentEnvironmentIfNeeded(
        point: GeoPoint,
        at date: Date
    ) {
        // Weather is part of the automatic sensor record. Location collection
        // enables it even when the legacy weather toggle is still off.
        guard isSceneActive,
              settings.locationEnabled || settings.weatherEnabled else {
            return
        }
        let movedFarEnough = lastLiveEnvironmentPoint.map {
            distanceMeters($0, point) >= 3_000
        } ?? true
        // Keep environment samples on the same cadence as the configured
        // GPS/sensor duty cycle.  The provider caches the value, so a one-
        // minute accuracy profile does not imply a one-minute network call.
        let collectionInterval = settings.sensorCollectionProfile.interval
        let agedEnough = lastLiveEnvironmentAt.map {
            date.timeIntervalSince($0) >= collectionInterval
        } ?? true
        let retryAllowed = lastLiveEnvironmentFailureAt.map {
            date.timeIntervalSince($0) >= 60
        } ?? true
        let now = Date.now
        let futureRefreshDue = lastFutureWeatherRefreshAt.map {
            now.timeIntervalSince($0) >= Self.weatherPreviewRefreshInterval
        } ?? true
        let futureMovedToNewLocation = lastFutureWeatherPoint.map {
            distanceMeters($0, point) >= 1_000
        } ?? true
        let shouldRefreshFutureWeather =
            futureMovedToNewLocation || futureRefreshDue
        guard movedFarEnough || agedEnough,
              retryAllowed,
              liveWeatherRefreshTask == nil else { return }
        liveWeatherRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer { self.liveWeatherRefreshTask = nil }
            do {
                var context = try await self.weatherService.context(
                    latitude: point.latitude,
                    longitude: point.longitude,
                    at: date
                )
                context.point = point
                context.placeName = "현재 위치"
                context.airQuality = try? await self.airQualityService.context(
                    latitude: point.latitude,
                    longitude: point.longitude,
                    at: date
                )
                guard !Task.isCancelled,
                      self.isSceneActive,
                      self.acceptsDataMutation() else { return }

                var futureContexts: [WeatherContext] = []
                var futureRange: TimeSpan?
                if shouldRefreshFutureWeather {
                    let range = self.weatherPreviewRange(from: now)
                    let futureStart = max(now, range.start)
                    do {
                        let fetched = try await self.weatherService
                            .hourlyContexts(
                                latitude: point.latitude,
                                longitude: point.longitude,
                                from: range.start,
                                through: range.end
                            )
                        futureContexts = fetched.filter {
                            $0.observedAt >= futureStart
                                && $0.observedAt < range.end
                            }
                        if !futureContexts.isEmpty {
                            futureRange = range
                            self.lastFutureWeatherRefreshAt = now
                            self.lastFutureWeatherPoint = point
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        self.recordWeatherFailure(
                            WeatherFailureKind.kind(for: error),
                            at: now
                        )
                        TaptionPlanDiagnosticsLogger.shared.record(
                            "weather_preview_failed",
                            level: .error,
                            fields: [
                                "error": String(describing: type(of: error)),
                                "from": String(range.start.timeIntervalSince1970),
                                "through": String(range.end.timeIntervalSince1970),
                            ]
                        )
                    }
                }

                guard !Task.isCancelled,
                      self.isSceneActive,
                      self.acceptsDataMutation() else { return }
                for index in futureContexts.indices {
                    futureContexts[index].isForecast = true
                    futureContexts[index].point = point
                    futureContexts[index].placeName = "현재 위치"
                }
                await self.archiveWeatherRawContexts(
                    [context],
                    kind: "weather-context"
                )
                await self.archiveWeatherRawContexts(
                    futureContexts,
                    kind: "weather-forecast-hourly"
                )
                guard !Task.isCancelled,
                      self.isSceneActive,
                      self.acceptsDataMutation() else { return }
                self.lastLiveEnvironmentPoint = point
                self.lastLiveEnvironmentAt = date
                self.lastLiveEnvironmentFailureAt = nil
                self.recordWeatherSuccess(context)
                self.snapshot.weather = WeatherTimelineEngine.replacing(
                    self.snapshot.weather,
                    current: context,
                    forecast: futureContexts,
                    forecastRange: futureRange
                )
                TaptionPlanDiagnosticsLogger.shared.record(
                    "live_environment_refreshed",
                    fields: [
                        "air_quality": String(context.airQuality != nil),
                        "forecast_contexts": String(futureContexts.count),
                    ]
                )
                await self.persistDeviceLocalSnapshot()
            } catch is CancellationError {
                return
            } catch {
                self.lastLiveEnvironmentFailureAt = date
                Self.integrationLogger.info(
                    "Live weather context unavailable: \(error.localizedDescription, privacy: .public)"
                )
                let failureKind = WeatherFailureKind.kind(for: error)
                self.recordWeatherFailure(failureKind, at: date)
                TaptionPlanDiagnosticsLogger.shared.record(
                    "live_environment_failed",
                    level: .error,
                    fields: [
                        "error": String(describing: type(of: error)),
                        "authentication": String(failureKind == .authentication),
                    ]
                )
            }
        }
    }

    func weatherNeedsRefresh(for reading: SensorReading?) -> Bool {
        guard let reading, let point = reading.point else { return false }
        let latest = snapshot.weather
            .filter { context in
                guard let contextPoint = context.point,
                      context.placeID == nil,
                      context.observedAt <= reading.timestamp else {
                    return false
                }
                return distanceMeters(contextPoint, point) < 1_000
            }
            .max { $0.observedAt < $1.observedAt }
        guard let latest else { return true }
        return reading.timestamp.timeIntervalSince(latest.observedAt)
            >= settings.sensorCollectionProfile.interval
    }

    func refreshWeather(
        in span: TimeSpan,
        fallbackReading: SensorReading? = nil
    ) async {
        let calendar = Calendar.autoupdatingCurrent
        guard calendar.isDate(span.start, inSameDayAs: .now) else {
            TaptionPlanDiagnosticsLogger.shared.record(
                "weather_historical_restored",
                fields: [
                    "from": String(span.start.timeIntervalSince1970),
                    "through": String(span.end.timeIntervalSince1970),
                ]
            )
            return
        }
        // 확정한 날의 날씨는 저장된 값을 그대로 쓴다(지나간 날을 다시 조회하지 않는다).
        guard allowsRecalculation(of: span.start) else {
            TaptionPlanDiagnosticsLogger.shared.record(
                "weather_refresh_skipped_sealed",
                fields: ["day": String(Int(calendar.startOfDay(for: span.start).timeIntervalSince1970))]
            )
            return
        }
        let latestStoredPoint = snapshot.weather
            .filter { $0.point != nil && $0.isForecast != true }
            .max(by: { $0.observedAt < $1.observedAt })?.point
        guard let point = fallbackReading?.point
            ?? latestSensorReading?.point
            ?? latestStoredPoint else {
            return
        }
        await refreshWeather(at: point, observedAt: .now)
    }

    func refreshWeather(
        at point: GeoPoint,
        observedAt: Date,
        placeID: UUID? = nil,
        placeName: String? = "현재 위치"
    ) async {
        do {
            var context = try await weatherService.context(
                latitude: point.latitude,
                longitude: point.longitude,
                at: observedAt
            )
            context.observedAt = observedAt
            context.placeID = placeID
            context.placeName = placeName
            context.point = point
            context.airQuality = try? await airQualityService.context(
                latitude: point.latitude,
                longitude: point.longitude,
                at: observedAt
            )
            guard !Task.isCancelled, acceptsDataMutation() else { return }
            await archiveWeatherRawContexts(
                [context],
                kind: "weather-context"
            )
            guard !Task.isCancelled, acceptsDataMutation() else { return }
            snapshot.weather = WeatherTimelineEngine.replacing(
                snapshot.weather,
                current: context
            )
            recordWeatherSuccess(context)
            TaptionPlanDiagnosticsLogger.shared.record(
                "stored_environment_fallback_refreshed",
                fields: [
                    "air_quality": String(context.airQuality != nil),
                ]
            )
            await persistDeviceLocalSnapshot()
            if placeID == nil {
                await refreshFutureWeatherIfNeeded(at: point)
            }
        } catch {
            Self.integrationLogger.info(
                "Stored weather fallback unavailable: \(error.localizedDescription, privacy: .public)"
            )
            let failureKind = WeatherFailureKind.kind(for: error)
            recordWeatherFailure(failureKind, at: .now)
            TaptionPlanDiagnosticsLogger.shared.record(
                "stored_environment_fallback_failed",
                level: .error,
                fields: [
                    "error": String(describing: type(of: error)),
                    "authentication": String(failureKind == .authentication),
                ]
            )
        }
    }

    private func recordWeatherSuccess(_ context: WeatherContext) {
        // 오래된 값(실패 뒤 캐시)은 성공으로 세지 않는다.
        guard context.isStale != true else { return }
        var next = weatherStatus
        guard next.recordSuccess(at: .now) else { return }
        weatherStatus = next
    }

    private func recordWeatherFailure(_ kind: WeatherFailureKind, at date: Date) {
        var next = weatherStatus
        guard next.recordFailure(kind, at: date) else { return }
        weatherStatus = next
    }

    private func coalesceWeatherSnapshot() {
        snapshot.weather = WeatherTimelineEngine.coalesced(snapshot.weather)
    }
}
