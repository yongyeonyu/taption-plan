import Testing
@testable import TaptionActivityEngine

struct WalkingStrideTests {
    private let clean = WalkingBout(meters: 700, steps: 1_000, duration: 600, meanAccuracyMeters: 8)

    @Test func medianOfCleanBouts() {
        let other = WalkingBout(meters: 150, steps: 200, duration: 120, meanAccuracyMeters: 12)
        let third = WalkingBout(meters: 300, steps: 400, duration: 240, meanAccuracyMeters: 10)
        #expect(WalkingStride.calibrated([clean, other, third]) == 0.75)
    }

    @Test func dirtyOrFewBoutsGiveNoStride() {
        #expect(WalkingStride.calibrated([clean]) == nil)
        let indoor = WalkingBout(meters: 700, steps: 1_000, duration: 600, meanAccuracyMeters: 60)
        #expect(WalkingStride.calibrated([clean, indoor]) == nil)
        let vehicle = WalkingBout(meters: 5_000, steps: 1_000, duration: 600, meanAccuracyMeters: 8)
        #expect(WalkingStride.calibrated([clean, vehicle]) == nil)
    }
}
