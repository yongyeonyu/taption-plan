import Foundation

/// 클립 편집의 「적용」 단추 상태. 그날 기록과 전체 기록을 다 읽기 전에는 저장하지 않는다.
/// 반쯤 읽은 상태로 저장하면 아직 안 읽은 기록을 지울 수 있다(NLE1103A04).
struct NLEClipSaveGate: Equatable {
    var hasChanges: Bool
    var isSaving: Bool
    var isDayLoaded: Bool
    var recordsLoaded: Bool

    var isLoaded: Bool { isDayLoaded && recordsLoaded }
    var canApply: Bool { hasChanges && !isSaving && isLoaded }
}
