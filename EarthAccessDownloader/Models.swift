//
//  Models.swift
//  EarthAccessDownloader
//

import Foundation
import SwiftUI

struct Product: Identifiable, Hashable {
    let label: String
    let shortName: String
    let version: String
    let instrument: String

    var id: String { shortName + "/" + version }

    /// A finer-grained grouping than `instrument` for display: splits AVIRIS into its variants
    /// (AVIRIS-3, AVIRIS-5, AVIRIS-NG, AVIRIS-Classic) rather than lumping them together.
    var displayInstrument: String {
        label.split(separator: " ").first.map(String.init) ?? instrument
    }

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

    private static let timestampToken = /^\d{8}[Tt]\d{6}$/
    private static let flightIdToken = /^(?:AV\d|ang|prm|f)\d{6,8}[tT]\d{2,6}(?:p\d{2}r\d+)?$/
    private static let hashToken = /^[0-9a-f]{8}$/
    private static let versionToken = /^\d{3}$/

    private static func isIdentifying(_ token: Substring) -> Bool {
        token.wholeMatch(of: timestampToken) != nil || token.wholeMatch(of: flightIdToken) != nil
            || token.wholeMatch(of: hashToken) != nil || token.wholeMatch(of: versionToken) != nil
    }

    /// A label identifying the physical acquisition independent of which product/level it is,
    /// e.g. "EMIT_002_20220828T174405" or "AV520250602t202631_004". Granules from different
    /// products that share this label describe the same acquisition and can be shown together.
    /// Built by keeping only the tokens of `name` that identify the acquisition itself
    /// (version, timestamp, flight id, hash) and dropping the product/level-specific ones,
    /// mirroring the filename-kind stripping done in earthaccess_helper.py's `file_kind`.
    var collectionLabel: String? {
        let tokens = name.split(separator: "_")
        guard let first = tokens.first else { return nil }
        let identifying = tokens.filter(Self.isIdentifying)
        guard !identifying.isEmpty else { return nil }
        let joined = identifying.joined(separator: "_")
        return Self.isIdentifying(first) ? joined : "\(first)_\(joined)"
    }

    var productInfo: Product? { Product.all.first { $0.label == product } }

    var instrument: String { productInfo?.instrument ?? "Other" }

    /// The finer-grained grouping used for display; see `Product.displayInstrument`.
    var displayInstrument: String { productInfo?.displayInstrument ?? instrument }
}

/// A top-level entry in the results list: a lone granule, several products' granules for the
/// same acquisition (e.g. EMIT L1B + L2A for one overflight), or the segments of one flightline
/// (each segment itself a lone granule or a same-acquisition collection).
enum ResultRow: Identifiable {
    case granule(Granule)
    case collection(label: String, granules: [Granule])
    indirect case flightline(prefix: String, segments: [ResultRow])

    var id: String {
        switch self {
        case let .granule(g): return g.id
        case let .collection(label, _): return "col/\(label)"
        case let .flightline(prefix, _): return "line/\(prefix)"
        }
    }

    var instrument: String {
        switch self {
        case let .granule(g): return g.displayInstrument
        case let .collection(_, granules): return granules.first?.displayInstrument ?? "Other"
        case let .flightline(_, segments): return segments.first?.instrument ?? "Other"
        }
    }

    /// Sort key within an instrument group: a flightline/collection sorts by its label, a lone granule by its name.
    private var sortKey: String {
        switch self {
        case let .granule(g): return g.name
        case let .collection(label, _): return label
        case let .flightline(prefix, _): return prefix
        }
    }

    /// The flightline prefix shared by a row's granules, if any; used to group segments together.
    private var flightlinePrefix: String? {
        switch self {
        case let .granule(g): return g.flightlinePrefix
        case let .collection(_, granules): return granules.first?.flightlinePrefix
        case .flightline: return nil
        }
    }

    /// All granules contained in this row, for selection, file listing, and flightline extension.
    var allGranules: [Granule] {
        switch self {
        case let .granule(g): return [g]
        case let .collection(_, granules): return granules
        case let .flightline(_, segments): return segments.flatMap(\.allGranules)
        }
    }

    /// Groups granules describing the same acquisition (across products) into collections, then
    /// groups the resulting rows sharing a flightline (across segments) into flightlines.
    static func rows(from granules: [Granule]) -> [ResultRow] {
        var acquisitionMembers: [String: [Granule]] = [:]
        for g in granules {
            acquisitionMembers[g.collectionLabel ?? g.id, default: []].append(g)
        }
        var emittedAcquisitions = Set<String>()
        var acquisitionRows: [ResultRow] = []
        for g in granules {
            let key = g.collectionLabel ?? g.id
            guard emittedAcquisitions.insert(key).inserted else { continue }
            let group = acquisitionMembers[key]!
            acquisitionRows.append(group.count > 1
                ? .collection(label: key, granules: group.sorted { $0.product < $1.product })
                : .granule(group[0]))
        }

        var flightlineMembers: [String: [ResultRow]] = [:]
        for row in acquisitionRows {
            if let prefix = row.flightlinePrefix { flightlineMembers[prefix, default: []].append(row) }
        }
        var emittedFlightlines = Set<String>()
        var rows: [ResultRow] = []
        for row in acquisitionRows {
            guard let prefix = row.flightlinePrefix,
                  let group = flightlineMembers[prefix], group.count > 1 else {
                rows.append(row)
                continue
            }
            if emittedFlightlines.insert(prefix).inserted {
                rows.append(.flightline(prefix: prefix, segments: group.sorted { $0.sortKey < $1.sortKey }))
            }
        }
        return rows
    }

    /// Rows grouped by instrument (alphabetically), sorted by name within each group.
    static func groupedByInstrument(from granules: [Granule]) -> [(instrument: String, rows: [ResultRow])] {
        let grouped = Dictionary(grouping: rows(from: granules), by: \.instrument)
        return grouped.keys.sorted().map { key in
            (instrument: key, rows: grouped[key]!.sorted { $0.sortKey < $1.sortKey })
        }
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

extension String {
    private static let instrumentColorPalette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .brown, .indigo]

    /// A display color for a display-instrument name, assigned by alphabetical position among
    /// all known display-instruments so each one is stable and distinct across runs.
    var instrumentColor: Color {
        let instruments = Set(Product.all.map(\.displayInstrument)).union([self]).sorted()
        let index = instruments.firstIndex(of: self) ?? 0
        return Self.instrumentColorPalette[index % Self.instrumentColorPalette.count]
    }
}
