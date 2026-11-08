import Foundation
import TaptionPlanCore

extension AppModel {
    /// 자동 기록의 원본은 보존하고, 시간표와 상세 화면에 표시할 활동만
    /// 사용자가 교정한다. 교정표는 기록 ID로 저장되어 다음 센서 갱신에도
    /// 같은 결과를 복원한다.
    func updateActualActivity(
        _ actualID: UUID,
        with option: ActivityCorrectionOption
    ) async {
        guard let actual = snapshot.actuals.first(where: {
            $0.id == actualID
        }) else {
            return
        }
        let previous = snapshot
        let previousSpan = actual.endedAt.map {
            TimeSpan(start: actual.startedAt, end: $0)
        }
        let wasConfirmedSleep = actual.modelVersion
            == TaptionActivityEngineAdapter.confirmedSleepModelVersion
        snapshot.settings.activityCorrections[actualID] =
            ActivityCorrectionEngine.replacingActivity(
                in: snapshot.settings.activityCorrections[actualID],
                with: option
            )
        if option.isCustom {
            snapshot.settings.customActivityLabels =
                AppFeatureSettings.normalizedActivityLabels(
                    snapshot.settings.customActivityLabels + [option.title]
                )
        }
        snapshot.actuals = ActivityCorrectionEngine.applying(
            snapshot.settings.activityCorrections,
            to: snapshot.actuals
        )
        if wasConfirmedSleep, let previousSpan {
            replaceConfirmedSleepSpans(removing: [previousSpan])
        }
        if option.categoryID == "sleep", let previousSpan {
            replaceConfirmedSleepSpans(adding: [previousSpan])
        }
        snapshot.actuals.sort { $0.startedAt < $1.startedAt }
        await saveUserEdit(from: previous)
        TaptionPlanDiagnosticsLogger.shared.record(
            "activity_correction_applied",
            fields: [
                "record_id": actualID.uuidString,
                "scope": "record",
                "source": String(describing: actual.source),
            ]
        )
    }

    /// 자동 기록의 센서 원본은 그대로 두고, 화면에 표시할 시간만 조정한다.
    func updateActualSpan(
        _ actualID: UUID,
        startAt: Date,
        endAt: Date
    ) async {
        guard endAt > startAt,
              let actual = snapshot.actuals.first(where: { $0.id == actualID })
        else { return }
        let previous = snapshot
        let previousSpan = actual.endedAt.map {
            TimeSpan(start: actual.startedAt, end: $0)
        }
        let wasConfirmedSleep = actual.modelVersion
            == TaptionActivityEngineAdapter.confirmedSleepModelVersion

        var correction = snapshot.settings.activityCorrections[actualID]
            ?? ActivityCorrection(
                title: actual.title,
                behavior: actual.behavior,
                categoryID: actual.categoryID
            )
        correction.startedAt = startAt
        correction.endedAt = endAt
        snapshot.settings.activityCorrections[actualID] = correction
        snapshot.actuals = ActivityCorrectionEngine.applying(
            snapshot.settings.activityCorrections,
            to: snapshot.actuals
        )
        if wasConfirmedSleep, let previousSpan {
            replaceConfirmedSleepSpans(removing: [previousSpan])
        }
        if correction.categoryID == "sleep" {
            replaceConfirmedSleepSpans(
                adding: [TimeSpan(start: startAt, end: endAt)]
            )
        }
        snapshot.actuals.sort { $0.startedAt < $1.startedAt }
        await saveUserEdit(from: previous)
        TaptionPlanDiagnosticsLogger.shared.record(
            "activity_span_correction_applied",
            fields: [
                "record_id": actualID.uuidString,
                "scope": "record",
                "source": String(describing: actual.source),
                "start": String(startAt.timeIntervalSince1970),
                "end": String(endAt.timeIntervalSince1970),
            ]
        )
    }

