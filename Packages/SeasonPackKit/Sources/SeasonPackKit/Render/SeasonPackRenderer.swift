import CoreGraphics
import Foundation
import ImageIO
import Synchronization

/// 동작 줄이기·저전력이면 움직이는 연출(점멸·비행)을 하지 않는다.
public struct SeasonPackMotionPolicy: Sendable, Equatable {
    public var reduceMotion: Bool
    public var lowPower: Bool
    public init(reduceMotion: Bool = false, lowPower: Bool = false) { self.reduceMotion = reduceMotion; self.lowPower = lowPower }
    public var isReduced: Bool { reduceMotion || lowPower }
}

public struct SeasonPackHouseState: Sendable, Equatable {
    public enum Blink: Sendable, Equatable {
        case none
        case slow(periodMs: Int)
        case fast(periodMs: Int)
    }
    public var baseAsset: String
    public var litAsset: String?
    public var glowAsset: String?
    public var isLit: Bool
    public var blink: Blink
}

/// 팩이 들고 온 슬롯을 지금 시각·환경에 맞는 값으로 푸는 순수 계산.
public enum SeasonPackRenderer {
    /// 집 그림. 아침~저녁 `stages`가 있으면 그 단계, 점등은 `lights.on`~`off`(일몰~일출) 사이. 점멸은 줄이기·저전력에서 멈추고 `lit` 정지 그림을 쓴다.
    public static func houseState(
        pack: SeasonPack, now: Date, windows: SeasonPackWindows, motion: SeasonPackMotionPolicy, fastUntil: Date? = nil
    ) -> SeasonPackHouseState? {
        guard let house = pack.manifest.slots?.house else { return nil }
        let calendar = windows.calendar
        var base = house.base
        if let stages = house.stages?.compactMap({ stage in SeasonPackDateParsing.hourMinute(stage.from).map { ($0.hour * 60 + $0.minute, stage.image) } }).sorted(by: { $0.0 < $1.0 }), !stages.isEmpty {
            let minutes = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
            base = stages.last { $0.0 <= minutes }?.1 ?? stages[0].1
        }
        let lit = house.lit != nil && isLit(house.lights, now: now, windows: windows)
        var blink = SeasonPackHouseState.Blink.none
        if lit, !motion.isReduced, let config = house.lights?.blink {
            blink = (fastUntil.map { $0 > now } ?? false) ? .fast(periodMs: config.fastPeriodMs) : .slow(periodMs: config.periodMs)
        }
        return SeasonPackHouseState(baseAsset: base, litAsset: house.lit, glowAsset: house.glow, isLit: lit, blink: blink)
    }

    /// `on`(켜는 시각)부터 `off`(끄는 시각)까지. 시각을 풀 수 없으면(좌표 없음) 켜지 않는다.
    public static func isLit(_ lights: SeasonPackManifest.Slots.House.Lights?, now: Date, windows: SeasonPackWindows) -> Bool {
        guard let lights, let on = lights.on, let off = lights.off else { return false }
        let today = windows.calendar.startOfDay(for: now)
        guard let onTime = windows.resolve(on, on: today, isEnd: false), let offTime = windows.resolve(off, on: today, isEnd: false) else { return false }
        // 켜는 시각이 끄는 시각보다 늦으면(일몰~다음 날 일출) 밤 구간, 아니면 낮 구간.
        return onTime > offTime ? (now >= onTime || now < offTime) : (now >= onTime && now < offTime)
    }

    /// 점멸 밝기(0.35…1). 시각만의 함수라 같은 순간에는 같은 값이다.
    public static func blinkLevel(_ blink: SeasonPackHouseState.Blink, at date: Date) -> Double {
        let period: Int
        switch blink {
        case .none: return 1
        case .slow(let ms), .fast(let ms): period = max(60, ms)
        }
        let phase = (date.timeIntervalSinceReferenceDate * 1000).truncatingRemainder(dividingBy: Double(period)) / Double(period)
        return 0.675 + 0.325 * cos(phase * 2 * .pi)
    }
}

