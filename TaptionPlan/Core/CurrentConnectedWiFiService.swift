import CoreLocation
import Foundation
import NetworkExtension
import TaptionPlanCore

/// Reads only the network the device is currently joined to. iOS does not
/// expose a surrounding-network scan to third-party apps. Access requires
/// the Wi-Fi information entitlement and an authorized location status.
@MainActor
enum CurrentConnectedWiFiService {
    static func fetchSSID(
        authorizationStatus: CLAuthorizationStatus,
        completion: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        guard authorizationStatus == .authorizedAlways
                || authorizationStatus == .authorizedWhenInUse else {
            completion(nil)
            return
        }
        guard #available(iOS 14.0, *) else {
            completion(nil)
            return
        }
        NEHotspotNetwork.fetchCurrent { network in
            let ssid = network?.ssid
            Task { @MainActor in
                completion(ssid)
            }
        }
    }
}