    /// 겹침 제거로 갈라진 표시 조각만 교정한다. 조각이 원본 전체와 같으면
    /// 기존 교정표를 쓰고, 일부면 자동 원본 위에 별도의 수동 기록을 얹는다.
    func correctActualFragment(
        _ actualID: UUID,
        displayedSpan: TimeSpan,
        startAt: Date,
        endAt: Date,
        with option: ActivityCorrectionOption?
    ) async {
        guard acceptsDataMutation() else { return }
        guard endAt > startAt,
              displayedSpan.duration > 0,
              let actual = snapshot.actuals.first(where: {
                  $0.id == actualID
              }) else {
            return
        }
        let previous = snapshot
        let wasConfirmedSleep = actual.modelVersion
            == TaptionActivityEngineAdapter.confirmedSleepModelVersion

        if !ActivityFragmentCorrectionEngine.needsSeparateRecord(
            source: actual,
            displayedSpan: displayedSpan
        ) {
            var correction = snapshot.settings.activityCorrections[actualID]
                ?? ActivityCorrection(
                    title: actual.title,
                    behavior: actual.behavior,
                    categoryID: actual.categoryID
                )
            if let option {
                correction = ActivityCorrectionEngine.replacingActivity(
                    in: correction,
                    with: option
                )
            }
            correction.startedAt = startAt
            correction.endedAt = endAt
            snapshot.settings.activityCorrections[actualID] = correction
        } else {
            let fragmentID = ActivityFragmentCorrectionEngine.stableID(
                sourceID: actualID,
                span: displayedSpan
            )
            let createdAt = snapshot.actuals.first(where: {
                $0.id == fragmentID
            })?.createdAt ?? .now
            let fragment = ActivityFragmentCorrectionEngine.record(
                source: actual,
                displayedSpan: displayedSpan,
                correctedSpan: TimeSpan(start: startAt, end: endAt),
                option: option,
                createdAt: createdAt
            )
            if let index = snapshot.actuals.firstIndex(where: {
                $0.id == fragment.id
            }) {
                snapshot.actuals[index] = fragment
            } else {
                snapshot.actuals.append(fragment)
            }
        }

        if let option, option.isCustom {
            snapshot.settings.customActivityLabels =
                AppFeatureSettings.normalizedActivityLabels(
                    snapshot.settings.customActivityLabels + [option.title]
                )
        }
        snapshot.actuals = ActivityCorrectionEngine.applying(
            snapshot.settings.activityCorrections,
            to: snapshot.actuals
        )
        if wasConfirmedSleep {
            replaceConfirmedSleepSpans(removing: [displayedSpan])
            if option == nil || option?.categoryID == "sleep" {
                replaceConfirmedSleepSpans(
                    adding: [TimeSpan(start: startAt, end: endAt)]
                )
            }
        } else if option?.categoryID == "sleep" {
            storeConfirmedSleepSpan(TimeSpan(start: startAt, end: endAt))
        }
        snapshot.actuals.sort { $0.startedAt < $1.startedAt }
        await saveUserEdit(from: previous)
        TaptionPlanDiagnosticsLogger.shared.record(
            "activity_correction_applied",
            fields: [
                "record_id": actualID.uuidString,
                "scope": ActivityFragmentCorrectionEngine.needsSeparateRecord(
                    source: actual,
                    displayedSpan: displayedSpan
                ) ? "fragment" : "record",
                "source": String(describing: actual.source),
                "display_start": String(
                    displayedSpan.start.timeIntervalSince1970
                ),
                "display_end": String(
                    displayedSpan.end.timeIntervalSince1970
                ),
                "start": String(startAt.timeIntervalSince1970),
                "end": String(endAt.timeIntervalSince1970),
            ]
        )
    }

