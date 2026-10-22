//
//  Models.swift
//  EarthAccessDownloader
//

import Foundation

struct Product: Identifiable, Hashable {
    let label: String
    let shortName: String
    let version: String
    let instrument: String

    var id: String { shortName + "/" + version }

    static let all: [Product] = [
        Product(label: "EMIT L1B Radiance", shortName: "EMITL1BRAD", version: "002", instrument: "EMIT"),
        Product(label: "EMIT L2A Reflectance", shortName: "EMITL2ARFL", version: "002", instrument: "EMIT"),
        Product(label: "EMIT L2A Mask", shortName: "EMITL2AMASK", version: "003", instrument: "EMIT"),
        Product(label: "EMIT L2B Mineralogy", shortName: "EMITL2BMIN", version: "002", instrument: "EMIT"),
        Product(label: "EMIT L2B CH4 Enhancement", shortName: "EMITL2BCH4ENH", version: "003", instrument: "EMIT"),
        Product(label: "EMIT L2B CH4 Plume", shortName: "EMITL2BCH4PLM", version: "002", instrument: "EMIT"),
        Product(label: "EMIT L2B CO2 Enhancement", shortName: "EMITL2BCO2ENH", version: "003", instrument: "EMIT"),
        Product(label: "EMIT L2B CO2 Plume", shortName: "EMITL2BCO2PLM", version: "002", instrument: "EMIT"),
        Product(label: "AVIRIS-3 L1B Radiance", shortName: "AV3_L1B_RDN_2356", version: "1", instrument: "AVIRIS"),
        Product(label: "AVIRIS-3 L2A Reflectance", shortName: "AV3_L2A_RFL_2357", version: "1", instrument: "AVIRIS"),
        Product(label: "AVIRIS-3 L2B GHG", shortName: "AV3_L2B_GHG_2358", version: "1", instrument: "AVIRIS"),
        Product(label: "AVIRIS-5 L1B Radiance", shortName: "AV5_L1B_RDN_2483", version: "1", instrument: "AVIRIS"),
        Product(label: "AVIRIS-5 L2A Reflectance", shortName: "AV5_L2A_RFL_2484", version: "1", instrument: "AVIRIS"),
        Product(label: "AVIRIS-5 L2B GHG", shortName: "AV5_L2B_GHG_2485", version: "1", instrument: "AVIRIS"),
        Product(label: "AVIRIS-NG L1B Radiance", shortName: "AVIRIS-NG_L1B_radiance_2095", version: "1", instrument: "AVIRIS"),
        Product(label: "AVIRIS-NG L2 Reflectance", shortName: "AVIRIS-NG_L2_Reflectance_2110", version: "1", instrument: "AVIRIS"),
        Product(label: "AVIRIS-Classic L1B Radiance", shortName: "AVIRIS-Classic_L1B_Radiance_2155", version: "1", instrument: "AVIRIS"),
        Product(label: "AVIRIS-Classic L2 Reflectance", shortName: "AVIRIS-Classic_L2_Reflectance_2154", version: "1", instrument: "AVIRIS"),
    ]

    static let defaultSelection: Set<String> = [
        "EMITL1BRAD/002", "EMITL2ARFL/002", "AV3_L1B_RDN_2356/1", "AV3_L2A_RFL_2357/1",
    ]
}

struct GranuleFile: Identifiable, Hashable, Decodable {
    let url: String
    let name: String
    let kind: String
    let bytes: Int64?

    var id: String { url }
}

struct Granule: Identifiable, Hashable, Decodable {
    let id: String
    let name: String
    let product: String
    let start: String?
    let end: String?
    let files: [GranuleFile]

    /// Flightline id shared by all segments, e.g. "AV520250602t202631" for
    /// "AV520250602t202631_004_L1B_RDN_1". Nil for granules not named in segments.
    var flightlinePrefix: String? {
        name.firstMatch(of: /^((?:AV\d|ang|prm)\d{8}t\d{6})_\d{3}_/)
            .map { String($0.1) }
    }

    var productInfo: Product? { Product.all.first { $0.label == product } }
}

/// A top-level entry in the results list: a lone granule, or the segments of one flightline.
enum ResultRow: Identifiable {
    case granule(Granule)
    case flightline(prefix: String, product: String, granules: [Granule])

    var id: String {
        switch self {
        case let .granule(g): return g.id
        case let .flightline(prefix, product, _): return "line/\(product)/\(prefix)"
        }
    }

    /// Groups granules sharing a flightline (within one product) when there are at least two,
    /// keeping the order of first appearance.
    static func rows(from granules: [Granule]) -> [ResultRow] {
        var members: [String: [Granule]] = [:]
        for g in granules {
            if let prefix = g.flightlinePrefix { members["\(g.product)/\(prefix)", default: []].append(g) }
        }
        var emitted = Set<String>()
        var rows: [ResultRow] = []
        for g in granules {
            guard let prefix = g.flightlinePrefix, let group = members["\(g.product)/\(prefix)"], group.count > 1 else {
                rows.append(.granule(g))
                continue
            }
            if emitted.insert("\(g.product)/\(prefix)").inserted {
                rows.append(.flightline(prefix: prefix, product: g.product, granules: group.sorted { $0.name < $1.name }))
            }
        }
        return rows
    }
}

enum LocationMode: String, CaseIterable, Identifiable {
    case point = "Point"
    case box = "Corners"
    case offset = "Corner + offset"

    var id: String { rawValue }
}

/// A bounding box or point in the form earthaccess expects.
enum SearchLocation {
    case point(lon: Double, lat: Double)
    case bbox(west: Double, south: Double, east: Double, north: Double)

    var json: [String: Any] {
        switch self {
        case let .point(lon, lat): return ["point": [lon, lat]]
        case let .bbox(w, s, e, n): return ["bbox": [w, s, e, n]]
        }
    }

    /// Upper-right corner for a lower-left corner plus east/north offsets in meters.
    static func box(lowerLeftLat lat: Double, lon: Double, eastMeters: Double, northMeters: Double) -> SearchLocation {
        let metersPerDegreeLat = 111_320.0
        let north = lat + northMeters / metersPerDegreeLat
        let midLat = (lat + north) / 2
        let east = lon + eastMeters / (metersPerDegreeLat * cos(midLat * .pi / 180))
        return .bbox(west: lon, south: lat, east: east, north: north)
    }
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
