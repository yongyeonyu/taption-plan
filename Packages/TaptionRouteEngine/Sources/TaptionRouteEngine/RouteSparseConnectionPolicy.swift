import Foundation

public enum RouteSparseConnectionPolicy {
    public static let maximumGapDuration: TimeInterval = 15 * 60
    public static let minimumSparseGapDuration: TimeInterval = 5 * 60
    public static let maximumSparseDistanceMeters: Double = 1_000

    public static func breaksConnection(
        gapDuration: TimeInterval,
        distanceMeters: Double?
    ) -> Bool {
        gapDuration > minimumSparseGapDuration
            && distanceMeters.map { $0 > maximumSparseDistanceMeters } == true
    }
}
