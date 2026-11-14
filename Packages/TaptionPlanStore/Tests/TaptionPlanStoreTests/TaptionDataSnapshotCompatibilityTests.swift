import Foundation
import Testing
import TaptionPlanCore
@testable import TaptionPlanStore

/// 앱에서 옮겨 온 `TaptionDataSnapshot`(과 저장 속성 타입 전체)의 저장 바이트 계약.
/// 기대 JSON은 옮기기 전 앱 선언으로 같은 `SnapshotFixture.make()`를 인코딩한 결과다(RFA1102A01).
/// 저장소·백업과 같은 설정(`secondsSince1970`, `sortedKeys`)을 쓴다.
struct TaptionDataSnapshotCompatibilityTests {
    static let stored = ##"{"actuals":[{"behavior":"walking","categoryID":"movement","confidence":"medium","createdAt":1762560000,"endedAt":1762560600,"evidence":["steps"],"id":"00000000-0000-0000-0000-000000000002","isClassificationLocked":true,"manuallyCorrected":false,"source":"motion","startedAt":1762560000,"title":"걷기"}],"calendarEvents":[{"calendarColorHex":"#FF0000","calendarID":"cal","calendarTitle":"개인","id":"evt","isAllDay":false,"notes":"노트","span":{"end":1762561800,"start":1762560000},"timeZoneIdentifier":"Asia\/Seoul","title":"약속"}],"categories":[{"actualHex":"#333333","darkHex":"#222222","icon":"briefcase","id":"work","isBuiltIn":false,"isHidden":false,"lightHex":"#111111","name":"일","sortOrder":1}],"floorTransitions":[{"confidence":"medium","evidence":["altimeter"],"fromFloor":1,"id":"00000000-0000-0000-0000-000000000009","placeKey":"home","relativeAltitudeMeters":6.5,"span":{"end":1762561800,"start":1762560000},"toFloor":3}],"memos":[{"attachments":[],"categoryID":"movement","createdAt":1762560000,"id":"00000000-0000-0000-0000-000000000004","isHighlightedInReview":true,"isTimeless":false,"kind":"idea","mapPoint":{"altitude":12.5,"horizontalAccuracy":5,"latitude":37.5,"longitude":127.25,"verticalAccuracy":-1},"occurredAt":1762560000,"targetID":"actual:b","text":"메모","updatedAt":1762560000}],"photos":[{"capturedAt":1762560000,"id":"photo-1","isFavorite":true,"isHiddenFromTimeline":false,"location":{"altitude":12.5,"horizontalAccuracy":5,"latitude":37.5,"longitude":127.25,"verticalAccuracy":-1},"pixelHeight":3024,"pixelWidth":4032}],"places":[{"confidence":"high","displayName":"집","floor":3,"id":"00000000-0000-0000-0000-000000000007","isConfirmed":true,"placeKey":"home","point":{"altitude":12.5,"horizontalAccuracy":5,"latitude":37.5,"longitude":127.25,"verticalAccuracy":-1},"span":{"end":1762561800,"start":1762560000}}],"plans":[{"categoryID":"work","createdAt":1762560000,"id":"00000000-0000-0000-0000-000000000001","isFixed":false,"isImportant":false,"origin":"user","span":{"end":1762561800,"start":1762560000},"status":"planned","title":"회의","updatedAt":1762560000}],"recordLinks":[{"createdAt":1762560000,"fromNodeID":"plan:a","id":"00000000-0000-0000-0000-000000000003","toNodeID":"actual:b"}],"schemaVersion":3,"settings":{"activityCorrections":[],"backgroundPreciseLocationEnabled":false,"calendarTitleDetails":{},"catStyle":"calico","cloudDeletedRecordKeys":[],"cloudResetAt":1762560000,"confirmedSleepSpans":[{"end":1762561800,"start":1762560000}],"customActivityLabels":[],"dismissedPlaceSuggestions":[],"floorCalibrationHistory":[],"frequentPlaces":[{"createdAt":1762560000,"floorHeightMeters":3,"floorReferencePoints":[],"id":"00000000-0000-0000-0000-000000000900","isAutomaticRecordingEnabled":true,"kind":"home","minimumDwellMinutes":10,"name":"장소0","radiusMeters":120,"updatedAt":1762560000},{"createdAt":1762560000,"floorHeightMeters":3,"floorReferencePoints":[],"id":"00000000-0000-0000-0000-000000000901","isAutomaticRecordingEnabled":true,"kind":"school","minimumDwellMinutes":10,"name":"장소1","radiusMeters":120,"updatedAt":1762560000},{"createdAt":1762560000,"floorHeightMeters":3,"floorReferencePoints":[],"id":"00000000-0000-0000-0000-000000000902","isAutomaticRecordingEnabled":true,"kind":"academy","minimumDwellMinutes":10,"name":"장소2","radiusMeters":120,"updatedAt":1762560000},{"createdAt":1762560000,"floorHeightMeters":3,"floorReferencePoints":[],"id":"00000000-0000-0000-0000-000000000903","isAutomaticRecordingEnabled":true,"kind":"company","minimumDwellMinutes":10,"name":"장소3","radiusMeters":120,"updatedAt":1762560000},{"createdAt":1762560000,"floorHeightMeters":3,"floorReferencePoints":[],"id":"00000000-0000-0000-0000-000000000904","isAutomaticRecordingEnabled":true,"kind":"hobby","minimumDwellMinutes":10,"name":"장소4","radiusMeters":120,"updatedAt":1762560000},{"createdAt":1762560000,"floorHeightMeters":3,"floorReferencePoints":[],"id":"00000000-0000-0000-0000-000000000905","isAutomaticRecordingEnabled":true,"kind":"exercise","minimumDwellMinutes":10,"name":"장소5","radiusMeters":120,"updatedAt":1762560000}],"gpsLoggingPreferences":{"intervalSeconds":300,"isBatteryMinimal":false},"healthEnabled":false,"locationEnabled":false,"mapCategoryColors":{"movement":"#123456"},"mapDisplayStyle":"mapLibreRPG","mapMemoDisplayFilter":"all","mapUserActivityCategories":[],"movementCorrections":[],"notificationsEnabled":false,"permissions":["location","authorized"],"predictedRouteDecisions":[],"recentCarAudioNames":[],"reduceMotion":false,"registeredCarAudioNames":["내 차"],"rememberLastScale":false,"selectedCalendarIDs":[],"sensorCollectionProfile":1,"showsPhotos":false,"showsPhotosInWidgets":false,"startScale":"day","suppressedActualIDs":["00000000-0000-0000-0000-000000000070"],"timelineRowOrder":["calendar","location","movement","sleep","activity","appUsage","weather","photo","memo"],"transitBoardingDecisions":[],"userTransitLocations":[],"watchAccelerationProfile":0,"watchDataSyncProfile":0,"weatherEnabled":false,"weatherSidebarVisible":true},"stickers":[{"colorHex":"#F28FA9","createdAt":1762560000,"id":"00000000-0000-0000-0000-000000000005","occurredAt":1762560000,"placement":"map","point":{"altitude":12.5,"horizontalAccuracy":5,"latitude":37.5,"longitude":127.25,"verticalAccuracy":-1},"systemImage":"star.fill","title":"별","updatedAt":1762560000}],"travel":[{"confidence":"low","distanceMeters":800,"evidence":["gps"],"id":"00000000-0000-0000-0000-000000000008","isClassificationLocked":false,"isConfirmed":false,"mode":"walking","span":{"end":1762561800,"start":1762560000}}],"updatedAt":1762560060,"weather":[{"condition":"clear","id":"00000000-0000-0000-0000-000000000006","isContextOnly":true,"isForecast":false,"isStale":false,"observedAt":1762560000,"point":{"altitude":12.5,"horizontalAccuracy":5,"latitude":37.5,"longitude":127.25,"verticalAccuracy":-1},"precipitationChance":0.1,"symbolName":"sun.max","temperatureCelsius":21.5}],"yearlyReports":[]}"##