/// 걸치는 장식 세 칸(모자·목도리·리본). 팩 값이 있는 칸만 덮고, 없으면 원래 값이 그대로 남는다 — 기간이 끝나면 `pack`이 nil이라 저절로 원복한다.
public struct SeasonPackAccessorySlots<Value: Sendable & Equatable>: Sendable, Equatable {
    public var hat: Value?
    public var scarf: Value?
    public var ribbon: Value?

    public init(hat: Value? = nil, scarf: Value? = nil, ribbon: Value? = nil) { self.hat = hat; self.scarf = scarf; self.ribbon = ribbon }

    public func overridden(by pack: SeasonPackAccessorySlots<Value>?) -> SeasonPackAccessorySlots<Value> {
        guard let pack else { return self }
        return SeasonPackAccessorySlots(hat: pack.hat ?? hat, scarf: pack.scarf ?? scarf, ribbon: pack.ribbon ?? ribbon)
    }
}

public extension SeasonPackManifest.Slots.Accessory {
    var layers: SeasonPackAccessorySlots<SeasonPackManifest.Layer> { SeasonPackAccessorySlots(hat: hat, scarf: scarf, ribbon: ribbon) }
}

/// 팩 PNG 한 장을 얹을 자리. 앵커는 캐릭터 그림 안의 비율 위치이고 `scale`은 그림 너비에 대한 비율, `offset`은 그림 크기에 대한 비율이다.
public struct SeasonPackLayerPlacement: Sendable, Equatable {
    public static let anchors: [String: CGPoint] = [
        "head": CGPoint(x: 0.5, y: 0.2), "body": CGPoint(x: 0.5, y: 0.62),
        "tail": CGPoint(x: 0.88, y: 0.72), "feet": CGPoint(x: 0.5, y: 0.94),
    ]

    public static func frame(for layer: SeasonPackManifest.Layer, imageSize: CGSize, in container: CGSize) -> CGRect {
        let anchor = anchors[layer.anchor] ?? anchors["head"]!
        let width = container.width * layer.scale
        let height = imageSize.width > 0 ? width * imageSize.height / imageSize.width : width
        let dx = layer.offset.first ?? 0, dy = layer.offset.count > 1 ? layer.offset[1] : 0
        let center = CGPoint(x: (anchor.x + dx) * container.width, y: (anchor.y + dy) * container.height)
        return CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }
}

public enum SeasonPackTextSlots {
    /// 글자 칸 내용: `year` → 그 해 숫자, `memo` → 메모 첫 줄(없으면 빈 글), 그 밖은 정적 문자열.
    public static func text(for slot: SeasonPackManifest.TextSlot, year: Int, memoLine: String?) -> String {
        switch slot.content {
        case "year": String(year)
        case "memo": memoLine ?? ""
        default: slot.content
        }
    }
}

/// 연도 롤링: 마지막으로 보여 준 해와 지금 해가 다르면 한 번 굴러 내려오고, 끝나면 지금 해를 기억한다.
public struct SeasonPackYearRoll: Sendable, Equatable {
    public var from: Int?
    public var to: Int
    public var needsRoll: Bool { from != nil && from != to }

    public static func plan(shownYear: Int?, currentYear: Int) -> SeasonPackYearRoll {
        SeasonPackYearRoll(from: shownYear, to: currentYear)
    }
}

/// 팩 그림 읽기. 한 번 읽은 그림은 팩 폴더·자산 id별로 쥐고 있어 렌더 중 디스크를 다시 읽지 않는다.
public final class SeasonPackImageCache: Sendable {
    public static let shared = SeasonPackImageCache()
    private let images = Mutex<[String: CGImage]>([:])

    public func image(pack: SeasonPack, asset: String) -> CGImage? {
        let key = "\(pack.directory.path)#\(asset)"
        if let hit = images.withLock({ $0[key] }) { return hit }
        guard let url = pack.assetURL(asset), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        images.withLock { $0[key] = image }
        return image
    }

    public func preload(pack: SeasonPack) {
        for asset in pack.manifest.assets where asset.isImage { _ = image(pack: pack, asset: asset.id) }
    }

    public func removeAll() { images.withLock { $0.removeAll() } }
}
