import Foundation
import TaptionPlanCore

extension AppModel {
    /// 메모 입력의 유일한 입구. 계획도 기록도 고르지 않고 순간만 받는다.
    /// `memoIDs` 가 비어 있지 않으면 그 자리에 이미 있던 메모를 펼친다.
    func openMemoEntry(at instant: Date, memoIDs: [UUID] = []) {
        memoEntry = MemoEntry(occurredAt: instant, memoIDs: memoIDs)
        detail = .memo
    }

    func closeMemoEntry() {
        memoEntry = nil
        detail = nil
    }

    /// 메모가 놓일 순간을 옮긴다. 손가락으로만 움직이므로 키보드는 메모 글에만
    /// 쓰인다.
    func moveMemoEntry(to instant: Date) {
        guard memoEntry?.occurredAt != instant else { return }
        memoEntry?.occurredAt = instant
    }

    var memoEntryMemos: [ActionMemo] {
        guard let memoEntry, !memoEntry.memoIDs.isEmpty else { return [] }
        let ids = Set(memoEntry.memoIDs)
        return snapshot.memos
            .filter { ids.contains($0.id) }
            .sorted { $0.occurredAt < $1.occurredAt }
    }

    /// 시간표 메모 줄이 읽는 값. 항목에 붙은 메모도 결국 한 순간에 놓이므로
    /// 줄 하나가 그 기간의 메모를 전부 보여 준다.
    func timelineMemos(in span: TimeSpan) -> [ActionMemo] {
        snapshot.memos.filter {
            $0.occurredAt >= span.start && $0.occurredAt < span.end
        }
    }

    @discardableResult
    func addMemoAtEntryInstant(text: String, kind: MemoKind) -> UUID? {
        guard let entry = memoEntry,
              let id = addMemo(
                  text: text,
                  kind: kind,
                  categoryID: MemoTimelineEngine.categoryID,
                  on: entry.occurredAt
              ) else {
            return nil
        }
        memoEntry?.memoIDs.append(id)
        return id
    }

    func addAttachmentMemoAtEntryInstant(
        kind: MemoKind,
        attachmentKind: AttachmentKind,
        localIdentifier: String,
        text: String? = nil
    ) {
        guard acceptsDataMutation() else { return }
        guard let entry = memoEntry else { return }
        let fallbackText = attachmentKind == .photo ? "사진 메모" : "음성 메모"
        guard let memoText = validatedMemoText(text ?? fallbackText) else {
            return
        }
        let memo = ActionMemo(
            categoryID: MemoTimelineEngine.categoryID,
            occurredAt: entry.occurredAt,
            kind: kind,
            text: memoText,
            attachments: [
                MemoAttachment(
                    kind: attachmentKind,
                    localIdentifier: localIdentifier
                ),
            ]
        )
        snapshot.memos.append(memo)
        memoEntry?.memoIDs.append(memo.id)
        Task { await persist() }
    }

    /// 알람 판정용: 선택한 날짜(오늘)의 센서 측정. 읽지 못하면 빈 배열.
    func readingsForAlarmCheck(on day: Date) async -> [SensorReading] {
        guard let sensorService else { return [] }
        let start = Calendar.autoupdatingCurrent.startOfDay(for: day)
        let end = Calendar.autoupdatingCurrent.date(byAdding: .day, value: 1, to: start) ?? start
        return (try? await sensorService.archivedReadings(in: TimeSpan(start: start, end: end))) ?? []
    }

    /// 메모(지도·일반 편집 화면)에 음성 파일을 오디오 첨부로 붙인다.
    func attachAudio(toMemo memoID: UUID, localIdentifier: String) {
        guard acceptsDataMutation() else { return }
        guard let index = snapshot.memos.firstIndex(where: { $0.id == memoID }) else { return }
        snapshot.memos[index].attachments.append(
            MemoAttachment(kind: .audio, localIdentifier: localIdentifier)
        )
        Task { await persist() }
    }

