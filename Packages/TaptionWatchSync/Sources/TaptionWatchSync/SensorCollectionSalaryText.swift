import Foundation

/// 잠금 화면 연봉 카운터 글자. 앱이 준 기준값에서 지금 시각까지 흐른 근무 시간을 더해 간격 단위로 맞춘다.
public enum SensorCollectionSalaryText {
    public static func text(
        baseSeconds: Double,
        hourlyRate: Double,
        measuredAt: Date,
        isWorking: Bool,
        tickSeconds: Int,
        now: Date,
        currencyCode: String? = nil
    ) -> String {
        let tick = Double(max(1, tickSeconds))
        let elapsed = isWorking ? max(0, now.timeIntervalSince(measuredAt)) : 0
        let seconds = ((max(0, baseSeconds) + elapsed) / tick).rounded(.down) * tick
        let amount = seconds / 3_600 * hourlyRate
        let region = AppRegion.current
        guard currencyCode == nil || currencyCode == region.currencyCode else {
            return amount.formatted(.currency(code: currencyCode ?? "KRW"))
        }
        return region.moneyText(amount)
    }
}