    @Test func encodedBytesMatchPreMoveDeclarations() throws {
        #expect(try SnapshotFixture.storeJSON(SnapshotFixture.make()) == Self.stored)
    }

    @Test func storedBytesDecodeAndReencodeUnchanged() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        var decoded = try decoder.decode(TaptionDataSnapshot.self, from: Data(Self.stored.utf8))
        // 읽을 때 권한 표를 모든 항목으로 채우는 것은 옮기기 전과 같은 동작이다.
        #expect(decoded.settings.permissions.count == PermissionFeature.allCases.count)
        #expect(decoded.settings.permissions[.location] == .authorized)
        #expect(decoded.settings.permissions.filter { $0.key != .location }.values.allSatisfy { $0 == .notDetermined })
        decoded.settings.permissions = [.location: .authorized]
        #expect(decoded == SnapshotFixture.make())
        #expect(try SnapshotFixture.storeJSON(decoded) == Self.stored)
    }

    /// 빠진 키는 빈 스냅샷의 값으로 채운다(예전 백업 호환).
    @Test func missingKeysFallBackToEmptySnapshot() throws {
        let decoded = try JSONDecoder().decode(TaptionDataSnapshot.self, from: Data("{}".utf8))
        #expect(decoded == .empty)
    }
}

/// 배열마다 한 항목씩 채운 스냅샷. 같은 코드를 옮기기 전 앱 선언으로 인코딩해 기대 JSON을 만들었다.
enum SnapshotFixture {
    static let start = Date(timeIntervalSince1970: 1_762_560_000)

