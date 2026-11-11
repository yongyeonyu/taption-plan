import Foundation
import SwiftUI

enum MapHomeVectorStyle: String, CaseIterable, Sendable {
    case night
    case contrast
    case casual
    case rpg
    /// 수묵(INK1108A01): 한지 바탕·먹 도로·옅은 물. 색은 `MapHomeInkWash`에 모았다.
    case ink
    /// 백자(PLN1111A01): 색은 `MapHomePorcelainMap`에 모았다.
    case porcelain

    static let sourceURL = "https://tiles.openfreemap.org/planet"
    static let glyphsURL = "https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf"
    static let routeHex = MapHomeWBSTripStyle.actualRouteHex
    static let transitRouteHex = MapHomeWBSTripStyle.transitRouteHex

    var backgroundHex: String {
        switch self {
        case .night: "#05070D"
        case .contrast: "#FFFFFF"
        case .casual: TaptionSeasonStore.current.colors.map.background
        case .rpg: "#ECDFC0"
        case .ink: MapHomeInkWash.Map.paper
        case .porcelain: MapHomePorcelainMap.paper
        }
    }

    var waterHex: String {
        switch self {
        case .night: "#06264D"
        case .contrast: "#0057FF"
        case .casual: TaptionSeasonStore.current.colors.map.water
        case .rpg: "#86C3E0"
        case .ink: MapHomeInkWash.Map.water
        case .porcelain: MapHomePorcelainMap.water
        }
    }

    var landuseHex: String {
        switch self {
        case .night: "#0B1424"
        case .contrast: "#CDEBC0"
        case .casual: TaptionSeasonStore.current.colors.map.land
        case .rpg: "#DCCB9E"
        case .ink: MapHomeInkWash.Map.landuse
        case .porcelain: MapHomePorcelainMap.landuse
        }
    }

    var buildingHex: String {
        switch self {
        case .night: "#13223D"
        case .contrast: "#000000"
        case .casual: TaptionSeasonStore.current.colors.map.building
        case .rpg: "#CBAE7C"
        case .ink: MapHomeInkWash.Map.building
        case .porcelain: MapHomePorcelainMap.building
        }
    }

    var roadCasingHex: String {
        switch self {
        case .night: "#0A3A7A"
        case .contrast: "#000000"
        case .casual: "#FFFFFF"
        case .rpg: "#F3E7C8"
        case .ink: MapHomeInkWash.Map.roadCasing
        case .porcelain: MapHomePorcelainMap.roadCasing
        }
    }

    var roadHex: String {
        switch self {
        case .night: "#2FD6FF"
        case .contrast: "#D9BE6A"
        case .casual: TaptionSeasonStore.current.colors.map.road
        case .rpg: "#9A7B4A"
        case .ink: MapHomeInkWash.Map.road
        case .porcelain: MapHomePorcelainMap.road
        }
    }

    var labelPalette: MapHomeVectorLabels.Palette {
        switch self {
        case .night: .night
        case .contrast: .contrast
        case .casual: .season(TaptionSeasonStore.current.colors.map)
        case .rpg: .rpg
        case .ink: MapHomeInkWash.Map.labels
        case .porcelain: MapHomePorcelainMap.labels
        }
    }

    private var name: String {
        switch self {
        case .night: "Taption Vector Night"
        case .contrast: "Taption Vector Contrast"
        case .casual: "Taption Vector Casual"
        case .rpg: "Taption Vector RPG"
        case .ink: "Taption Vector Ink"
        case .porcelain: "Taption Vector Porcelain"
        }
    }

