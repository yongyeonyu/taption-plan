import Foundation
import TaptionPlanStore

// 등록부 동작 4·5묶음 — 사진, 분류·장소·설정 (ACT1114A07·ACT1114A09·RMN1114A22)의 읽기 쪽.
// 적용(`apply`)은 앱의 `TravelPlacePhotos.swift`·`AssistantDataActions.swift`·`AssistantMoreActions.swift`에 있다(RMN1114A25).

/// 장소·분류 명령이 지키는 한도(ACA1112A01).
public enum AssistantCatalogLimits {
    public static let placeName = 40
    public static let categoryName = 20
    public static let radius = 30.0...500.0
    public static let places = 100

    public static func radiusOK(_ value: Double?) -> Bool { value.map { $0.isFinite && radius.contains($0) } ?? true }

    public static func isColor(_ text: String) -> Bool {
        text.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil
    }
}

extension AssistantOperations {
    public static let photos: [any AssistantOperationReading.Type] = [SetTripItemPhoto.self]

    /// 여행 카드 사진으로 받는 서버. 이 셋의 https 주소만 받는다.
    public static let photoHosts: Set<String> = ["upload.wikimedia.org", "images.unsplash.com", "images.pexels.com"]

    public static func allowedPhotoURL(_ text: String) -> URL? {
        guard text.count <= 500, let url = URL(string: text), url.scheme == "https", url.user == nil, url.port == nil,
              let host = url.host?.lowercased(), photoHosts.contains(host) else { return nil }
        return url
    }

    /// 여행 일정 카드에 보일 사진 주소를 정하거나 뗀다. 사진 자체는 서버를 거치지 않는다.
    public struct SetTripItemPhoto: AssistantOperationReading {
        public static let spec = AssistantOperationSpec(
            name: "setTripItemPhoto", fields: ["itemId", "photoUrl", "credit", "remove"], counter: .schedules,
            title: { $0.text("여행 일정 사진 정하기", "Set trip item photos") },
            guide: #""itemId":"<trips[].items[].itemId>","photoUrl":"https://upload.wikimedia.org/...","credit":"Author, CC BY-SA 4.0"} (the photo shown on one trip card; only a direct https image link on upload.wikimedia.org, images.unsplash.com or images.pexels.com that you actually found, never a guessed one; credit names the author and licence; "remove":true goes back to the app's own search)"#
        )

        public let itemID: String
        public let url: URL?
        public let credit: String

        public init?(fields: AssistantFields) {
            let url = fields.raw("photoUrl").flatMap(AssistantOperations.allowedPhotoURL), credit = fields.string("credit", max: 120), remove = fields.flag("remove")
            guard let itemID = fields.string("itemId", max: 100), fields.ok("photoUrl", url), fields.ok("credit", credit), fields.ok("remove", remove),
                  (remove == true) != (url != nil), remove != false, remove == nil || credit == nil else { return nil }
            self.itemID = itemID
            self.url = url
            self.credit = credit ?? ""
        }
    }
}

extension AssistantOperations {
    public static let catalog: [any AssistantOperationReading.Type] = [
        MoveCategory.self, DeleteCategory.self, SetPlaceFloor.self, AddMyStop.self, UpdateMyStop.self, DeleteMyStop.self,
        SetDayCardItems.self, SetDayCardTime.self, SetAlert.self, SetCatOutfit.self, SetPlaceKind.self, SetMapActivityColor.self,
    ]

    /// 「근처에 남긴 메모」 알림의 이름. 알림 종류(`alertKinds`)와 따로 저장되는 스위치다.
    public static let nearbyMemoAlert = "nearbyMemo"

    // 앱 화면의 값과 같아야 하는 이름들. 앱 시험(`AssistantCommandEditTests`)이 앱의 형과 맞는지 본다.
    /// 알림 종류(`MapHomeAlarmKind`).
    public static let alertKinds = [
        "arriveCompany", "leaveCompany", "arriveSchool", "leaveSchool", "arriveAcademy", "leaveAcademy", "arriveHome", "leaveHome",
        "wakeUp", "dailyCard", "rateChange", "breakEven",
    ]
    /// 장식 자리(`MapHomeAccessoryKind`).
    public static let accessoryKinds = ["hat", "scarf", "ribbon"]
    /// 하루 카드 항목(`MapHomeCardMetricOption.all`)과 한 번에 올리는 수(`MapHomeCardMetricSelection.maximum`).
    public static let dayCardItems = [
        "sleep", "movement", "study", "work", "exercise", "hobby", "distance", "places", "trips",
        "steps", "photos", "walkDistance", "carDistance", "transitDistance", "awayTime", "stepDistance", "calories",
        "income", "expense", "memos",
    ]
    public static let dayCardItemLimit = 4