    static func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }

    static func make() -> TaptionDataSnapshot {
        let span = TimeSpan(start: start, end: start.addingTimeInterval(1_800))
        let point = GeoPoint(latitude: 37.5, longitude: 127.25, altitude: 12.5, horizontalAccuracy: 5, verticalAccuracy: -1)
        // 기본 설정 전체를 담되, 실행 시각·언어·사전 순서에 따라 바뀌는 값은 고정한다.
        var settings = AppFeatureSettings.defaults
        // 기대 JSON을 만들 때의 기본 지도다. 뒤에 기본값이 바뀌어도(MDF1114A01) 저장 바이트 계약은 그대로여야 한다.
        settings.mapDisplayStyle = .mapLibreRPG
        settings.frequentPlaces = settings.frequentPlaces.enumerated().map { index, place in
            var place = place
            place.id = id(900 + index)
            place.name = "장소\(index)"
            place.radiusMeters = 120 // 저장된 바이트는 기본 반경이 120m이던 때의 것(PLR1112A01).
            place.createdAt = start
            place.updatedAt = start
            return place
        }
        settings.permissions = [.location: .authorized]
        settings.mapCategoryColors = ["movement": "#123456"]
        settings.suppressedActualIDs = [id(70)]
        settings.confirmedSleepSpans = [span]
        settings.registeredCarAudioNames = ["내 차"]
        settings.cloudResetAt = start
        return TaptionDataSnapshot(
            schemaVersion: 3,
            updatedAt: start.addingTimeInterval(60),
            plans: [PlanRecord(id: id(1), title: "회의", span: span, categoryID: "work", repeatRules: [],
                               createdAt: start, updatedAt: start)],
            actuals: [ActualRecord(id: id(2), planID: nil, title: "걷기", categoryID: "movement",
                                   startedAt: start, endedAt: start.addingTimeInterval(600), source: .motion,
                                   confidence: .medium, createdAt: start, behavior: "walking", evidence: ["steps"])],
            recordLinks: [RecordLink(id: id(3), fromNodeID: "plan:a", toNodeID: "actual:b", createdAt: start)],
            memos: [ActionMemo(id: id(4), planID: nil, targetID: "actual:b", categoryID: "movement",
                               occurredAt: start, mapPoint: point, isTimeless: false, kind: .idea, text: "메모",
                               attachments: [], isHighlightedInReview: true, createdAt: start, updatedAt: start)],
            stickers: [MapSticker(id: id(5), title: "별", memo: nil, placement: .map, point: point,
                                  occurredAt: start, createdAt: start, updatedAt: start)],
            categories: [CategoryDefinition(id: "work", name: "일", icon: .briefcase, lightHex: "#111111",
                                            darkHex: "#222222", actualHex: "#333333", sortOrder: 1)],
            photos: [PhotoMoment(id: "photo-1", capturedAt: start, pixelWidth: 4032, pixelHeight: 3024,
                                 isFavorite: true, isHiddenFromTimeline: false, location: point)],
            calendarEvents: [CalendarRecord(id: "evt", calendarID: "cal", title: "약속", span: span,
                                            isAllDay: false, calendarTitle: "개인", calendarColorHex: "#FF0000",
                                            sourceTitle: nil, timeZoneIdentifier: "Asia/Seoul", notes: "노트")],
            weather: [WeatherContext(id: id(6), observedAt: start, condition: "clear", symbolName: "sun.max",
                                     temperatureCelsius: 21.5, precipitationChance: 0.1, point: point)],
            places: [PlaceStay(id: id(7), placeKey: "home", displayName: "집", floor: 3, span: span,
                               confidence: .high, point: point, isConfirmed: true)],
            travel: [TravelSegment(id: id(8), mode: .walking, span: span, distanceMeters: 800,
                                   confidence: .low, evidence: ["gps"])],
            floorTransitions: [FloorTransition(id: id(9), placeKey: "home", fromFloor: 1, toFloor: 3,
                                               relativeAltitudeMeters: 6.5, span: span, confidence: .medium,
                                               evidence: ["altimeter"], floorEvidence: nil)],
            yearlyReports: [],
            settings: settings
        )
    }

    static func storeJSON(_ snapshot: TaptionDataSnapshot) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(snapshot), as: UTF8.self)
    }
}

/// PLR1112A01: 새로 등록하는 장소는 200m, 저장된 반경은 그대로.
@Test func newPlacesUseTwoHundredMetresAndStoredRadiusStays() throws {
    #expect(FrequentPlace(kind: .custom, name: "새 곳").radiusMeters == 200)
    let point = GeoPoint(latitude: 37.5, longitude: 127, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: -1)
    var unplaced = FrequentPlace(kind: .home, radiusMeters: 120)
    unplaced.setMapLocation(point)
    #expect(unplaced.radiusMeters == 200, "위치를 처음 정하는 옛 칸은 지금 기본값으로")
    var chosen = FrequentPlace(kind: .home, point: point, radiusMeters: 120)
    chosen.setMapLocation(GeoPoint(latitude: 37.6, longitude: 127, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: -1))
    #expect(chosen.radiusMeters == 120, "이미 등록한 장소의 반경은 바꾸지 않는다")
    var custom = FrequentPlace(kind: .home, radiusMeters: 80)
    custom.setMapLocation(point)
    #expect(custom.radiusMeters == 80)
    let old = try JSONDecoder().decode(FrequentPlace.self, from: JSONEncoder().encode(chosen))
    #expect(old.radiusMeters == 120)
}
