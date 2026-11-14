import Foundation
import TaptionPlanCore

// MARK: 등록부 동작 — 알림·장식·장소 종류·지도 활동 색 (ACT1114A09, RMN1114A22).
// `AssistantOperations.catalog`(AssistantDataActions.swift)에 올라 있다.

extension AssistantOperations {
    /// 「근처에 남긴 메모」 알림의 이름. 알림 종류(`MapHomeAlarmKind`)와 따로 저장되는 스위치다.
    static let nearbyMemoAlert = "nearbyMemo"

    @MainActor
    static func isNearbyMemoOn(_ defaults: UserDefaults) -> Bool { defaults.object(forKey: NearbyMemoPolicy.enabledKey) as? Bool ?? true }

    /// 앱 상태에 싣는 켜 둔 알림. 근처 메모 알림도 켜져 있으면 함께 싣는다.
    @MainActor
    static func alertsOn(_ defaults: UserDefaults) -> [String] {
        (MapHomeAlarmSettings.stored(defaults).enabled.map(\.rawValue) + (isNearbyMemoOn(defaults) ? [nearbyMemoAlert] : [])).sorted()
    }

    /// 앱 상태에 싣는 지도 활동 색: 기본 분류(id 글) 다음에 사용자 분류(UUID).
    @MainActor
    static func mapColors(_ model: AppModel, language: MapHomeLanguage = .current) -> [AssistantAppState.MapColor] {
        let settings = model.snapshot.settings
        return MapHomeSidebarMajorCategory.all(categoryColors: settings.mapCategoryColors).map {
            .init(id: $0.id, name: $0.localizedTitle(language), color: $0.hex, custom: false)
        } + settings.mapUserActivityCategories.map { .init(id: $0.id.uuidString, name: $0.title, color: $0.hex, custom: true) }
    }

    static func placeKindTitle(_ kind: FrequentPlaceKind, _ language: MapHomeLanguage) -> String {
        switch kind {
        case .home: language.text("집", "Home")
        case .school: language.text("학교", "School")
        case .academy: language.text("학원", "Academy")
        case .company: language.text("회사", "Work")
        case .hobby: language.text("취미", "Hobby")
        case .exercise: language.text("운동", "Exercise")
        case .restaurant: language.text("식당", "Restaurant")
        case .custom: language.text("기타", "Other")
        }
    }

    /// 알림 종류 하나 켜고 끄기(알림 설정의 스위치와 같은 저장 값). iOS 알림 권한은 건드리지 않는다.
    struct SetAlert: AssistantOperation {
        static let spec = AssistantOperationSpec(
            name: "setAlert", fields: ["alert", "enabled"], counter: .settings,
            title: { $0.text("알림 종류 켜고 끄기", "Switch alert kinds on or off") },
            guide: #""alert":"\#((MapHomeAlarmKind.allCases.map(\.rawValue) + [AssistantOperations.nearbyMemoAlert]).joined(separator: "|"))","enabled":false} (one kind of app alert; those on are in GET /app settings.alertsOn; nearbyMemo is the alert for a memo I left near where I am; this does not grant the iOS notification permission)"#
        )

        /// nil이면 근처 메모 알림이다.
        let kind: MapHomeAlarmKind?
        let enabled: Bool

        init?(fields: AssistantFields) {
            guard let enabled = fields.flag("enabled") else { return nil }
            let kind: MapHomeAlarmKind? = fields.choice("alert")
            guard kind != nil || fields.raw("alert") == AssistantOperations.nearbyMemoAlert else { return nil }
            self.kind = kind
            self.enabled = enabled
        }

        func apply(host: AssistantOperationHost) async -> AssistantEditResult {
            let language = host.language
            guard let kind else { return applyNearbyMemo(host: host) }
            var settings = MapHomeAlarmSettings.stored(host.defaults)
            guard settings.enabled.contains(kind) != enabled else { return .rejected("no_change") }
            if enabled { settings.enabled.insert(kind) } else { settings.enabled.remove(kind) }
            guard let change = host.changing(MapHomeAlarmSettings.storageKey, { host.defaults.set(settings.rawValue, forKey: MapHomeAlarmSettings.storageKey) }) else {
                return .rejected("no_change")
            }
            if host.preferences.isLive { await MapHomeAlarmCenter.shared.syncDailyCardSchedule(language: language) }
            return result(kind.title(language), change, language)
        }

