import GoogleMobileAds
import SwiftUI
import UIKit

enum TaptionAdvertisingPolicy {
    static let launchAdMinimumInterval: TimeInterval = 4 * 60 * 60

    static func shouldPresentLaunchAd(
        lastShownAt: Date?,
        now: Date = .now
    ) -> Bool {
        guard let lastShownAt else { return true }
        return now.timeIntervalSince(lastShownAt) >= launchAdMinimumInterval
    }
}

@MainActor
final class TaptionAdvertisingCoordinator: NSObject, FullScreenContentDelegate {
    static let shared = TaptionAdvertisingCoordinator()

    private let launchAdShownAtKey = "TaptionPlan.launchAdShownAt"
    private var appOpenAd: AppOpenAd?
    private var isLoadingAppOpenAd = false
    private var wantsStartupPresentation = false
    private var isPresenting = false
    private var didPresentThisLaunch = false

    func start() {
        guard MapHomeAdConfiguration.isSDKConfigured else { return }
        MobileAds.shared.start()
        loadAppOpenAdIfNeeded()
    }

    func requestStartupPresentation() {
        wantsStartupPresentation = true
        presentAppOpenAdIfReady()
        loadAppOpenAdIfNeeded()
    }

    private func loadAppOpenAdIfNeeded() {
        guard !didPresentThisLaunch,
              !isLoadingAppOpenAd,
              appOpenAd == nil,
              let unitID = MapHomeAdConfiguration.appOpenUnitID else {
            return
        }

        isLoadingAppOpenAd = true
        Task { [weak self] in
            await self?.loadAppOpenAd(unitID: unitID)
        }
    }

    private func loadAppOpenAd(unitID: String) async {
        defer { isLoadingAppOpenAd = false }
        do {
            appOpenAd = try await AppOpenAd.load(
                with: unitID,
                request: Request()
            )
            appOpenAd?.fullScreenContentDelegate = self
            presentAppOpenAdIfReady()
        } catch {
            appOpenAd = nil
        }
    }

    private func presentAppOpenAdIfReady() {
        guard wantsStartupPresentation,
              !didPresentThisLaunch,
              !isPresenting,
              UIApplication.shared.applicationState == .active,
              TaptionAdvertisingPolicy.shouldPresentLaunchAd(
                lastShownAt: UserDefaults.standard.object(
                    forKey: launchAdShownAtKey
                ) as? Date
              ),
              let appOpenAd else {
            return
        }

        self.appOpenAd = nil
        appOpenAd.fullScreenContentDelegate = self
        isPresenting = true
        appOpenAd.present(from: nil)
    }

    func adWillPresentFullScreenContent(_ ad: FullScreenPresentingAd) {
        didPresentThisLaunch = true
        wantsStartupPresentation = false
        UserDefaults.standard.set(Date.now, forKey: launchAdShownAtKey)
    }

    func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
        isPresenting = false
    }

    func ad(
        _ ad: FullScreenPresentingAd,
        didFailToPresentFullScreenContentWithError error: Error
    ) {
        isPresenting = false
        wantsStartupPresentation = false
    }
}

struct MapHomeBannerAdView: View {
    private let adSize = largeAnchoredAdaptiveBanner(
        width: UIScreen.main.bounds.width
    )

    var body: some View {
        if let unitID = MapHomeAdConfiguration.bannerUnitID {
            MapHomeBannerAdContainer(adSize: adSize, unitID: unitID)
                .frame(
                    width: adSize.size.width,
                    height: adSize.size.height
                )
                .frame(maxWidth: .infinity)
                .accessibilityLabel("광고")
        }
    }
}

private enum MapHomeAdConfiguration {
    static var isSDKConfigured: Bool {
        let applicationID = string(for: "GADApplicationIdentifier")
        return applicationID.hasPrefix("ca-app-pub-")
            && applicationID.contains("~")
    }

    static var bannerUnitID: String? {
        let bannerUnitID = string(for: "TaptionAdMobBannerUnitID")
        guard isSDKConfigured, isValidUnitID(bannerUnitID) else {
            return nil
        }
        return bannerUnitID
    }

    static var appOpenUnitID: String? {
        let appOpenUnitID = string(for: "TaptionAdMobAppOpenUnitID")
        guard isSDKConfigured, isValidUnitID(appOpenUnitID) else {
            return nil
        }
        return appOpenUnitID
    }

    private static func isValidUnitID(_ unitID: String) -> Bool {
        unitID.hasPrefix("ca-app-pub-") && unitID.contains("/")
    }

    private static func string(for key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

private struct MapHomeBannerAdContainer: UIViewRepresentable {
    let adSize: AdSize
    let unitID: String

    func makeUIView(context: Context) -> BannerView {
        TaptionAdvertisingCoordinator.shared.start()

        let banner = BannerView(adSize: adSize)
        banner.adUnitID = unitID
        banner.load(Request())
        return banner
    }

    func updateUIView(_ banner: BannerView, context: Context) {}
}
