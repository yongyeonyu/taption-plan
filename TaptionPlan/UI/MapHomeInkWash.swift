import Foundation

/// 수묵 테마 색과 지도 레이어(INK1108A01, 대표 승인).
///
/// 한지 바탕·먹 글자·붉은 인주 강조 하나로 그린다. 다른 앱의 그림·이름은 쓰지 않고 앱 고유 색으로 다시 잡았다.
/// 앱 색 구성은 밝은 한지 하나다. 기기 다크 모드에서도 한지를 유지한다(기본 양피지 테마와 같은 규칙:
/// 테마가 `preferredColorScheme`을 정하므로 먹 글자가 한지 위에서 읽히는 조합을 그대로 둔다).
enum MapHomeInkWash {
    /// 6단 색상표: 배경(한지)·면·선·강조(인주)·보조 글자·글자(먹).
    /// 인주 #B8322A는 흰 글자 5.9:1, 면 위 5.3:1이고 보조 글자는 한지 위 5.7:1이다.
    static let uiHexes = ["#EFE6D2", "#F8F2E4", "#BFB39C", "#B8322A", "#5E574C", "#2B2925"]

    /// 하단 메뉴 스티커: 테두리·산호·꿀·벽돌·민트·장미·하늘·크림·코코아·평일.
    static let barHexes = [
        "#2B2925", "#B8322A", "#D8CDB6", "#8E3A2E", "#A7B2AC",
        "#C98B82", "#B4C0C5", "#F8F2E4", "#5E574C", "#8C8273",
    ]

    /// 도장 인주색. 테마 강조색과 같다.
    static let sealHex = "#B8322A"

    enum Map {
        static let paper = "#EFE6D2"
        /// 물은 한지보다 조금 차가운 회청색으로만 칠하고, 물가는 옅은 선으로 그린다.
        static let water = "#DCE1DD"
        static let waterLine = "#8C9BA3"
        static let landuse = "#E6DCC6"
        static let building = "#DDD2BC"
        static let roadCasing = "#F4EDDD"
        static let road = "#8A8276"
        static let ink = "#2B2925"
        /// 색 있는 시설 아이콘을 옅게 누른다.
        static let iconOpacity = 0.32

        static let labels = MapHomeVectorLabels.Palette(
            place: "#2B2925", road: "#5E574C", poi: "#5E574C", transit: "#3F4A52", water: "#5C6E78", park: "#4F5644",
            halo: paper, waterHalo: "#E3E6E0", parkHalo: paper
        )

        /// 땅 위 레이어: 숲·풀은 먹을 옅게 번진 면, 물가는 회청 선.
        static let landLayersJSON = #"""
        ,
        {
          "id": "ink-landcover",
          "type": "fill",
          "source": "openmaptiles",
          "source-layer": "landcover",
          "filter": ["in", "class", "wood", "grass", "scrub"],
          "paint": {
            "fill-color": "#D6D3C2",
            "fill-opacity": 0.5
          }
        },
        {
          "id": "ink-coastline",
          "type": "line",
          "source": "openmaptiles",
          "source-layer": "water",
          "layout": { "line-join": "round" },
          "paint": {
            "line-color": "\#(waterLine)",
            "line-opacity": 0.7,
            "line-width": ["interpolate", ["linear"], ["zoom"], 5, 0.4, 12, 0.9, 17, 1.6]
          }
        }
        """#

        /// 도로 위 레이어: 큰길만 가는 먹선으로 한 번 더 긋고, 물길은 회청 선.
        static let overlayLayersJSON = #"""
        ,
        {
          "id": "ink-road-major",
          "type": "line",
          "source": "openmaptiles",
          "source-layer": "transportation",
          "filter": ["all", ["==", "$type", "LineString"], ["in", "class", "motorway", "trunk", "primary", "secondary"]],
          "layout": { "line-cap": "round", "line-join": "round" },
          "paint": {
            "line-color": "\#(ink)",
            "line-opacity": 0.72,
            "line-width": ["interpolate", ["linear"], ["zoom"], 6, 0.3, 12, 0.8, 16, 1.6, 20, 3.2]
          }
        },
        {
          "id": "ink-waterway",
          "type": "line",
          "source": "openmaptiles",
          "source-layer": "waterway",
          "layout": { "line-cap": "round", "line-join": "round" },
          "paint": {
            "line-color": "\#(waterLine)",
            "line-opacity": 0.8,
            "line-width": ["interpolate", ["linear"], ["zoom"], 8, 0.3, 14, 1.0, 18, 2.4]
          }
        }
        """#
    }
}