        /// 근처 메모 알림 스위치(RMN1114A22). 권한은 묻지 않고, 감시 지역은 화면의 스위치와 같이 다시 맞춘다.
        @MainActor
        private func applyNearbyMemo(host: AssistantOperationHost) -> AssistantEditResult {
            let key = NearbyMemoPolicy.enabledKey
            guard AssistantOperations.isNearbyMemoOn(host.defaults) != enabled,
                  let change = host.changing(key, { host.defaults.set(enabled, forKey: key) }) else { return .rejected("no_change") }
            if host.preferences.isLive { host.model.scheduleNearbyMemoSync() }
            return result(host.language.text("근처에 남긴 메모", "Memos left nearby"), change, host.language)
        }

        @MainActor
        private func result(_ name: String, _ change: AssistantAppChange.Stored, _ language: MapHomeLanguage) -> AssistantEditResult {
            var result = AssistantEditResult(before: "\(name): \(AssistantOperations.onOff(!enabled, language))", after: "\(name): \(AssistantOperations.onOff(enabled, language))")
            result.appChange = AssistantAppChange(stored: [change])
            return result
        }
    }

    /// 화랑이 꾸미기: 이미 받은 장식 하나를 입히거나(집 성장 화면의 「착용」과 같은 `equipAccessory`), 걸친 자리 하나를 벗긴다(`unequip`).
    struct SetCatOutfit: AssistantOperation {
        static let spec = AssistantOperationSpec(
            name: "setCatOutfit", fields: ["accessoryId", "remove"], counter: .settings,
            title: { $0.text("고양이 장식 입히기", "Dress my cat") },
            guide: #""accessoryId":"<settings.outfit.owned[]>"} (puts on one accessory I already earned; one hat, one scarf and one tail ribbon can be worn together; worn ones are in GET /app settings.outfit.worn; or "remove":"hat|scarf|ribbon" instead of accessoryId takes that one off)"#
        )

        let accessoryID: String?
        let remove: MapHomeAccessoryKind?

        init?(fields: AssistantFields) {
            let remove: MapHomeAccessoryKind? = fields.choice("remove")
            let accessoryID = fields.string("accessoryId", max: 100)
            // 입히기와 벗기기 가운데 하나만 받는다.
            guard fields.ok("remove", remove), fields.ok("accessoryId", accessoryID), (accessoryID == nil) != (remove == nil),
                  accessoryID?.hasPrefix("cat.accessory.") ?? true else { return nil }
            self.accessoryID = accessoryID
            self.remove = remove
        }

        func apply(host: AssistantOperationHost) async -> AssistantEditResult {
            let language = host.language
            func name(_ id: String?) -> String {
                guard let id else { return "" }
                return MapHomeGrowthAccessoryCatalog.landmark(for: id).map { language.runtimeText($0.name, $0.englishName) } ?? id
            }
            guard var history = AssistantOperations.growthHistory(host.defaults) else { return .rejected(remove == nil ? "no_accessory" : "no_change") }
            let before: String, after: String
            if let remove {
                guard let worn = history.season.equipped(remove), MapHomeGrowthPolicy.unequip(kind: remove, in: &history.season) else { return .rejected("no_change") }
                (before, after) = (name(worn), language.text("없음", "None"))
            } else {
                guard let accessoryID, history.season.accessories.contains(accessoryID) else { return .rejected("no_accessory") }
                guard !history.season.isEquipped(accessoryID) else { return .rejected("no_change") }
                before = name(history.season.equipped(MapHomeGrowthAccessoryCatalog.kind(for: accessoryID)))
                guard MapHomeGrowthPolicy.equipAccessory(accessoryID, in: &history.season) else { return .rejected("edit_failed") }
                after = name(accessoryID)
            }
            guard let encoded = try? JSONEncoder().encode(history),
                  let change = host.changing(MapHomeGrowthPolicy.storageKey, { host.defaults.set(encoded, forKey: MapHomeGrowthPolicy.storageKey) }) else {
                return .rejected("edit_failed")
            }
            var result = AssistantEditResult(before: before, after: after)
            result.appChange = AssistantAppChange(stored: [change])
            return result
        }
    }

