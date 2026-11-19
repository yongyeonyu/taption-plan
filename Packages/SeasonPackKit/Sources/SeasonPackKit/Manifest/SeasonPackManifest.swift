import Foundation

/// 시즌 팩 매니페스트 v1. 모르는 열쇠는 `Codable`이 그대로 넘기고, 모르는 `kind`는 문자열로 받아 두었다가
/// 쓰는 쪽(레지스트리·시나리오)이 감춘다. 필수 열쇠(`format`·`schema`·`id`·`version`·`event`·`assets`)가 없으면 디코딩이 던져 그 팩만 버려진다.
public struct SeasonPackManifest: Codable, Sendable, Equatable {
    public static let format = "bokki-season-pack"
    public static let supportedSchema = 1

    public var format: String
    public var schema: Int
    public var id: String
    public var version: Int
    public var requiresAppBuild: Int?
    public var priority: Int?
    public var event: Event
    public var assets: [Asset]
    public var slots: Slots?
    public var textSlots: [TextSlot]?
    public var menuIcons: [MenuIcon]?
    public var audio: [AudioTrack]?
    public var lyrics: [LyricTrack]?
    public var actors: [Actor]?
    public var interactions: [Interaction]?
    public var credits: [SeasonPackText]?

    public struct Event: Codable, Sendable, Equatable {
        public var id: String
        public var kind: String?
        public var announcementId: String?
        public var title: SeasonPackText?
        public var windows: [Window]
    }

    /// 월·일 기준 창. `year`가 있으면 그해만. `from` > `to`면 연말을 넘는 창. `rule`이 있으면 그 규칙이 정하는 하루.
    public struct Window: Codable, Sendable, Equatable {
        public struct MonthDay: Codable, Sendable, Equatable, Comparable {
            public var month: Int
            public var day: Int
            public init(month: Int, day: Int) { self.month = month; self.day = day }
            public static func < (a: MonthDay, b: MonthDay) -> Bool { (a.month, a.day) < (b.month, b.day) }
        }
        public struct Rule: Codable, Sendable, Equatable {
            public var kind: String
            public var month: Int?
            /// `Calendar` 요일(1 = 일요일 … 7 = 토요일).
            public var weekday: Int?
            /// 1…5, -1은 마지막.
            public var nth: Int?
        }
        public var from: MonthDay?
        public var to: MonthDay?
        public var year: Int?
        public var fromTime: String?
        public var toTime: String?
        public var rule: Rule?
    }

    public struct Asset: Codable, Sendable, Equatable {
        public var id: String
        public var path: String
        public var sha256: String
        public var bytes: Int
        public var kind: String
    }

    /// 한 칸에 놓는 PNG 한 장과 위치. 문자열 하나(`"accessory.santaHat"`)로도 쓸 수 있다.
    public struct Layer: Codable, Sendable, Equatable {
        public var asset: String
        public var anchor: String
        public var scale: Double
        public var offset: [Double]
        public var z: Int

        public init(asset: String, anchor: String = "head", scale: Double = 0.5, offset: [Double] = [0, 0], z: Int = 0) {
            self.asset = asset; self.anchor = anchor; self.scale = scale; self.offset = offset; self.z = z
        }

        public init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer().decode(String.self) {
                self.init(asset: single)
                return
            }
            let container = try decoder.container(keyedBy: Keys.self)
            self.init(
                asset: try container.decode(String.self, forKey: .asset),
                anchor: try container.decodeIfPresent(String.self, forKey: .anchor) ?? "head",
                scale: try container.decodeIfPresent(Double.self, forKey: .scale) ?? 0.5,
                offset: try container.decodeIfPresent([Double].self, forKey: .offset) ?? [0, 0],
                z: try container.decodeIfPresent(Int.self, forKey: .z) ?? 0
            )
        }

