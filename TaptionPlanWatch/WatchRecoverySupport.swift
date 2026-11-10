import Foundation
import HealthKit

/// 워치 리뷰(WCH1110A01)에서 더한 도우미. 큰 파일(`WatchWorkoutManager`·`WatchConnectivityController`)을
/// 키우지 않으려고 상태가 없는 부분만 여기에 둔다.

/// 실패한 운동 세션의 기록을 끝내 건강 앱에 남긴다. 예전에는 저장도 폐기도 하지 않아 기록이 사라졌다.
enum WatchWorkoutSalvage {
    enum Outcome {
        case saved(HKWorkout?)
        /// 수집을 끝내지 못해 폐기했다.
        case discarded
        /// 저장 도중 실패했다. 저장됐을 수도 있다.
        case failedWhileFinishing
    }

    @MainActor
    static func finish(_ builder: HKLiveWorkoutBuilder, at end: Date, onFinishing: () -> Void) async -> Outcome {
        do {
            try await builder.endCollection(at: end)
        } catch {
            builder.discardWorkout()
            return .discarded
        }
        onFinishing()
        do {
            return .saved(try await builder.finishWorkout())
        } catch {
            return .failedWhileFinishing
        }
    }
}

/// 파일 끝부분만 읽는다. 한 달 치 가속도 파일 전체를 읽으면 백그라운드 예산과 메모리를 넘긴다.
enum WatchFileTail {
    /// 읽은 줄들(잘린 첫 줄은 뺀다)과 파일이 줄바꿈으로 끝나는지.
    static func read(_ url: URL, maxBytes: UInt64 = 2 * 1_024 * 1_024) throws -> (lines: Data, endsWithNewline: Bool) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let offset = size > maxBytes ? size - maxBytes : 0
        try handle.seek(toOffset: offset)
        var data = try handle.readToEnd() ?? Data()
        let endsWithNewline = data.isEmpty || data.last == 0x0A
        if offset > 0, let firstBreak = data.firstIndex(of: 0x0A) {
            data = data[data.index(after: firstBreak)...]
        }
        return (data, endsWithNewline)
    }
}

/// 보내지 못한 큰 대기열을 UserDefaults가 아닌 파일에 둔다. 예전 UserDefaults 값은 처음 읽을 때 옮긴다.
enum WatchPendingFile {
    static func url(_ name: String) -> URL {
        let root = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL.temporaryDirectory
        return root.appendingPathComponent("TaptionPlan", isDirectory: true).appendingPathComponent(name)
    }

    static func read(_ name: String, legacyKey: String) -> Data? {
        if let data = try? Data(contentsOf: url(name)) { return data }
        guard let legacy = TaptionWatchDeviceLocalDefaults.data(forKey: legacyKey) else { return nil }
        if write(legacy, to: name) { TaptionWatchDeviceLocalDefaults.removeObject(forKey: legacyKey) }
        return legacy
    }

    @discardableResult
    static func write(_ data: Data, to name: String) -> Bool {
        let file = url(name)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            WatchLaunchDiagnostics.mark("pending file write failed name=\(name)")
            return false
        }
    }

    static func remove(_ name: String, legacyKey: String) {
        try? FileManager.default.removeItem(at: url(name))
        TaptionWatchDeviceLocalDefaults.removeObject(forKey: legacyKey)
    }
}

extension WatchWorkoutManager {
    /// 실패한 세션의 운동을 끝내 저장한다. 저장하지 못하면 builder를 폐기한다.
    func salvageWorkoutAfterFailure() async {
        guard let builder else { return }
        switch await WatchWorkoutSalvage.finish(builder, at: .now, onFinishing: { workoutFinishState = .finishing }) {
        case .saved(let finished):
            workoutFinishState = .successfulFinish(sampleAvailable: finished != nil)
            workoutAwaitingPurgeDeletion = finished
            workoutAwaitingPurgeDeletionID = finished == nil ? nil : workoutPurgeIdentifier
        case .failedWhileFinishing:
            workoutFinishState = .failedMayHavePersisted
            if let workoutPurgeIdentifier { TaptionWatchWorkoutPurgeIntentStore.enqueue(workoutPurgeIdentifier) }
        case .discarded:
            break
        }
    }
}