    /// 화면에서만 채워졌던 미확인 구간을 사용자가 결정한 파생 기록으로 남긴다.
    /// 센서·HealthKit 원본은 수정하거나 삭제하지 않는다.
    func classifyUnconfirmedSpan(
        _ span: TimeSpan,
        with option: ActivityCorrectionOption
    ) async {
        guard acceptsDataMutation() else { return }
        guard span.duration > 0 else { return }
        let alreadySaved = snapshot.actuals.contains { actual in
            actual.source == .manual
                && actual.manuallyCorrected
                && actual.title == option.title
                && actual.categoryID == option.categoryID
                && actual.behavior == option.behavior
                && actual.startedAt == span.start
                && actual.endedAt == span.end
        }
        guard !alreadySaved else { return }
        let previous = snapshot
        if option.isCustom {
            snapshot.settings.customActivityLabels =
                AppFeatureSettings.normalizedActivityLabels(
                    snapshot.settings.customActivityLabels + [option.title]
                )
        }
        snapshot.actuals.append(
            ActualRecord(
                planID: nil,
                title: option.title,
                categoryID: option.categoryID,
                startedAt: span.start,
                endedAt: span.end,
                source: .manual,
                confidence: .high,
                behavior: option.behavior,
                evidence: ["사용자가 미확인 구간을 분류함"],
                modelVersion: "manual-gap-classification-v1",
                manuallyCorrected: true
            )
        )
        snapshot.actuals.sort { $0.startedAt < $1.startedAt }
        if option.categoryID == "sleep" {
            storeConfirmedSleepSpan(span)
        }
        await saveUserEdit(from: previous)
    }

    func saveActivitySectionEdit(
        _ request: ActivitySectionEditRequest
    ) async -> ActivitySectionEditSaveResult? {
        guard acceptsDataMutation() else { return nil }
        let records = ActivitySectionOverrideEngine.records(for: request)
        guard !records.isEmpty else { return nil }
        TaptionPlanDiagnosticsLogger.shared.record(
            "section_edit_save_started",
            fields: [
                "source_count": String(request.sourceIDs.count),
                "piece_count": String(records.count),
                "start": String(request.originalSpan.start.timeIntervalSince1970),
                "end": String(request.originalSpan.end.timeIntervalSince1970),
            ]
        )

        let previous = snapshot
        var staged = snapshot
        guard let stage = ActivitySectionEditStaging.stage(
            request, into: &staged, sleepRule: .primarySpan
        ) else { return nil }
        snapshot = staged
        let preservedPieces = stage.preservedPieces
        let editedSpan = stage.editedSpan

        let rollback = userEditRollback(from: previous)
        guard await persist() else {
            rollBackUnsavedEdit(rollback)
            TaptionPlanDiagnosticsLogger.shared.record(
                "section_edit_save_failed",
                level: .error,
                fields: ["stage": "persist"]
            )
            return nil
        }

        do {
            let storedIDs = try await repository.existingActualIDs(
                Set((records + preservedPieces).map(\.id)))
            let replacedByConfirmedSleep = records
                .filter { $0.categoryID == "sleep" }
            let expectedRecords = records.filter {
                !replacedByConfirmedSleep.contains($0)
            }
            guard (expectedRecords + preservedPieces).allSatisfy({ storedIDs.contains($0.id) }) else {
                userFacingError = AppLanguagePreference.text(
                    korean: "변경 내용을 저장소에서 다시 확인하지 못했습니다.",
                    english: "Changes could not be verified against storage again."
                )
                TaptionPlanDiagnosticsLogger.shared.record(
                    "section_edit_save_failed",
                    level: .error,
                    fields: ["stage": "readback"]
                )
                return nil
            }
        } catch is CancellationError {
            return nil
        } catch {
            userFacingError = AppLanguagePreference.text(
                korean: "변경 내용을 저장소에서 다시 확인하지 못했습니다.",
                english: "Changes could not be verified against storage again."
            )
            TaptionPlanDiagnosticsLogger.shared.record(
                "section_edit_save_failed",
                level: .error,
                fields: [
                    "stage": "readback",
                    "error": String(describing: type(of: error)),
                ]
            )
            return nil
        }

        let selectedSpan = editedSpan
        TaptionPlanDiagnosticsLogger.shared.record(
            "section_edit_save_completed",
            fields: [
                "record_count": String(records.count),
                "selected_start": String(selectedSpan.start.timeIntervalSince1970),
                "selected_end": String(selectedSpan.end.timeIntervalSince1970),
            ]
        )
        recordUserEdit(from: previous)
        return ActivitySectionEditSaveResult(
            recordIDs: records.map(\.id),
            selectedSpan: selectedSpan
        )
    }