    /// 자주 가는 장소의 종류(RMN1114A22, `setFrequentPlaceKind`). 식당·기타 말고는 한 곳만 둔다.
    struct SetPlaceKind: AssistantOperation {
        static let spec = AssistantOperationSpec(
            name: "setPlaceKind", fields: ["placeId", "kind"], counter: .settings,
            title: { $0.text("자주 가는 장소의 종류 바꾸기", "Change kinds of frequent places") },
            guide: #""placeId":"<places[].id>","kind":"\#(FrequentPlaceKind.allCases.map(\.rawValue).joined(separator: "|"))"} (what kind of place a registered place is; every kind except restaurant and custom holds one place, so it is rejected with kind_taken when another place already has it)"#
        )

        let placeID: UUID
        let kind: FrequentPlaceKind

        init?(fields: AssistantFields) {
            guard let placeID = fields.uuid("placeId"), let kind: FrequentPlaceKind = fields.choice("kind") else { return nil }
            self.placeID = placeID
            self.kind = kind
        }

        func apply(host: AssistantOperationHost) async -> AssistantEditResult {
            let model = host.model, language = host.language
            guard let place = model.snapshot.settings.frequentPlaces.first(where: { $0.id == placeID }) else { return .rejected("no_place") }
            switch model.setFrequentPlaceKind(placeID, kind: kind) {
            case .missing: return .rejected("no_place")
            case .same: return .rejected("no_change")
            case .taken: return .rejected("kind_taken")
            case .empty: return .rejected("place_not_located")
            case .changed: break
            }
            await model.persist()
            guard model.snapshot.settings.frequentPlaces.first(where: { $0.id == placeID })?.kind == kind else { return .rejected("edit_failed") }
            return AssistantEditResult(
                before: "\(place.displayName) · \(AssistantOperations.placeKindTitle(place.kind, language))",
                after: "\(place.displayName) · \(AssistantOperations.placeKindTitle(kind, language))"
            )
        }
    }

    /// 지도·시간 막대가 쓰는 활동 색(RMN1114A22, 메뉴의 색 팔레트와 같은 `setMapCategoryColor`).
    struct SetMapActivityColor: AssistantOperation {
        static let spec = AssistantOperationSpec(
            name: "setMapActivityColor", fields: ["categoryId", "color"], counter: .settings,
            title: { $0.text("지도 활동 색 바꾸기", "Change map activity colours") },
            guide: ##""categoryId":"<settings.mapColors[].id>","color":"#RRGGBB"} (the colour the map and the time bar use for one activity; current colours are in GET /app settings.mapColors)"##
        )

        let categoryID: String
        let color: String

        init?(fields: AssistantFields) {
            guard let categoryID = fields.string("categoryId", max: 100), let color = fields.raw("color"),
                  color.count == 7, color.first == "#", color.dropFirst().allSatisfy(\.isHexDigit) else { return nil }
            self.categoryID = categoryID
            self.color = color.uppercased()
        }

        func apply(host: AssistantOperationHost) async -> AssistantEditResult {
            let model = host.model
            guard let current = model.mapActivityColor(for: categoryID),
                  let name = AssistantOperations.mapColors(model, language: host.language).first(where: { $0.id == categoryID })?.name
            else { return .rejected("unknown_category") }
            guard current.uppercased() != color else { return .rejected("no_change") }
            // 기본 분류는 고른 색이 없었으면 되돌릴 때 기본 색으로 돌아가게 nil로 적는다.
            let hadChoice = UUID(uuidString: categoryID) != nil || model.snapshot.settings.mapCategoryColors[categoryID] != nil
            model.setMapCategoryColor(color, for: categoryID)
            await model.persist()
            guard model.mapActivityColor(for: categoryID) == color else { return .rejected("edit_failed") }
            var result = AssistantEditResult(before: "\(name) \(current)", after: "\(name) \(color)")
            result.appChange = AssistantAppChange(mapColor: .init(categoryID: categoryID, before: hadChoice ? current : nil, after: color))
            return result
        }
    }
}