    /// 분류 차례 바꾸기(분류 목록을 끌어 옮기는 것과 같은 `moveCategories`). 자리는 「미확인」을 뺀 목록에서 센다(앱 상태의 차례와 같다).
    public struct MoveCategory: AssistantOperationReading {
        public static let spec = AssistantOperationSpec(
            name: "moveCategory", fields: ["categoryId", "position"], counter: .settings,
            title: { $0.text("분류 차례 바꾸기", "Reorder categories") },
            guide: #""categoryId":"<categories[].id>","position":1} (moves one major category to that place in the list, 1 is the top; categories in GET /app are in their order)"#
        )

        public let categoryID: String
        public let position: Int

        public init?(fields: AssistantFields) {
            guard let categoryID = fields.string("categoryId", max: 100), let position = fields.integer("position", in: 1...100) else { return nil }
            self.categoryID = categoryID
            self.position = position
        }
    }

    /// 내가 만든 분류 지우기(분류 편집의 「삭제」와 같은 `deleteCustomCategory`). 그 분류의 일정·기록은 `moveTo`로 옮긴다.
    public struct DeleteCategory: AssistantOperationReading {
        public static let spec = AssistantOperationSpec(
            name: "deleteCategory", fields: ["categoryId", "moveTo"], counter: .settings, deletes: true,
            title: { $0.text("내가 만든 분류 지우기", "Delete my categories") },
            guide: #""categoryId":"<categories[].id with custom true>","moveTo":"<another categories[].id>"} (deletes a category I made; its plans and records move to moveTo; built-in categories cannot be deleted, hide those with updateCategory; only when I asked)"#
        )

        public let categoryID: String
        public let moveTo: String

        public init?(fields: AssistantFields) {
            guard let categoryID = fields.string("categoryId", max: 100), let moveTo = fields.string("moveTo", max: 100), categoryID != moveTo else { return nil }
            self.categoryID = categoryID
            self.moveTo = moveTo
        }
    }

    /// 자주 가는 장소의 층(장소 편집의 층 고르기와 같은 `setFrequentPlaceFloor`). 높이 재기는 그 자리에서 사용자가 한다.
    public struct SetPlaceFloor: AssistantOperationReading {
        public static let spec = AssistantOperationSpec(
            name: "setPlaceFloor", fields: ["placeId", "floor"], counter: .settings,
            title: { $0.text("자주 가는 장소의 층 정하기", "Set floors of frequent places") },
            guide: #""placeId":"<places[].id>","floor":3} (which floor a registered place is on, -10 to 100, basements negative)"#
        )

        public let placeID: UUID
        public let floor: Int

        public init?(fields: AssistantFields) {
            guard let placeID = fields.uuid("placeId"), let floor = fields.integer("floor", in: FloorCalibrationPrompt.range) else { return nil }
            self.placeID = placeID
            self.floor = floor
        }
    }

    /// 내 정류장 더하기(「내 정류장」 화면과 같은 `addUserTransitLocation`). 좌표는 받기만 하고 내보내지 않는다.
    public struct AddMyStop: AssistantOperationReading {
        public static let spec = AssistantOperationSpec(
            name: "addMyStop", fields: ["name", "kind", "latitude", "longitude", "floor"], counter: .settings, changes: 0,
            title: { $0.text("내 정류장 더하기", "Add my stations and stops") },
            guide: #""name":"Home stop","kind":"subwayStation|busStop|trainStation|airport|harbor","latitude":37.5,"longitude":127.0,"floor":-2} (registers a station or stop I use so rides from there are recognised; floor optional; my stops are in GET /app settings.myStops without coordinates)"#
        )

        public let name: String
        public let kind: UserTransitLocationKind
        public let latitude: Double
        public let longitude: Double
        public let floor: Int?