    func memos(for planID: UUID?) -> [ActionMemo] {
        guard let planID else { return [] }
        return snapshot.memos
            .filter {
                $0.planID == planID
                    && ($0.targetID == nil
                        || $0.targetID == "plan.\(planID.uuidString)")
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func memos(forTargetID targetID: String?) -> [ActionMemo] {
        guard let targetID, !targetID.isEmpty else { return [] }
        return snapshot.memos
            .filter { $0.targetID == targetID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Notes left on a category row. They belong to the category and the day,
    /// not to a plan, so nothing has to be invented to store them.
    func memos(forCategoryID categoryID: String?, on date: Date) -> [ActionMemo] {
        guard let categoryID, !categoryID.isEmpty else { return [] }
        let calendar = Calendar.autoupdatingCurrent
        return snapshot.memos
            .filter {
                $0.planID == nil
                    && $0.targetID == nil
                    && $0.categoryID == categoryID
                    && calendar.isDate($0.occurredAt, inSameDayAs: date)
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func addMemo(
        text: String,
        kind: MemoKind,
        to planID: UUID
    ) {
        guard let cleanText = validatedMemoText(text),
              let plan = snapshot.plans.first(where: { $0.id == planID })
        else {
            return
        }
        snapshot.memos.append(
            ActionMemo(
                planID: planID,
                categoryID: plan.categoryID,
                occurredAt: plan.span.start,
                kind: kind,
                text: cleanText
            )
        )
        Task { await persist() }
    }

    @discardableResult
    func addMemo(
        text: String,
        kind: MemoKind,
        categoryID: String,
        on date: Date
    ) -> UUID? {
        guard acceptsDataMutation() else { return nil }
        guard let cleanText = validatedMemoText(text),
              !categoryID.isEmpty else { return nil }
        let memo = ActionMemo(
            categoryID: categoryID,
            occurredAt: date,
            kind: kind,
            text: cleanText
        )
        snapshot.memos.append(memo)
        Task { await persist() }
        return memo.id
    }

    @discardableResult
    func addMapMemo(
        text: String,
        kind: MemoKind,
        mapPoint: GeoPoint,
        planID: UUID? = nil,
        targetID: String? = nil,
        occurredAt: Date,
        shouldPersist: Bool = true
    ) -> UUID? {
        guard acceptsDataMutation() else { return nil }
        guard let cleanText = validatedMemoText(text),
              occurredAt.timeIntervalSince1970.isFinite,
              mapPoint.latitude.isFinite,
              mapPoint.longitude.isFinite,
              mapPoint.altitude.isFinite,
              mapPoint.horizontalAccuracy.isFinite,
              mapPoint.verticalAccuracy.isFinite,
              (-90...90).contains(mapPoint.latitude),
              (-180...180).contains(mapPoint.longitude) else {
            return nil
        }
        let requestedPlan = planID.flatMap { planID in
            snapshot.plans.first(where: { $0.id == planID })
        }
        let linkedPlan = requestedPlan.flatMap { plan in
            plan.span.start <= occurredAt && occurredAt < plan.span.end
                ? plan
                : nil
        } ?? MapMemoLinkEngine.plan(
            containing: occurredAt,
            in: snapshot.plans
        )
        let memo = ActionMemo(
            planID: linkedPlan?.id,
            targetID: targetID,
            categoryID: linkedPlan?.categoryID ?? MemoTimelineEngine.categoryID,
            occurredAt: occurredAt,
            mapPoint: mapPoint,
            kind: kind,
            text: cleanText
        )
        snapshot.memos.append(memo)
        if shouldPersist {
            invalidateReviewArchives(dates: [occurredAt])
            Task { await persist() }
        } else {
            pendingMapMemoIDs.insert(memo.id)
        }
        return memo.id
    }

    /// 통합 메모의 초안: 위치·시간 없이 먼저 만들고, 편집 화면에서 위치·시간을 더한 뒤 저장한다.
    /// 저장 전에는 임시(pending) 상태라 저장소에 쓰지 않는다. 시간은 기본적으로 지정하지 않음.
    func addMemoDraft(
        text: String,
        occurredAt: Date = .now,
        mapPoint: GeoPoint? = nil,
        isTimeless: Bool = true
    ) -> UUID? {
        guard acceptsDataMutation(), let cleanText = validatedMemoText(text) else { return nil }
        let memo = ActionMemo(
            planID: nil,
            categoryID: MemoTimelineEngine.categoryID,
            occurredAt: occurredAt,
            mapPoint: mapPoint,
            isTimeless: isTimeless,
            kind: .idea,
            text: cleanText
        )
        snapshot.memos.append(memo)
        pendingMapMemoIDs.insert(memo.id)
        return memo.id
    }

    /// 임시 메모 초안을 저장소에 쓰지 않고 바꾼다(위치를 고르러 편집 화면을 닫을 때 쓴다).
    /// 글자가 비어 있으면 이전 글자를 그대로 둔다.
    func updateMemoDraft(
        _ memoID: UUID,
        text: String?,
        occurredAt: Date?,
        isTimeless: Bool?,
        mapPoint: GeoPoint??
    ) {
        guard pendingMapMemoIDs.contains(memoID),
              let index = snapshot.memos.firstIndex(where: { $0.id == memoID }) else { return }
        if let text {
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty, clean.count <= 1_000 { snapshot.memos[index].text = clean }
        }
        if let occurredAt, occurredAt.timeIntervalSince1970.isFinite {
            snapshot.memos[index].occurredAt = occurredAt
        }
        if let isTimeless { snapshot.memos[index].isTimeless = isTimeless ? true : nil }
        if let mapPoint { snapshot.memos[index].mapPoint = mapPoint }
    }

    /// 초안의 아이콘을 저장소에 쓰지 않고 바꾼다(위치를 고르고 돌아와도 고른 아이콘이 남는다).
    func updateMemoDraftSticker(_ memoID: UUID, symbol: String?, colorHex: String?) {
        guard pendingMapMemoIDs.contains(memoID),
              let index = snapshot.memos.firstIndex(where: { $0.id == memoID }) else { return }
        snapshot.memos[index].stickerSymbol = symbol
        snapshot.memos[index].stickerColorHex = symbol == nil ? nil : colorHex
    }

    func isMemoDraft(_ memoID: UUID) -> Bool { pendingMapMemoIDs.contains(memoID) }

    func discardMapMemoDraft(_ memoID: UUID) {
        guard acceptsDataMutation() else { return }
        guard snapshot.memos.contains(where: { memo in
            memo.id == memoID && (memo.mapPoint != nil || pendingMapMemoIDs.contains(memoID))
        }) else {
            return
        }
        pendingMapMemoIDs.remove(memoID)
        snapshot.memos.removeAll { $0.id == memoID }
        memoEntry?.memoIDs.removeAll { $0 == memoID }
    }

    func deleteMemo(_ memoID: UUID) {
        guard let memo = snapshot.memos.first(where: { $0.id == memoID }) else {
            return
        }
        if pendingMapMemoIDs.remove(memoID) != nil {
            snapshot.memos.removeAll { $0.id == memoID }
            memoEntry?.memoIDs.removeAll { $0 == memoID }
            return
        }
        invalidateReviewArchives(dates: [memo.occurredAt])
        snapshot.settings.cloudDeletedRecordKeys.insert(
            CloudBackupRecordKey.memo(memoID)
        )
        snapshot.memos.removeAll { $0.id == memoID }
        memoEntry?.memoIDs.removeAll { $0 == memoID }
        Task { await persist() }
    }

    func updateMemo(
        _ memoID: UUID,
        text: String,
        kind: MemoKind
    ) {
        guard let cleanText = validatedMemoText(text),
              let index = snapshot.memos.firstIndex(where: {
            $0.id == memoID
        }), let updated = ActionMemoEditingEngine.updating(
            snapshot.memos[index],
            text: cleanText,
            kind: kind
        ) else {
            return
        }
        snapshot.memos[index] = updated
        Task { await persist() }
    }

    @discardableResult
    func updateMapMemo(
        _ memoID: UUID,
        text: String,
        kind: MemoKind,
        mapPoint: GeoPoint?,
        occurredAt: Date,
        isTimeless: Bool = false
    ) -> Bool {
        guard acceptsDataMutation() else { return false }
        guard let cleanText = validatedMemoText(text),
              occurredAt.timeIntervalSince1970.isFinite,
              mapPoint.map({ point in
                  point.latitude.isFinite
                      && point.longitude.isFinite
                      && point.altitude.isFinite
                      && point.horizontalAccuracy.isFinite
                      && point.verticalAccuracy.isFinite
                      && (-90...90).contains(point.latitude)
                      && (-180...180).contains(point.longitude)
              }) ?? true,
              let index = snapshot.memos.firstIndex(where: { $0.id == memoID }),
              let updated = ActionMemoEditingEngine.updating(
                  snapshot.memos[index],
                  text: cleanText,
                  kind: kind
              ) else {
            return false
        }
        let previousDate = snapshot.memos[index].occurredAt
        let existingMemo = snapshot.memos[index]
        var value = updated
        let linkedPlan = MapMemoLinkEngine.plan(
            containing: occurredAt,
            in: snapshot.plans
        )
        value.planID = isTimeless ? nil : linkedPlan?.id
        value.categoryID = isTimeless ? (existingMemo.categoryID ?? MemoTimelineEngine.categoryID) : (linkedPlan?.categoryID
            ?? (existingMemo.planID == nil
                ? (existingMemo.categoryID ?? MemoTimelineEngine.categoryID)
                : MemoTimelineEngine.categoryID))
        value.mapPoint = mapPoint
        value.isTimeless = isTimeless ? true : nil
        value.occurredAt = occurredAt
        snapshot.memos[index] = value
        pendingMapMemoIDs.remove(memoID)
        invalidateReviewArchives(dates: [previousDate, occurredAt])
        Task { await persist() }
        return true
    }

    /// 메모의 스티커 정보를 바꾼다. symbol이 nil이면 일반 메모가 된다.
    @discardableResult
    func setMemoSticker(_ memoID: UUID, symbol: String?, colorHex: String?) -> Bool {
        guard acceptsDataMutation(),
              let index = snapshot.memos.firstIndex(where: { $0.id == memoID }) else { return false }
        snapshot.memos[index].stickerSymbol = symbol
        snapshot.memos[index].stickerColorHex = symbol == nil ? nil : colorHex
        snapshot.memos[index].updatedAt = .now
        Task { await persist() }
        return true
    }

    private func validatedMemoText(_ text: String) -> String? {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return nil }
        do {
            try TaptionPlanMemoRecord.validate(text: cleanText)
            return cleanText
        } catch {
            userFacingError = AppLanguagePreference.text(
                korean: "메모는 1,000자까지 저장할 수 있습니다.",
                english: "Memos can contain up to 1,000 characters."
            )
            return nil
        }
    }

    /// 음성 메모도 붙일 항목을 찾지 않는다. 메모 입력이 열려 있으면 그 순간에
    /// 놓인다.
    func toggleVoiceMemo(kind: MemoKind) async {
        guard memoEntry != nil else { return }

        if isRecordingVoiceMemo {
            guard let url = voiceMemoRecorder.stop() else {
                isRecordingVoiceMemo = false
                return
            }
            isRecordingVoiceMemo = false
            addAttachmentMemoAtEntryInstant(
                kind: kind,
                attachmentKind: .audio,
                localIdentifier: url.path
            )
            return
        }

        voiceMemoPlayer.stop()
        playingVoiceAttachmentID = nil
        let granted = await voiceMemoRecorder.requestPermission()
        snapshot.settings.permissions[.microphone] =
            granted ? .authorized : .denied
        guard granted else {
            userFacingError = AppLanguagePreference.text(
                korean: "음성 메모를 사용하려면 마이크 권한이 필요합니다.",
                english: "Microphone access is required to use voice memos."
            )
            await persist()
            return
        }

        do {
            let root = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            _ = try voiceMemoRecorder.start(
                in: root.appendingPathComponent(
                    "TaptionPlan/VoiceMemos",
                    isDirectory: true
                )
            )
            isRecordingVoiceMemo = true
            await persist()
        } catch {
            isRecordingVoiceMemo = false
            let reason = (error as? VoiceMemoRecordingError)?.localizedDescription
                ?? AppLanguagePreference.text(
                    korean: "마이크 입력 장치를 확인해 주세요.",
                    english: "Check your microphone input device."
                )
            userFacingError = AppLanguagePreference.text(
                korean: "음성 녹음을 시작하지 못했습니다. \(reason)",
                english: "Could not start voice recording. \(reason)"
            )
        }
    }

    func toggleVoicePlayback(_ attachment: MemoAttachment) {
        guard attachment.kind == .audio else { return }
        if playingVoiceAttachmentID == attachment.id {
            voiceMemoPlayer.stop()
            playingVoiceAttachmentID = nil
            return
        }
        do {
            try voiceMemoPlayer.play(
                filePath: attachment.localIdentifier
            )
            playingVoiceAttachmentID = attachment.id
        } catch {
            playingVoiceAttachmentID = nil
            userFacingError = AppLanguagePreference.text(
                korean: "음성 메모를 재생하지 못했습니다. \(error.localizedDescription)",
                english: "Could not play the voice memo. \(error.localizedDescription)"
            )
        }
    }
}
