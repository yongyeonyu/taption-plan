import Foundation
import TaptionPlanCore

/// 앱 기록 저장소의 경계. 앱의 `TaptionStoreRepository`(SQLite)와 시험용 메모리 저장소가 따른다.
public protocol PlanDataRepository: Sendable {
    func load() async throws -> TaptionDataSnapshot
    func loadStartupSnapshot() async throws -> TaptionDataSnapshot?
    func save(_ snapshot: TaptionDataSnapshot) async throws
    func save(_ snapshot: TaptionDataSnapshot, actualEdit: PlanActualEdit?) async throws
    func actuals(in span: TimeSpan, matching source: [ActualRecord]) async throws -> [ActualRecord]?
    /// 저장 직후 되읽기용: 이 기록 id들이 저장소에 남아 있는지만 확인한다.
    /// 전체 스냅샷을 다시 읽으면 수만 행을 해독하므로, 확인만 필요할 때는 이 좁은 조회를 쓴다.
    func existingActualIDs(_ ids: Set<UUID>) async throws -> Set<UUID>
    func deleteAll() async throws
    func handleMemoryPressure() async
}

extension PlanDataRepository {
    public func loadStartupSnapshot() async throws -> TaptionDataSnapshot? { nil }
    public func save(_ snapshot: TaptionDataSnapshot, actualEdit: PlanActualEdit?) async throws {
        try await save(snapshot)
    }
    public func actuals(in span: TimeSpan, matching source: [ActualRecord]) async throws -> [ActualRecord]? { nil }
    /// 기본 구현은 전체를 읽는다. 저장소가 좁은 조회를 지원하면 그쪽이 이긴다.
    public func existingActualIDs(_ ids: Set<UUID>) async throws -> Set<UUID> {
        guard !ids.isEmpty else { return [] }
        return Set(try await load().actuals.map(\.id)).intersection(ids)
    }
}

extension PlanDataRepository {
    public func deleteAll() async throws {
        try await save(.empty)
    }

    public func handleMemoryPressure() async {}
}
