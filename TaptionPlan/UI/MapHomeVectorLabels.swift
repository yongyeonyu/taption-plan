import Foundation

/// 벡터 지도의 글자·아이콘 층(MAP1104A01). 네 스타일이 같은 층을 쓰고 색 묶음만 다르다.
/// 뒤에 있는 층이 먼저 자리를 차지하므로 번지·작은 길 → 상호 → 정류장 → 큰 길 → 지명 → 역 순서로 쌓는다.
enum MapHomeVectorLabels {
    static let spriteURL = "https://tiles.openfreemap.org/sprites/ofm_f384/ofm"

    enum Tone: CaseIterable, Sendable {
        case place, road, poi, transit, water, park
    }

    struct Palette: Equatable, Sendable {
        var place, road, poi, transit, water, park: String
        var halo, waterHalo, parkHalo: String

        func text(_ tone: Tone) -> String {
            switch tone {
            case .place: place
            case .road: road
            case .poi: poi
            case .transit: transit
            case .water: water
            case .park: park
            }
        }

        func halo(_ tone: Tone) -> String {
            switch tone {
            case .water: waterHalo
            case .park: parkHalo
            case .place, .road, .poi, .transit: halo
            }
        }

        static func season(_ map: TaptionSeason.Map) -> Palette {
            Palette(
                place: map.label, road: map.roadLabel, poi: map.label, transit: "#1D5AA8",
                water: map.waterLabel, park: map.parkLabel,
                halo: map.halo, waterHalo: map.waterHalo, parkHalo: map.parkHalo
            )
        }

        static let night = Palette(
            place: "#EAF4FF", road: "#9FD8F0", poi: "#D6E2F5", transit: "#FFFFFF", water: "#7FC4FF", park: "#8FD9A8",
            halo: "#05070D", waterHalo: "#05070D", parkHalo: "#05070D"
        )
        static let contrast = Palette(
            place: "#000000", road: "#000000", poi: "#000000", transit: "#00318F", water: "#00318F", park: "#0B5D1E",
            halo: "#FFFFFF", waterHalo: "#FFFFFF", parkHalo: "#FFFFFF"
        )
        static let rpg = Palette(
            place: "#5A4A2E", road: "#6E5B3E", poi: "#5A4A2E", transit: "#1F4A6E", water: "#1F5673", park: "#4A5A22",
            halo: "#ECDFC0", waterHalo: "#D7EDF7", parkHalo: "#ECDFC0"
        )
    }

    struct Layer: Sendable {
        let id, sourceLayer: String
        let minzoom: Double
        var filter: String?
        let layout: String
        let tone: Tone
        var haloWidth = 1.6
    }

    /// 그 언어 이름 → 영어 → 현지 이름 순서로 쓴다. 한국어는 영어를 거치지 않는다.
    private static var nameFields: String {
        nameFields(languageCode: UITextPack.activeLanguageCode ?? (MapHomeLanguage.current == .english ? "en" : nil))
    }