    private var casualLandLayersJSON: String {
        if self == .ink { return MapHomeInkWash.Map.landLayersJSON }
        if self == .porcelain { return MapHomePorcelainMap.landLayersJSON }
        if self == .rpg {
            return #"""
            ,
            {
              "id": "rpg-landcover",
              "type": "fill",
              "source": "openmaptiles",
              "source-layer": "landcover",
              "filter": ["in", "class", "wood", "grass", "scrub"],
              "paint": {
                "fill-color": "#B7C08A",
                "fill-opacity": 0.62
              }
            },
            {
              "id": "rpg-park",
              "type": "fill",
              "source": "openmaptiles",
              "source-layer": "park",
              "paint": {
                "fill-color": "#A6BE7C",
                "fill-opacity": 0.7
              }
            },
            {
              "id": "rpg-landuse-accent",
              "type": "fill",
              "source": "openmaptiles",
              "source-layer": "landuse",
              "filter": ["in", "class", "school", "university", "college", "kindergarten", "hospital", "cemetery", "commercial", "retail", "industrial", "railway", "pitch", "playground", "stadium", "track", "sports_centre"],
              "paint": {
                "fill-color": ["match", ["get", "class"],
                  ["school", "university", "college", "kindergarten"], "#F0D56E",
                  "hospital", "#E8A99B",
                  "cemetery", "#B7C99A",
                  ["commercial", "retail"], "#EBBE80",
                  ["industrial", "railway"], "#C9BBD6",
                  ["pitch", "playground", "stadium", "track", "sports_centre"], "#8FCB7A",
                  "#DCCB9E"],
                "fill-opacity": 0.72
              }
            },
            {
              "id": "rpg-landcover-extra",
              "type": "fill",
              "source": "openmaptiles",
              "source-layer": "landcover",
              "filter": ["in", "class", "sand", "wetland", "farmland", "rock", "ice"],
              "paint": {
                "fill-color": ["match", ["get", "class"],
                  "sand", "#F2DE9C",
                  "wetland", "#9ED0BE",
                  "farmland", "#DAD37E",
                  "ice", "#E4F0F6",
                  "#CFC3B2"],
                "fill-opacity": 0.66
              }
            },
            {
              "id": "rpg-coastline",
              "type": "line",
              "source": "openmaptiles",
              "source-layer": "water",
              "layout": { "line-cap": "round", "line-join": "round" },
              "paint": {
                "line-color": "#6E5B3E",
                "line-opacity": 0.55,
                "line-width": ["interpolate", ["linear"], ["zoom"], 5, 0.6, 12, 1.6, 16, 3.2]
              }
            }
            """#
        }
        guard self == .casual else { return "" }
        return #"""
        ,
        {
          "id": "casual-landcover",
          "type": "fill",
          "source": "openmaptiles",
          "source-layer": "landcover",
          "filter": ["in", "class", "wood", "grass", "scrub"],
          "paint": {
            "fill-color": "\#(TaptionSeasonStore.current.colors.map.cover)",
            "fill-opacity": 0.72
          }
        },
        {
          "id": "casual-park",
          "type": "fill",
          "source": "openmaptiles",
          "source-layer": "park",
          "paint": {
            "fill-color": "\#(TaptionSeasonStore.current.colors.map.park)",
            "fill-opacity": 0.84
          }
        }
        """#
    }

    private var casualBuildingLayersJSON: String {
        if self == .rpg {
            return #"""
            ,
            {
              "id": "rpg-building-tall",
              "type": "fill",
              "source": "openmaptiles",
              "source-layer": "building",
              "minzoom": 14,
              "filter": [">", ["to-number", ["get", "render_height"], 0], 25],
              "paint": {
                "fill-color": "#D98E6E",
                "fill-opacity": ["interpolate", ["linear"], ["zoom"], 14, 0.25, 17, 0.62]
              }
            },
            {
              "id": "rpg-building-outline",
              "type": "line",
              "source": "openmaptiles",
              "source-layer": "building",
              "minzoom": 13,
              "layout": { "line-cap": "round", "line-join": "round" },
              "paint": {
                "line-color": "#8A6A3E",
                "line-opacity": 0.5,
                "line-width": ["interpolate", ["linear"], ["zoom"], 13, 0.4, 17, 1.4]
              }
            }
            """#
        }
        guard self == .casual else { return "" }
        return #"""
        ,
        {
          "id": "casual-building-outline",
          "type": "line",
          "source": "openmaptiles",
          "source-layer": "building",
          "minzoom": 13,
          "layout": { "line-cap": "round", "line-join": "round" },
          "paint": {
            "line-color": "\#(TaptionSeasonStore.current.colors.map.buildingOutline)",
            "line-opacity": 0.46,
            "line-width": ["interpolate", ["linear"], ["zoom"], 13, 0.35, 17, 1.2]
          }
        }
        """#
    }

    private var casualOverlayLayersJSON: String {
        if self == .ink { return MapHomeInkWash.Map.overlayLayersJSON }
        if self == .porcelain { return MapHomePorcelainMap.overlayLayersJSON }
        if self == .rpg {
            return #"""
            ,
            {
              "id": "rpg-road-main",
              "type": "line",
              "source": "openmaptiles",
              "source-layer": "transportation",
              "filter": ["all", ["==", "$type", "LineString"], ["in", "class", "primary", "secondary"]],
              "layout": { "line-cap": "round", "line-join": "round" },
              "paint": {
                "line-color": "#E9C46A",
                "line-opacity": 0.95,
                "line-width": ["interpolate", ["linear"], ["zoom"], 7, 0.5, 11, 1.5, 16, 4.6, 20, 11]
              }
            },
            {
              "id": "rpg-road-highway",
              "type": "line",
              "source": "openmaptiles",
              "source-layer": "transportation",
              "filter": ["all", ["==", "$type", "LineString"], ["in", "class", "motorway", "trunk"]],
              "layout": { "line-cap": "round", "line-join": "round" },
              "paint": {
                "line-color": "#E8963A",
                "line-opacity": 0.96,
                "line-width": ["interpolate", ["linear"], ["zoom"], 5, 0.7, 11, 2.2, 16, 6.4, 20, 14]
              }
            },
            {
              "id": "rpg-rail",
              "type": "line",
              "source": "openmaptiles",
              "source-layer": "transportation",
              "minzoom": 9,
              "filter": ["all", ["==", "$type", "LineString"], ["==", "class", "rail"]],
              "layout": { "line-join": "round" },
              "paint": {
                "line-color": "#8E6FB5",
                "line-opacity": 0.85,
                "line-dasharray": [3, 2],
                "line-width": ["interpolate", ["linear"], ["zoom"], 9, 0.6, 14, 1.4, 18, 3]
              }
            },
            {
              "id": "rpg-waterway",
              "type": "line",
              "source": "openmaptiles",
              "source-layer": "waterway",
              "minzoom": 8,
              "layout": { "line-cap": "round", "line-join": "round" },
              "paint": {
                "line-color": "#5FA8CF",
                "line-opacity": 0.85,
                "line-width": ["interpolate", ["linear"], ["zoom"], 8, 0.6, 14, 2.6]
              }
            },
            {
              "id": "rpg-place-marker",
              "type": "circle",
              "source": "openmaptiles",
              "source-layer": "place",
              "minzoom": 5,
              "filter": ["in", "class", "city", "town", "village"],
              "paint": {
                "circle-color": "#C65D4D",
                "circle-radius": ["interpolate", ["linear"], ["zoom"], 5, 2.6, 10, 4.0, 14, 5.8],
                "circle-stroke-color": "#ECDFC0",
                "circle-stroke-width": 1.6
              }
            },
            {
              "id": "rpg-poi-marker",
              "type": "circle",
              "source": "openmaptiles",
              "source-layer": "poi",
              "minzoom": 13,
              "maxzoom": 14,
              "filter": ["in", "class", "cafe", "restaurant", "bakery", "shop", "supermarket"],
              "paint": {
                "circle-color": "#8A6A3E",
                "circle-opacity": 0.7,
                "circle-radius": 3.2,
                "circle-stroke-color": "#ECDFC0",
                "circle-stroke-width": 1
              }
            }
            """#
        }
        guard self == .casual else { return "" }
        return #"""
        ,
        {
          "id": "casual-waterway",
          "type": "line",
          "source": "openmaptiles",
          "source-layer": "waterway",
          "minzoom": 8,
          "layout": { "line-cap": "round", "line-join": "round" },
          "paint": {
            "line-color": "\#(TaptionSeasonStore.current.colors.map.waterway)",
            "line-opacity": 0.78,
            "line-width": ["interpolate", ["linear"], ["zoom"], 8, 0.6, 14, 2.8]
          }
        },
        {
          "id": "casual-place-marker",
          "type": "circle",
          "source": "openmaptiles",
          "source-layer": "place",
          "minzoom": 5,
          "filter": ["in", "class", "city", "town", "village"],
          "paint": {
            "circle-color": "\#(TaptionSeasonStore.current.colors.map.marker)",
            "circle-radius": ["interpolate", ["linear"], ["zoom"], 5, 2.4, 10, 3.8, 14, 5.5],
            "circle-stroke-color": "\#(TaptionSeasonStore.current.colors.map.halo)",
            "circle-stroke-width": 1.5
          }
        },
        {
          "id": "casual-poi-marker",
          "type": "circle",
          "source": "openmaptiles",
          "source-layer": "poi",
          "minzoom": 13,
          "maxzoom": 14,
          "filter": ["in", "class", "cafe", "restaurant", "bakery", "shop", "supermarket"],
          "paint": {
            "circle-color": "\#(TaptionSeasonStore.current.colors.map.poi)",
            "circle-opacity": 0.68,
            "circle-radius": 3.2,
            "circle-stroke-color": "\#(TaptionSeasonStore.current.colors.map.halo)",
            "circle-stroke-width": 1
          }
        }
        """#
    }

    var json: String {
        #"""
    {
      "version": 8,
      "name": "\#(name)",
      "sources": {
        "openmaptiles": {
          "type": "vector",
          "url": "https://tiles.openfreemap.org/planet",
          "attribution": "<a href=\"https://openfreemap.org/\">OpenFreeMap</a> <a href=\"https://www.openmaptiles.org/\">© OpenMapTiles</a> Data from <a href=\"https://www.openstreetmap.org/copyright\">OpenStreetMap</a>"
        }
      },
      "glyphs": "https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf",
      "sprite": "\#(MapHomeVectorLabels.spriteURL)",
      "layers": [
        {
          "id": "background",
          "type": "background",
          "paint": { "background-color": "\#(backgroundHex)" }
        },
        {
          "id": "water",
          "type": "fill",
          "source": "openmaptiles",
          "source-layer": "water",
          "paint": { "fill-color": "\#(waterHex)" }
        },
        {
          "id": "landuse",
          "type": "fill",
          "source": "openmaptiles",
          "source-layer": "landuse",
          "paint": {
            "fill-color": "\#(landuseHex)",
            "fill-opacity": 0.55
          }
        }\#(casualLandLayersJSON)
        ,
        {
          "id": "building",
          "type": "fill",
          "source": "openmaptiles",
          "source-layer": "building",
          "minzoom": 12,
          "paint": {
            "fill-color": "\#(buildingHex)",
            "fill-opacity": ["interpolate", ["linear"], ["zoom"], 12, 0.42, 16, 0.78]
          }
        }\#(casualBuildingLayersJSON)
        ,
        {
          "id": "road-casing",
          "type": "line",
          "source": "openmaptiles",
          "source-layer": "transportation",
          "filter": ["all", ["==", "$type", "LineString"], ["in", "class", "motorway", "trunk", "primary", "secondary", "tertiary", "minor", "service", "path", "track", "raceway"]],
          "layout": { "line-cap": "round", "line-join": "round" },
          "paint": {
            "line-color": "\#(roadCasingHex)",
            "line-opacity": 0.92,
            "line-width": ["interpolate", ["linear"], ["zoom"], 5, 0.6, 11, 1.8, 16, 6.4, 20, 15]
          }
        },
        {
          "id": "road",
          "type": "line",
          "source": "openmaptiles",
          "source-layer": "transportation",
          "filter": ["all", ["==", "$type", "LineString"], ["in", "class", "motorway", "trunk", "primary", "secondary", "tertiary", "minor", "service", "path", "track", "raceway"]],
          "layout": { "line-cap": "round", "line-join": "round" },
          "paint": {
            "line-color": "\#(roadHex)",
            "line-opacity": ["interpolate", ["linear"], ["zoom"], 5, 0.58, 12, 0.82, 17, 0.96],
            "line-width": ["interpolate", ["linear"], ["zoom"], 5, 0.3, 11, 1.0, 16, 3.5, 20, 10]
          }
        }\#(casualOverlayLayersJSON),
        \#(MapHomeVectorLabels.json(palette: labelPalette, iconOpacity: self == .ink ? MapHomeInkWash.Map.iconOpacity : 1))
      ]
    }
    """#
    }
}

extension MapDisplayStyle {
    var mapHomeVectorStyle: MapHomeVectorStyle? {
        switch self {
        case .mapLibreNight: .night
        case .mapLibreContrast: .contrast
        case .mapLibreCasual: .casual
        case .mapLibreRPG: .rpg
        case .mapLibreInk: .ink
        case .mapLibrePorcelain: .porcelain
        case .standard, .hybrid: nil
        }
    }
}