    func applyStoredActivityCorrections() {
        let confirmedSleepSpans =
            TaptionActivityEngineAdapter.migratedConfirmedSleepSpans(
                existing: snapshot.settings.confirmedSleepSpans,
                corrections: snapshot.settings.activityCorrections,
                actuals: snapshot.actuals
            )
        if confirmedSleepSpans != snapshot.settings.confirmedSleepSpans {
            snapshot.settings.confirmedSleepSpans = confirmedSleepSpans
        }
        var corrected = ActivityCorrectionEngine.applying(
            snapshot.settings.activityCorrections,
            to: snapshot.actuals
        )
        corrected = TaptionActivityEngineAdapter.applyingConfirmedSleepSpans(
            snapshot.settings.confirmedSleepSpans,
            to: corrected
        )
        guard corrected != snapshot.actuals else { return }
        snapshot.actuals = corrected
    }

    private func storeConfirmedSleepSpan(_ span: TimeSpan) {
        guard span.duration > 0 else { return }
        replaceConfirmedSleepSpans(adding: [span])
    }

    private func replaceConfirmedSleepSpans(
        removing: [TimeSpan] = [],
        adding: [TimeSpan] = []
    ) {
        snapshot.settings.confirmedSleepSpans =
            ConfirmedSleepSpanEditor.replacing(
                snapshot.settings.confirmedSleepSpans,
                removing: removing,
                adding: adding
            )
        snapshot.actuals = TaptionActivityEngineAdapter.applyingConfirmedSleepSpans(
            snapshot.settings.confirmedSleepSpans,
            to: snapshot.actuals
        )
    }

    func deleteActual(_ actualID: UUID) async {
        guard acceptsDataMutation() else { return }
        guard let actual = snapshot.actuals.first(where: {
            $0.id == actualID
        }) else {
            userFacingError = AppLanguagePreference.text(
                korean: "삭제할 실제 기록을 찾지 못했습니다.",
                english: "Could not find the actual record to delete."
            )
            return
        }

        clearUserEditRedoHistory()
        let previous = snapshot
        invalidateReviewArchives(spans: [actual.span()])
        snapshot.settings.suppressedActualIDs.insert(actualID)
        snapshot.actuals.removeAll { $0.id == actualID }
        removeRecordLinks {
            $0.fromNodeID == "automatic.actual.\(actualID.uuidString)"
                || $0.toNodeID == "automatic.actual.\(actualID.uuidString)"
        }

        if actual.endedAt == nil,
           let planID = actual.planID,
           let planIndex = snapshot.plans.firstIndex(where: {
               $0.id == planID
           }),
           snapshot.plans[planIndex].status == .running {
            snapshot.plans[planIndex].status = .planned
            snapshot.plans[planIndex].updatedAt = .now
            let majorCategory = currentMajorCategory(for: snapshot.plans[planIndex])
            try? await liveActivityController.stop(
                plan: snapshot.plans[planIndex],
                catStyle: snapshot.settings.catStyle,
                majorCategoryID: majorCategory.id,
                majorCategoryTitle: majorCategory.title,
                majorCategorySystemImage: majorCategory.systemImage
            )
        }

        await persistOrRollBack(userEditRollback(from: previous))
    }
}
