import Foundation
import TaptionPlanCore

extension AppModel {
    func selectCatCoat(_ coat: CatCoat) {
        selectedCatCoat = coat
        snapshot.settings.catStyle = coat.catStyle
        publishWatchPayload()
        Task { await persist() }
    }

    func setStartScale(_ scale: TimeScale) {
        let scheduleScale = scale.scheduleEquivalent
        snapshot.settings.startScale = scheduleScale.timelineLevel
        selectedScale = scheduleScale
        Task { await persist() }
    }

    func setRememberLastScale(_ enabled: Bool) {
        snapshot.settings.rememberLastScale = enabled
        if enabled {
            snapshot.settings.startScale = selectedScale.timelineLevel
        }
        Task { await persist() }
    }

    func setReduceMotion(_ enabled: Bool) {
        guard snapshot.settings.reduceMotion != enabled else { return }
        snapshot.settings.reduceMotion = enabled
        publishWatchPayload()
        Task { await persist() }
    }

    var setupCategories: [CategoryDefinition] {
        snapshot.categories.sorted { $0.sortOrder < $1.sortOrder }
    }

    var selectedSetupCategoryCount: Int {
        if !isEditingSetupCategories {
            return snapshot.categories.filter { !$0.isHidden }.count
        }
        return pendingSetupCategoryIDs.count
    }

    func openInitialSetup() {
        let visibleIDs = Set(
            snapshot.categories.filter { !$0.isHidden }.map(\.id)
        )
        pendingSetupCategoryIDs = visibleIDs.isEmpty
            ? Set(snapshot.categories.map(\.id))
            : visibleIDs
        isEditingSetupCategories = true
        detail = .categorySetup
    }

    func toggleSetupCategory(_ categoryID: String) {
        if pendingSetupCategoryIDs.contains(categoryID) {
            pendingSetupCategoryIDs.remove(categoryID)
        } else {
            pendingSetupCategoryIDs.insert(categoryID)
        }
    }

    func cancelInitialCategorySelection() {
        isEditingSetupCategories = false
        pendingSetupCategoryIDs = []
        detail = nil
    }

    func applyInitialCategorySelection() async {
        guard !pendingSetupCategoryIDs.isEmpty else {
            userFacingError = AppLanguagePreference.text(
                korean: "대분류를 하나 이상 선택해 주세요.",
                english: "Select at least one major category."
            )
            return
        }
        snapshot.categories = snapshot.categories.map { category in
            var updated = category
            updated.isHidden = !pendingSetupCategoryIDs.contains(category.id)
            return updated
        }
        await persist()
        isEditingSetupCategories = false
        detail = nil
    }

    func setWeatherEnabled(_ enabled: Bool) async {
        snapshot.settings.weatherEnabled = enabled
        snapshot.settings.permissions[.weather] =
            enabled ? .authorized : .denied
        if enabled {
            await refreshSensorTimeline()
        }
        await persist()
    }

    func setWeatherSidebarVisible(_ visible: Bool) {
        guard snapshot.settings.weatherSidebarVisible != visible else { return }
        snapshot.settings.weatherSidebarVisible = visible
        Task { await persist() }
    }

    func setMapDisplayStyle(_ style: MapDisplayStyle) {
        let persistedStyle = style.runtimeStyle
        guard snapshot.settings.mapDisplayStyle != persistedStyle else { return }
        TaptionPlanDiagnosticsLogger.shared.record(
            "map_style_changed",
            fields: [
                "from": snapshot.settings.mapDisplayStyle.rawValue,
                "to": persistedStyle.rawValue,
            ]
        )
        snapshot.settings.mapDisplayStyle = persistedStyle
        Task { await persist() }
    }

    func setMapDisplayProvider(_ provider: MapDisplayProvider) {
        setMapDisplayStyle(.standard)
    }

    func setMapMemoDisplayFilter(_ filter: MapMemoDisplayFilter) {
        guard snapshot.settings.mapMemoDisplayFilter != filter else { return }
        snapshot.settings.mapMemoDisplayFilter = filter
        Task { await persist() }
    }
}
