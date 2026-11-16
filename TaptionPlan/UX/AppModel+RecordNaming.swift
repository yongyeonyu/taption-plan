import Foundation
import TaptionPlanCore

/// 자동 기록 이름 붙이기(머무른 곳·버스·결제). 센서 갱신과 다른 화면이 함께 쓴다(RFT1116A03).
extension AppModel {
    func applyStayPlaceNames(asOf now: Date) {
        let named = StayPlaceNaming.retitling(
            snapshot.actuals, places: snapshot.places, names: NLENearbyPlaceNames.storedNames,
            candidates: NLENearbyPlaceNames.storedCandidates,
            activityCorrections: snapshot.settings.activityCorrections, asOf: now
        )
        if named != snapshot.actuals { snapshot.actuals = named }
    }

    /// 버스 구간의 기록 이름을 맞춘다(「버스 · 80번」). 버스가 아니게 된 구간의 기록은 「자동차」로 돌아간다.
    func applyBusRecordTitles(in span: TimeSpan, asOf now: Date) {
        let busSegments = snapshot.travel.filter { $0.mode == .bus && $0.span.intersection(with: span) != nil }
        let titled = BusRideRecognizer.retitling(
            snapshot.actuals,
            busSpans: busSegments.map(\.span),
            titles: busSegments.map { BusRouteCheck.title(BusRouteCheck.known($0) ?? []) },
            activityCorrections: snapshot.settings.activityCorrections,
            asOf: now
        )
        if titled != snapshot.actuals { snapshot.actuals = titled }
    }

    func applyPaymentAnchors(in span: TimeSpan) {
        let anchored = PaymentStayAnchor.applying(
            snapshot.actuals, payments: PaymentStayAnchor.payments(LedgerBook.shared.entries, in: span), places: snapshot.places,
            candidates: NLENearbyPlaceNames.storedCandidates, activityCorrections: snapshot.settings.activityCorrections, asOf: span.end
        )
        if anchored != snapshot.actuals { snapshot.actuals = anchored }
    }

    func scheduleStayPlaceNameLookup(asOf now: Date) {
        let points = StayPlaceNaming.pointsNeedingNames(
            snapshot.actuals, places: snapshot.places, known: NLENearbyPlaceNames.storedCandidates.mapValues { $0.first?.name ?? "" }, asOf: now
        )
        guard !points.isEmpty else { return }
        Task { @MainActor [weak self] in
            let found = await NLENearbyPlaceNames.names(for: points)
            guard let self, !found.isEmpty, !Task.isCancelled, self.acceptsDataMutation() else { return }
            self.applyStayPlaceNames(asOf: now)
        }
    }
}