        public init?(fields: AssistantFields) {
            let floor = fields.integer("floor", in: FloorCalibrationPrompt.range)
            guard let name = fields.string("name", max: AssistantCatalogLimits.placeName), let kind: UserTransitLocationKind = fields.choice("kind"),
                  let latitude = fields.number("latitude"), abs(latitude) <= 90, let longitude = fields.number("longitude"), abs(longitude) <= 180,
                  fields.ok("floor", floor) else { return nil }
            self.name = name
            self.kind = kind
            self.latitude = latitude
            self.longitude = longitude
            self.floor = floor
        }
    }

    /// 내 정류장 이름·층 고치기(`renameUserTransitLocation`·`setUserTransitLocationFloor`).
    public struct UpdateMyStop: AssistantOperationReading {
        public static let spec = AssistantOperationSpec(
            name: "updateMyStop", fields: ["stopId", "name", "floor", "clearFloor"], counter: .settings,
            title: { $0.text("내 정류장 고치기", "Edit my stations and stops") },
            guide: #""stopId":"<settings.myStops[].id>","name":"New name","floor":-1} (renames one of my stops or sets its floor; "clearFloor":true instead of floor for no floor; give at least one)"#
        )

        public let stopID: UUID
        public let name: String?
        public let floor: Int?
        public let clearsFloor: Bool

        public init?(fields: AssistantFields) {
            let name = fields.string("name", max: AssistantCatalogLimits.placeName), floor = fields.integer("floor", in: FloorCalibrationPrompt.range)
            let clear = fields.flag("clearFloor")
            guard let stopID = fields.uuid("stopId"), fields.ok("name", name), fields.ok("floor", floor), fields.ok("clearFloor", clear), clear != false,
                  name != nil || floor != nil || clear == true, !(clear == true && floor != nil) else { return nil }
            self.stopID = stopID
            self.name = name
            self.floor = floor
            clearsFloor = clear == true
        }
    }

    /// 내 정류장 지우기(`deleteUserTransitLocation`).
    public struct DeleteMyStop: AssistantOperationReading {
        public static let spec = AssistantOperationSpec(
            name: "deleteMyStop", fields: ["stopId"], counter: .settings, deletes: true,
            title: { $0.text("내 정류장 지우기", "Delete my stations and stops") },
            guide: #""stopId":"<settings.myStops[].id>"} (deletes one of my stations or stops; only when I asked)"#
        )

        public let stopID: UUID

        public init?(fields: AssistantFields) {
            guard let stopID = fields.uuid("stopId") else { return nil }
            self.stopID = stopID
        }
    }

    /// 하루 카드에 올릴 항목(카드의 「항목 고르기」와 같은 저장 값, 4개까지).
    public struct SetDayCardItems: AssistantOperationReading {
        public static let spec = AssistantOperationSpec(
            name: "setDayCardItems", fields: ["items"], counter: .settings,
            title: { $0.text("하루 카드 항목 고르기", "Choose day card figures") },
            guide: #""items":["sleep","steps","expense"]} (up to four figures on my daily share card, in order; [] for none; any of \#(AssistantOperations.dayCardItems.joined(separator: "|")); current ones in GET /app settings.dayCard.items)"#
        )

        public let items: [String]

        public init?(fields: AssistantFields) {
            let known = Set(AssistantOperations.dayCardItems)
            guard let items = fields.texts("items", max: 40, count: 0...AssistantOperations.dayCardItemLimit), items.allSatisfy(known.contains) else { return nil }
            self.items = items
        }
    }

    /// 하루 카드 알림 시각(알림 설정의 시각 고르기와 같은 두 키). 예약도 화면처럼 다시 맞춘다.
    public struct SetDayCardTime: AssistantOperationReading {
        public static let spec = AssistantOperationSpec(
            name: "setDayCardTime", fields: ["time"], counter: .settings,
            title: { $0.text("하루 카드 알림 시각 바꾸기", "Change the day card time") },
            guide: #""time":"08:00"} (when the daily "yesterday's card is ready" alert arrives; current time in GET /app settings.dayCard.time)"#
        )

        public let minutes: Int

        public init?(fields: AssistantFields) {
            guard let minutes = fields.minutes("time") else { return nil }
            self.minutes = minutes
        }
    }

    /// 알림 종류 하나 켜고 끄기(알림 설정의 스위치와 같은 저장 값). iOS 알림 권한은 건드리지 않는다.
    public struct SetAlert: AssistantOperationReading {
        public static let spec = AssistantOperationSpec(
            name: "setAlert", fields: ["alert", "enabled"], counter: .settings,
            title: { $0.text("알림 종류 켜고 끄기", "Switch alert kinds on or off") },
            guide: #""alert":"\#((AssistantOperations.alertKinds + [AssistantOperations.nearbyMemoAlert]).joined(separator: "|"))","enabled":false} (one kind of app alert; those on are in GET /app settings.alertsOn; nearbyMemo is the alert for a memo I left near where I am; this does not grant the iOS notification permission)"#
        )

