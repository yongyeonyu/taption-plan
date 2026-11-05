import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

extension MapHomeView {
    func recordUserMapAdjustment() {
        liveZoomGovernor.pauseForUserAdjustment(
            uptime: ProcessInfo.processInfo.systemUptime
        )
        hasUserAdjustedMap = true
        hasCancelledInitialLocationFocus = true
        initialLocationRequestTask?.cancel()
        initialLocationRequestTask = nil
        currentLocationRequestTask?.cancel()
        currentLocationRequestTask = nil
        appleViewportCommand = nil
    }
}