    static func nameFields(languageCode code: String?) -> String {
        guard let code else { return #"["get", "name:ko"], ["get", "name"]"# }
        let base = code.split(separator: "-").first.map(String.init) ?? code
        let names = code == "zh-Hant" ? [code, base] : [base]
        return (base == "en" ? names : names + ["en"]).map { #"["get", "name:\#($0)"], "# }.joined() + #"["get", "name"]"#
    }

    private static var name: String { #"["coalesce", \#(nameFields)]"# }
    private static let regular = #"["Noto Sans Regular"]"#
    private static let bold = #"["Noto Sans Bold"]"#

    /// 스프라이트에 `<class>_11`이 있는 `poi` 분류. 없는 분류는 글자만 쓴다.
    static let spriteClasses = [
        "alcohol_shop", "aquarium", "art_gallery", "attraction", "bakery", "bank", "bar", "beer", "bicycle",
        "bicycle_rental", "butcher", "cafe", "campsite", "car", "castle", "cemetery", "cinema", "clothing_store",
        "college", "dentist", "doctors", "drinking_water", "embassy", "fast_food", "fire_station", "fuel", "garden",
        "gift", "golf", "grocery", "hairdresser", "harbor", "hospital", "ice_cream", "information", "laundry",
        "library", "lodging", "monument", "museum", "music", "park", "parking", "pharmacy", "picnic_site", "pitch",
        "place_of_worship", "playground", "police", "post", "prison", "school", "shelter", "shop", "stadium",
        "swimming", "telephone", "tennis", "theatre", "toilets", "town_hall", "veterinary", "waste_basket", "zoo",
    ]
    /// 이름이 다른 분류의 대체 아이콘.
    static let spriteAliases = [
        ("atm", "bank_11"), ("office", "suitcase_11"), ("recycling", "waste_basket_11"),
        ("sports_centre", "stadium_11"), ("theme_park", "amusement_park_11"),
    ]

    private static var poiIcon: String {
        let classes = spriteClasses.map { "\"\($0)\"" }.joined(separator: ", ")
        let aliases = spriteAliases.map { "\"\($0.0)\", \"\($0.1)\"" }.joined(separator: ", ")
        return #"["match", ["get", "class"], [\#(classes)], ["concat", ["get", "class"], "_11"], \#(aliases), ""]"#
    }

    private static let landmarkFilter = #"""
    ["any",
      ["match", ["get", "class"], ["hospital", "school", "college", "stadium", "museum", "library", "town_hall", "post", "police", "fire_station", "castle", "monument", "attraction", "theatre", "cinema", "place_of_worship", "lodging", "park", "theme_park", "zoo", "aquarium", "embassy"], true, false],
      ["match", ["get", "subclass"], ["mall", "department_store", "marketplace"], true, false]]
    """#
    private static let transitClasses = #"["railway", "bus", "entrance", "aerialway", "ferry_terminal"]"#
    private static let utilityClasses = #"["waste_basket", "recycling", "bicycle_parking", "bollard", "lift_gate", "drinking_water", "telephone", "shelter"]"#

    private static func pointLayout(icon: String, font: String = regular, size: String, maxWidth: Int = 7) -> String {
        #"""
        "text-field": \#(name),
        "text-font": \#(font),
        "text-size": \#(size),
        "text-max-width": \#(maxWidth),
        "text-anchor": "top",
        "text-offset": [0, 0.8],
        "text-padding": 2,
        "icon-image": \#(icon),
        "icon-padding": 1
        """#
    }

    private static func lineLayout(field: String = name, size: String) -> String {
        #"""
        "symbol-placement": "line",
        "text-field": \#(field),
        "text-font": \#(regular),
        "text-size": \#(size),
        "text-padding": 3,
        "text-max-angle": 30,
        "text-keep-upright": true
        """#
    }

    private static func areaLayout(font: String = regular, size: String, maxWidth: Int = 8) -> String {
        #"""
        "text-field": \#(name),
        "text-font": \#(font),
        "text-size": \#(size),
        "text-max-width": \#(maxWidth),
        "text-padding": 4
        """#
    }

    static var layers: [Layer] { [
        Layer(
            id: "label-housenumber", sourceLayer: "housenumber", minzoom: 17,
            layout: #"""
            "text-field": ["get", "housenumber"],
            "text-font": \#(regular),
            "text-size": 10,
            "text-max-width": 6,
            "text-padding": 2
            """#,
            tone: .road, haloWidth: 1.2
        ),
        Layer(
            id: "label-road-minor", sourceLayer: "transportation_name", minzoom: 14,
            filter: #"["!", ["match", ["get", "class"], ["motorway", "trunk", "primary", "secondary", "tertiary"], true, false]]"#,
            layout: lineLayout(size: #"["interpolate", ["linear"], ["zoom"], 14, 9, 18, 12]"#),
            tone: .road
        ),
        Layer(
            id: "label-waterway", sourceLayer: "waterway", minzoom: 11,
            filter: #"["has", "name"]"#,
            layout: lineLayout(size: #"["interpolate", ["linear"], ["zoom"], 11, 9, 16, 12]"#),
            tone: .water
        ),
        // 일반 상호: 확대할수록 타일 안 순위 기준을 넓히고, 18배율부터 모두 올린다. 이름 없는 시설은 17배율부터 아이콘만.
        Layer(
            id: "label-poi", sourceLayer: "poi", minzoom: 14,
            filter: #"""
            ["all",
              ["!", ["match", ["get", "class"], \#(transitClasses), true, false]],
              ["<=", ["to-number", ["get", "rank"], 0], ["step", ["zoom"], 6, 15, 30, 16, 100, 17, 500, 18, 1000000]],
              ["any", ["has", "name"], [">=", ["zoom"], 17]],
              ["any", ["!", ["match", ["get", "class"], \#(utilityClasses), true, false]], [">=", ["zoom"], 18]]]
            """#,
            layout: pointLayout(icon: poiIcon, size: #"["interpolate", ["linear"], ["zoom"], 14, 10, 18, 12]"#),
            tone: .poi
        ),
        Layer(
            id: "label-subway-entrance", sourceLayer: "poi", minzoom: 16,
            filter: #"["==", ["get", "class"], "entrance"]"#,
            layout: pointLayout(icon: #""entrance_11""#, size: "10"),
            tone: .transit
        ),
        Layer(
            id: "label-bus", sourceLayer: "poi", minzoom: 15,
            filter: #"["==", ["get", "class"], "bus"]"#,
            layout: pointLayout(icon: #""bus_11""#, size: #"["interpolate", ["linear"], ["zoom"], 15, 10, 18, 12]"#),
            tone: .transit
        ),
        // 병원·학교·박물관처럼 길을 찾을 때 기준이 되는 곳은 일찍 보여 준다.
        Layer(
            id: "label-poi-landmark", sourceLayer: "poi", minzoom: 12,
            filter: #"""
            ["all", \#(landmarkFilter),
              ["<=", ["to-number", ["get", "rank"], 0], ["step", ["zoom"], 2, 13, 6, 14, 20, 15, 60, 16, 1000000]]]
            """#,
            layout: pointLayout(icon: poiIcon, size: #"["interpolate", ["linear"], ["zoom"], 12, 10, 18, 13]"#),
            tone: .poi
        ),
        Layer(
            id: "label-road-major", sourceLayer: "transportation_name", minzoom: 11,
            filter: #"["match", ["get", "class"], ["motorway", "trunk", "primary", "secondary", "tertiary"], true, false]"#,
            layout: lineLayout(
                field: #"["coalesce", \#(nameFields), ["get", "ref"]]"#,
                size: #"["interpolate", ["linear"], ["zoom"], 11, 9, 16, 12, 18, 14]"#
            ),
            tone: .road, haloWidth: 1.8
        ),
        Layer(
            id: "label-park", sourceLayer: "park", minzoom: 12,
            layout: areaLayout(size: #"["interpolate", ["linear"], ["zoom"], 12, 9, 15, 12]"#),
            tone: .park
        ),
        Layer(
            id: "label-water", sourceLayer: "water_name", minzoom: 8,
            layout: areaLayout(size: #"["interpolate", ["linear"], ["zoom"], 8, 10, 14, 14]"#),
            tone: .water, haloWidth: 1.8
        ),
        Layer(
            id: "label-peak", sourceLayer: "mountain_peak", minzoom: 10,
            layout: pointLayout(icon: #""mountain_11""#, size: "11"),
            tone: .park
        ),
        // 한국의 동 이름은 `quarter`다.
        Layer(
            id: "label-place-small", sourceLayer: "place", minzoom: 12,
            filter: #"["match", ["get", "class"], ["quarter", "neighbourhood", "hamlet", "isolated_dwelling", "locality"], true, false]"#,
            layout: areaLayout(size: #"["interpolate", ["linear"], ["zoom"], 12, 10, 16, 14]"#),
            tone: .place, haloWidth: 2
        ),
        Layer(
            id: "label-place", sourceLayer: "place", minzoom: 2,
            filter: #"["!", ["match", ["get", "class"], ["quarter", "neighbourhood", "hamlet", "isolated_dwelling", "locality"], true, false]]"#,
            layout: areaLayout(size: #"["interpolate", ["linear"], ["zoom"], 5, 10, 10, 13, 14, 17]"#),
            tone: .place, haloWidth: 2.2
        ),
        Layer(
            id: "label-airport", sourceLayer: "aerodrome_label", minzoom: 9,
            layout: pointLayout(icon: #""airport_11""#, font: bold, size: "12"),
            tone: .transit
        ),
        Layer(
            id: "label-station", sourceLayer: "poi", minzoom: 11,
            filter: #"["match", ["get", "class"], ["railway", "aerialway", "ferry_terminal"], true, false]"#,
            layout: pointLayout(
                icon: #"""
                ["match", ["get", "class"], "aerialway", "aerialway_11", "ferry_terminal", "ferry_11",
                  ["match", ["get", "subclass"], "subway", "railway_metro_11", "tram_stop", "railway_light_11", "railway_11"]]
                """#,
                font: bold,
                size: #"["interpolate", ["linear"], ["zoom"], 11, 10, 15, 13, 18, 15]"#
            ),
            tone: .transit, haloWidth: 2
        ),
    ] }

    /// 레이어의 글자 식. 언어를 바꿀 때 타일을 다시 받지 않고 이 식만 바꾼다.
    static func textField(of layer: Layer) -> Any? {
        let object = try? JSONSerialization.jsonObject(with: Data("{\(layer.layout)}".utf8))
        return (object as? [String: Any])?["text-field"]
    }

    /// `iconOpacity`: 수묵 지도는 색 있는 시설 아이콘을 옅게 눌러 먹빛 화면을 지킨다.
    static func json(palette: Palette, iconOpacity: Double = 1) -> String {
        let iconPaint = iconOpacity < 1 ? #", "icon-opacity": \#(iconOpacity)"# : ""
        return layers.map { layer in
            let filter = layer.filter.map { "\"filter\": \($0)," } ?? ""
            return #"""
            {
              "id": "\#(layer.id)",
              "type": "symbol",
              "source": "openmaptiles",
              "source-layer": "\#(layer.sourceLayer)",
              "minzoom": \#(layer.minzoom),
              \#(filter)
              "layout": { \#(layer.layout) },
              "paint": {
                "text-color": "\#(palette.text(layer.tone))",
                "text-halo-color": "\#(palette.halo(layer.tone))",
                "text-halo-width": \#(layer.haloWidth)\#(iconPaint)
              }
            }
            """#
        }
        .joined(separator: ",\n")
    }
}