        /// 알림 종류 이름(`alertKinds` 가운데 하나). nil이면 근처 메모 알림이다.
        public let kindName: String?
        public let enabled: Bool

        public init?(fields: AssistantFields) {
            guard let enabled = fields.flag("enabled") else { return nil }
            let kind = fields.choice("alert", among: AssistantOperations.alertKinds)
            guard kind != nil || fields.raw("alert") == AssistantOperations.nearbyMemoAlert else { return nil }
            kindName = kind
            self.enabled = enabled
        }
    }

    /// 화랑이 꾸미기: 이미 받은 장식 하나를 입히거나(집 성장 화면의 「착용」과 같은 `equipAccessory`), 걸친 자리 하나를 벗긴다(`unequip`).
    public struct SetCatOutfit: AssistantOperationReading {
        public static let spec = AssistantOperationSpec(
            name: "setCatOutfit", fields: ["accessoryId", "remove"], counter: .settings,
            title: { $0.text("고양이 장식 입히기", "Dress my cat") },
            guide: #""accessoryId":"<settings.outfit.owned[]>"} (puts on one accessory I already earned; one hat, one scarf and one tail ribbon can be worn together; worn ones are in GET /app settings.outfit.worn; or "remove":"hat|scarf|ribbon" instead of accessoryId takes that one off)"#
        )

        public let accessoryID: String?
        /// 벗길 자리 이름(`accessoryKinds` 가운데 하나).
        public let removeName: String?

        public init?(fields: AssistantFields) {
            let remove = fields.choice("remove", among: AssistantOperations.accessoryKinds)
            let accessoryID = fields.string("accessoryId", max: 100)
            // 입히기와 벗기기 가운데 하나만 받는다.
            guard fields.ok("remove", remove), fields.ok("accessoryId", accessoryID), (accessoryID == nil) != (remove == nil),
                  accessoryID?.hasPrefix("cat.accessory.") ?? true else { return nil }
            self.accessoryID = accessoryID
            removeName = remove
        }
    }

    /// 자주 가는 장소의 종류(RMN1114A22, `setFrequentPlaceKind`). 식당·기타 말고는 한 곳만 둔다.
    public struct SetPlaceKind: AssistantOperationReading {
        public static let spec = AssistantOperationSpec(
            name: "setPlaceKind", fields: ["placeId", "kind"], counter: .settings,
            title: { $0.text("자주 가는 장소의 종류 바꾸기", "Change kinds of frequent places") },
            guide: #""placeId":"<places[].id>","kind":"\#(FrequentPlaceKind.allCases.map(\.rawValue).joined(separator: "|"))"} (what kind of place a registered place is; every kind except restaurant and custom holds one place, so it is rejected with kind_taken when another place already has it)"#
        )

        public let placeID: UUID
        public let kind: FrequentPlaceKind

        public init?(fields: AssistantFields) {
            guard let placeID = fields.uuid("placeId"), let kind: FrequentPlaceKind = fields.choice("kind") else { return nil }
            self.placeID = placeID
            self.kind = kind
        }
    }

    /// 지도·시간 막대가 쓰는 활동 색(RMN1114A22, 메뉴의 색 팔레트와 같은 `setMapCategoryColor`).
    public struct SetMapActivityColor: AssistantOperationReading {
        public static let spec = AssistantOperationSpec(
            name: "setMapActivityColor", fields: ["categoryId", "color"], counter: .settings,
            title: { $0.text("지도 활동 색 바꾸기", "Change map activity colours") },
            guide: ##""categoryId":"<settings.mapColors[].id>","color":"#RRGGBB"} (the colour the map and the time bar use for one activity; current colours are in GET /app settings.mapColors)"##
        )

        public let categoryID: String
        public let color: String

        public init?(fields: AssistantFields) {
            guard let categoryID = fields.string("categoryId", max: 100), let color = fields.raw("color"),
                  color.count == 7, color.first == "#", color.dropFirst().allSatisfy(\.isHexDigit) else { return nil }
            self.categoryID = categoryID
            self.color = color.uppercased()
        }
    }
}