        enum Keys: String, CodingKey { case asset, anchor, scale, offset, z }
    }

    public struct Slots: Codable, Sendable, Equatable {
        public struct House: Codable, Sendable, Equatable {
            public struct Lights: Codable, Sendable, Equatable {
                public struct Blink: Codable, Sendable, Equatable {
                    public var periodMs: Int
                    public var fastPeriodMs: Int
                }
                public var on: String?
                public var off: String?
                public var blink: Blink?
            }
            /// 식목일처럼 하루 안에서 그림이 바뀌는 단계. `from`은 `HH:mm`.
            public struct Stage: Codable, Sendable, Equatable {
                public var from: String
                public var image: String
            }
            public var base: String
            public var lit: String?
            public var glow: String?
            public var lights: Lights?
            public var stages: [Stage]?
        }
        public struct Accessory: Codable, Sendable, Equatable {
            public var hat: Layer?
            public var scarf: Layer?
            public var ribbon: Layer?
        }
        public struct Bubbles: Codable, Sendable, Equatable {
            public var pool: [SeasonPackText]
            /// 말풍선에 노출할 메모 항목 id(구조만 열어 둠).
            public var memoItem: String?
        }
        public struct ShareCard: Codable, Sendable, Equatable {
            public var house: String?
            public var outfit: Bool?
        }
        public var house: House?
        public var outfit: [String: [Layer]]?
        public var accessory: Accessory?
        public var bubbles: Bubbles?
        public var shareCard: ShareCard?
    }

    public struct TextSlot: Codable, Sendable, Equatable {
        public struct Font: Codable, Sendable, Equatable {
            public var size: Double
            public var weight: String?
            public var design: String?
        }
        public var id: String
        public var rect: [Double]
        public var align: String?
        public var font: Font?
        public var color: String?
        /// `year`·`memo`·정적 문자열.
        public var content: String
        public var transition: String?
    }

    public struct MenuIcon: Codable, Sendable, Equatable {
        public struct Anchor: Codable, Sendable, Equatable {
            public var dx: Double
            public var dy: Double
        }
        public var id: String
        public var icon: String
        public var label: SeasonPackText?
        public var anchor: Anchor
        public var priority: Int?
        public var visibleFrom: String?
        public var visibleTo: String?
        public var menu: Menu
    }

    public struct Menu: Codable, Sendable, Equatable {
        public struct Section: Codable, Sendable, Equatable {
            public var title: SeasonPackText?
            public var items: [Item]
        }
        /// `kind`는 `text`·`memo`·`credits`·`link`·`toggle`. 모르는 값은 그 항목만 감춘다.
        public struct Item: Codable, Sendable, Equatable {
            public var id: String
            public var kind: String
            public var label: SeasonPackText?
            public var text: SeasonPackText?
            public var url: String?
            public var maxLength: Int?
            public var readOnlyAfter: String?
        }
        public var title: SeasonPackText?
        public var sections: [Section]
    }

    public struct AudioTrack: Codable, Sendable, Equatable {
        public struct License: Codable, Sendable, Equatable {
            public var title: String
            public var creator: String
            public var license: String
            public var source: String
            /// 라이선스 원문 파일(팩 안 자산 id, 선택).
            public var textAsset: String?
        }
        public var id: String
        public var asset: String
        public var durationMs: Int?
        public var loop: Bool?
        public var license: License
    }

    public struct LyricTrack: Codable, Sendable, Equatable {
        public struct Cue: Codable, Sendable, Equatable {
            public var atMs: Int
            public var text: SeasonPackText

            public init(atMs: Int, text: SeasonPackText) { self.atMs = atMs; self.text = text }

            public init(from decoder: Decoder) throws {
                let scalars = try decoder.singleValueContainer().decode([String: SeasonPackScalar].self)
                guard let at = scalars["atMs"]?.number else {
                    throw DecodingError.keyNotFound(AnyKey("atMs"), .init(codingPath: decoder.codingPath, debugDescription: "atMs"))
                }
                atMs = Int(at)
                text = SeasonPackText(scalars.filter { $0.key != "atMs" }.compactMapValues(\.text))
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: AnyKey.self)
                try container.encode(atMs, forKey: AnyKey("atMs"))
                for (key, value) in text.values { try container.encode(value, forKey: AnyKey(key)) }
            }
        }
        public var audio: String
        public var cues: [Cue]
    }

    public struct Actor: Codable, Sendable, Equatable {
        public struct Flight: Codable, Sendable, Equatable {
            public var seconds: Double
            public var start: [Double]
            public var end: [Double]
        }
        public struct Burst: Codable, Sendable, Equatable {
            public var images: [String]
            public var count: Int
        }
        public struct Tap: Codable, Sendable, Equatable {
            public var burst: Burst?
        }
        public var id: String
        public var image: String
        public var flight: Flight
        public var intervalSeconds: [Double]?
        public var tap: Tap?
        public var when: Condition?
    }

    public struct Condition: Codable, Sendable, Equatable {
        public var characterID: String?
    }

    public struct Interaction: Codable, Sendable, Equatable {
        public struct Action: Codable, Sendable, Equatable {
            public var kind: String
            public var seconds: Double?
            public var audio: String?
        }
        public var id: String
        public var target: String
        public var on: String
        public var when: Condition?
        public var actions: [Action]
    }
}

public extension SeasonPackManifest.Asset {
    var isImage: Bool { kind == "image" }
    var isAudio: Bool { kind == "audio" }
}

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
