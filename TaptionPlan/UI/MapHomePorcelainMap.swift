import Foundation

/// 「백자」 지도 모양(PLN1111A01 제안 6, P1 백자와 흙). 땅과 길은 가라앉히고 내 경로가 가장 뚜렷하게 보이게 한다.
/// 고를 수 있는 모양으로만 더한다. 기본 지도는 판타지 지도 그대로다.
enum MapHomePorcelainMap {
    static let paper = "#F4EEDF"
    static let water = "#BFD6DA"
    static let waterLine = "#9DBEC6"
    static let landuse = "#EDE4D0"
    static let park = "#D5DDBE"
    static let wood = "#DDE2C8"
    static let building = "#E6DAC3"
    static let buildingLine = "#CDBFA3"
    static let roadCasing = "#FBF7EC"
    static let road = "#D9CDB4"
    static let roadMajor = "#D2C29C"
    static let highway = "#C9B994"
    static let rail = "#A89F90"

    /// 글자 대비: 지명/땅 8.75, 시설/땅 4.41, 물 글자/물 4.19.
    static let labels = MapHomeVectorLabels.Palette(
        place: "#4A4034", road: "#6E6252", poi: "#7A6C58", transit: "#4A5A66", water: "#3F6570", park: "#55603C",
        halo: paper, waterHalo: "#D6E5E7", parkHalo: paper
    )

    /// 땅 위: 숲·공원을 옅은 풀빛으로, 물가는 가는 선.
    static let landLayersJSON = #"""
    ,
    {
      "id": "porcelain-landcover",
      "type": "fill",
      "source": "openmaptiles",
      "source-layer": "landcover",
      "filter": ["in", "class", "wood", "grass", "scrub"],
      "paint": { "fill-color": "\#(wood)", "fill-opacity": 0.8 }
    },
    {
      "id": "porcelain-park",
      "type": "fill",
      "source": "openmaptiles",
      "source-layer": "park",
      "paint": { "fill-color": "\#(park)", "fill-opacity": 0.85 }
    },
    {
      "id": "porcelain-coastline",
      "type": "line",
      "source": "openmaptiles",
      "source-layer": "water",
      "layout": { "line-join": "round" },
      "paint": {
        "line-color": "\#(waterLine)",
        "line-opacity": 0.6,
        "line-width": ["interpolate", ["linear"], ["zoom"], 5, 0.3, 12, 0.7, 17, 1.2]
      }
    }
    """#

    /// 길 위: 큰길·고속도로를 한 단계씩만 진하게, 철도는 회갈색 가는 선, 물길.
    static let overlayLayersJSON = #"""
    ,
    {
      "id": "porcelain-building-outline",
      "type": "line",
      "source": "openmaptiles",
      "source-layer": "building",
      "minzoom": 14,
      "paint": {
        "line-color": "\#(buildingLine)",
        "line-opacity": 0.7,
        "line-width": ["interpolate", ["linear"], ["zoom"], 14, 0.3, 18, 0.9]
      }
    },
    {
      "id": "porcelain-road-major",
      "type": "line",
      "source": "openmaptiles",
      "source-layer": "transportation",
      "filter": ["all", ["==", "$type", "LineString"], ["in", "class", "trunk", "primary", "secondary"]],
      "layout": { "line-cap": "round", "line-join": "round" },
      "paint": {
        "line-color": "\#(roadMajor)",
        "line-width": ["interpolate", ["linear"], ["zoom"], 6, 0.4, 12, 1.4, 16, 3.6, 20, 9]
      }
    },
    {
      "id": "porcelain-road-highway",
      "type": "line",
      "source": "openmaptiles",
      "source-layer": "transportation",
      "filter": ["all", ["==", "$type", "LineString"], ["==", "class", "motorway"]],
      "layout": { "line-cap": "round", "line-join": "round" },
      "paint": {
        "line-color": "\#(highway)",
        "line-width": ["interpolate", ["linear"], ["zoom"], 5, 0.5, 12, 1.8, 16, 4.2, 20, 10]
      }
    },
    {
      "id": "porcelain-rail",
      "type": "line",
      "source": "openmaptiles",
      "source-layer": "transportation",
      "minzoom": 9,
      "filter": ["all", ["==", "$type", "LineString"], ["in", "class", "rail", "transit"]],
      "paint": {
        "line-color": "\#(rail)",
        "line-opacity": 0.8,
        "line-dasharray": [4, 2],
        "line-width": ["interpolate", ["linear"], ["zoom"], 9, 0.4, 14, 0.9, 18, 1.8]
      }
    },
    {
      "id": "porcelain-waterway",
      "type": "line",
      "source": "openmaptiles",
      "source-layer": "waterway",
      "minzoom": 8,
      "layout": { "line-cap": "round", "line-join": "round" },
      "paint": {
        "line-color": "\#(waterLine)",
        "line-opacity": 0.8,
        "line-width": ["interpolate", ["linear"], ["zoom"], 8, 0.4, 14, 1.4, 18, 3]
      }
    }
    """#
}
