//
//  SearchViewModel.swift
//  EarthAccessDownloader
//

import Foundation
import Observation

@Observable
@MainActor
final class SearchViewModel {
    // Time window; ignored unless enabled
    var useTime = false
    var startDate = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    var endDate = Date.now

    // Location
    var mode: LocationMode = .point
    var lat = ""
    var lon = ""
    var llLat = ""
    var llLon = ""
    var urLat = ""
    var urLon = ""
    var offsetEast = ""
    var offsetNorth = ""

    var selectedProducts = Product.defaultSelection

    var pythonPath: String = UserDefaults.standard.string(forKey: "pythonPath") ?? "python3" {
        didSet { UserDefaults.standard.set(pythonPath, forKey: "pythonPath") }
    }

    // Results
    private(set) var granules: [Granule] = []
    private(set) var truncated = false
    private(set) var isSearching = false
    private(set) var hasSearched = false
    var selection = Set<String>()  // file URLs
    var selectedGranules = Set<String>()  // rows highlighted in the list
    private(set) var isExtending = false
    private(set) var extendStatus: String?

    // Download
    var destination: URL? = UserDefaults.standard.url(forKey: "destination") {
        didSet { UserDefaults.standard.set(destination, forKey: "destination") }
    }
    var downloadRemotely: Bool = UserDefaults.standard.bool(forKey: "downloadRemotely") {
        didSet { UserDefaults.standard.set(downloadRemotely, forKey: "downloadRemotely") }
    }
    var sshHost: String = UserDefaults.standard.string(forKey: "sshHost") ?? "" {
        didSet { UserDefaults.standard.set(sshHost, forKey: "sshHost") }
    }
    var remoteDir: String = UserDefaults.standard.string(forKey: "remoteDir") ?? "" {
        didSet { UserDefaults.standard.set(remoteDir, forKey: "remoteDir") }
    }
    var remotePython: String = UserDefaults.standard.string(forKey: "remotePython") ?? "python3" {
        didSet { UserDefaults.standard.set(remotePython, forKey: "remotePython") }
    }
    private(set) var remoteCheck: String?
    private(set) var isDownloading = false
    private(set) var downloadStatus: String?
    private(set) var downloadFraction = 0.0

    var errorMessage: String?

    private var client: HelperClient { HelperClient(pythonPath: pythonPath) }

    private var remoteClient: HelperClient {
        HelperClient(pythonPath: pythonPath,
                     remote: RemoteConfig(host: sshHost.trimmingCharacters(in: .whitespaces), python: remotePython))
    }

    var canDownload: Bool {
        guard !selection.isEmpty, !isDownloading else { return false }
        return downloadRemotely
            ? !sshHost.trimmingCharacters(in: .whitespaces).isEmpty && !remoteDir.trimmingCharacters(in: .whitespaces).isEmpty
            : destination != nil
    }

    /// Where files will land, for display.
    var destinationDescription: String {
        downloadRemotely ? "\(sshHost.isEmpty ? "(no host)" : sshHost):\(remoteDir.isEmpty ? "(no folder)" : remoteDir)"
                         : destination?.path ?? "No folder chosen"
    }

    func testRemote() async {
        remoteCheck = "Connecting…"
        do {
            for try await event in remoteClient.run("check", request: [:]) {
                if case .ok = event { remoteCheck = "Connected; earthaccess is available on \(sshHost)." }
            }
        } catch {
            remoteCheck = "Failed: \(error.localizedDescription)"
        }
    }


    // MARK: Location

    struct InputError: LocalizedError {
        let errorDescription: String?
    }

    private func number(_ text: String, _ label: String, range: ClosedRange<Double>? = nil) throws -> Double {
        guard let v = Double(text.trimmingCharacters(in: .whitespaces)) else {
            throw InputError(errorDescription: "\(label) must be a number.")
        }
        if let range, !range.contains(v) {
            throw InputError(errorDescription: "\(label) must be between \(range.lowerBound) and \(range.upperBound).")
        }
        return v
    }

    /// The fields for the current mode; blank means location is not being used.
    private var activeLocationFields: [String] {
        switch mode {
        case .point: [lat, lon]
        case .box: [llLat, llLon, urLat, urLon]
        case .offset: [llLat, llLon, offsetEast, offsetNorth]
        }
    }

    var hasLocation: Bool {
        activeLocationFields.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    func location() throws -> SearchLocation {
        let latRange = -90.0...90.0, lonRange = -180.0...180.0
        switch mode {
        case .point:
            return .point(lon: try number(lon, "Longitude", range: lonRange),
                          lat: try number(lat, "Latitude", range: latRange))
        case .box:
            let s = try number(llLat, "Lower-left latitude", range: latRange)
            let w = try number(llLon, "Lower-left longitude", range: lonRange)
            let n = try number(urLat, "Upper-right latitude", range: latRange)
            let e = try number(urLon, "Upper-right longitude", range: lonRange)
            guard n > s else { throw InputError(errorDescription: "Upper-right latitude must be north of lower-left.") }
            guard e > w else { throw InputError(errorDescription: "Upper-right longitude must be east of lower-left.") }
            return .bbox(west: w, south: s, east: e, north: n)
        case .offset:
            let s = try number(llLat, "Lower-left latitude", range: latRange)
            let w = try number(llLon, "Lower-left longitude", range: lonRange)
            let dx = try number(offsetEast, "East offset (m)", range: 0...2_000_000)
            let dy = try number(offsetNorth, "North offset (m)", range: 0...2_000_000)
            let loc = SearchLocation.box(lowerLeftLat: s, lon: w, eastMeters: dx, northMeters: dy)
            if case let .bbox(_, _, e, n) = loc, n > 90 || e > 180 {
                throw InputError(errorDescription: "The offset runs past the pole or antimeridian.")
            }
            return loc
        }
    }

    /// Human-readable box derived from the inputs, shown under the form.
    var resolvedBoxDescription: String? {
        guard mode == .offset, hasLocation, case let .bbox(w, s, e, n)? = try? location() else { return nil }
        return String(format: "Upper right: %.5f°, %.5f°  (box W %.5f S %.5f E %.5f N %.5f)", n, e, w, s, e, n)
    }

    // MARK: Search

    func search() async {
        errorMessage = nil
        guard useTime || hasLocation else {
            errorMessage = "Enter a time window, a location, or both."
            return
        }
        var loc: SearchLocation?
        if hasLocation {
            do { loc = try location() } catch { errorMessage = error.localizedDescription; return }
        }
        if useTime, endDate < Calendar.current.startOfDay(for: startDate) {
            errorMessage = "End date must not be before the start date."
            return
        }
        let products = Product.all.filter { selectedProducts.contains($0.id) }
        guard !products.isEmpty else { errorMessage = "Select at least one product."; return }

        var request: [String: Any] = [
            "products": products.map { ["short_name": $0.shortName, "version": $0.version, "label": $0.label] },
        ]
        if useTime {
            request["start"] = Self.isoDay(startDate) + "T00:00:00Z"
            request["end"] = Self.isoDay(endDate) + "T23:59:59Z"
        }
        if let loc { request["location"] = loc.json }

        isSearching = true
        defer { isSearching = false; hasSearched = true }
        var found: [Granule] = []
        var wasTruncated = false
        do {
            for try await event in client.run("search", request: request) {
                if case let .granules(gs, truncated) = event {
                    found += gs
                    wasTruncated = wasTruncated || truncated
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        granules = found.sorted { ($0.start ?? "") > ($1.start ?? "") }
        truncated = wasTruncated
        selection = []
        selectedGranules = []
        extendStatus = nil
    }

    // MARK: Flightline extension

    /// Highlighted granules that belong to a flightline we can extend. A row counts as
    /// highlighted either directly (its own id is selected) or because a row nested inside it
    /// (a flightline segment) is selected.
    var extendableSelection: [Granule] {
        func selected(_ row: ResultRow) -> [Granule] {
            if selectedGranules.contains(row.id) { return row.allGranules }
            if case let .flightline(_, segments) = row { return segments.flatMap(selected) }
            return []
        }
        return ResultRow.rows(from: granules).flatMap(selected).filter { $0.flightlinePrefix != nil }
    }

    /// Adds the remaining segments of the flightlines of `targets` to the results.
    func extendFlightlines(of targets: [Granule]) async {
        var seen = Set<String>()
        let lines: [[String: String]] = targets.compactMap { g in
            guard let prefix = g.flightlinePrefix, let product = g.productInfo,
                  seen.insert(product.id + prefix).inserted else { return nil }
            return ["short_name": product.shortName, "version": product.version,
                    "label": product.label, "prefix": prefix]
        }
        guard !lines.isEmpty else { return }
        errorMessage = nil
        isExtending = true
        defer { isExtending = false }

        var found: [Granule] = []
        do {
            for try await event in client.run("extend", request: ["lines": lines]) {
                if case let .granules(gs, _) = event { found += gs }
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let known = Set(granules.map(\.id))
        let added = found.filter { !known.contains($0.id) }
        // Keep each flightline's segments together, newest flightline first.
        granules = (granules + added).sorted {
            ($0.flightlinePrefix ?? $0.start ?? "", $0.name) > ($1.flightlinePrefix ?? $1.start ?? "", $1.name)
        }
        extendStatus = added.isEmpty
            ? "No additional granules found for \(lines.count) flightline\(lines.count == 1 ? "" : "s")."
            : "Added \(added.count) granule\(added.count == 1 ? "" : "s") from \(lines.count) flightline\(lines.count == 1 ? "" : "s")."
    }

    private static func isoDay(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: Selection

    var allFiles: [GranuleFile] { granules.flatMap(\.files) }

    /// File kinds across all granules, e.g. "EMIT_L1B_RAD.nc", with how many files of each.
    var kinds: [(kind: String, count: Int)] {
        Dictionary(grouping: allFiles, by: \.kind)
            .map { (kind: $0.key, count: $0.value.count) }
            .sorted { $0.kind < $1.kind }
    }

    var selectedBytes: Int64 {
        allFiles.filter { selection.contains($0.id) }.reduce(0) { $0 + ($1.bytes ?? 0) }
    }

    func selectAll() { selection = Set(allFiles.map(\.id)) }
    func selectNone() { selection = [] }

    func setSelected(_ files: [GranuleFile], _ on: Bool) {
        if on { selection.formUnion(files.map(\.id)) } else { selection.subtract(files.map(\.id)) }
    }

    func isAllSelected(_ files: [GranuleFile]) -> Bool {
        !files.isEmpty && files.allSatisfy { selection.contains($0.id) }
    }

    func isAnySelected(_ files: [GranuleFile]) -> Bool {
        files.contains { selection.contains($0.id) }
    }

    func files(ofKind kind: String) -> [GranuleFile] { allFiles.filter { $0.kind == kind } }

    // MARK: Download

    func download() async {
        let destinationPath: String
        if downloadRemotely {
            guard canDownload else { errorMessage = "Enter an ssh host and a remote folder first."; return }
            destinationPath = remoteDir.trimmingCharacters(in: .whitespaces)
        } else {
            guard let destination else { errorMessage = "Choose a download folder first."; return }
            destinationPath = destination.path
        }
        let runner = downloadRemotely ? remoteClient : client
        let chosen = allFiles.filter { selection.contains($0.id) }
        guard !chosen.isEmpty else { return }
        errorMessage = nil
        isDownloading = true
        downloadFraction = 0
        downloadStatus = "Starting…"
        defer { isDownloading = false }

        var failures: [String] = []
        do {
            let request: [String: Any] = ["urls": chosen.map(\.url), "dest": destinationPath]
            for try await event in runner.run("download", request: request) {
                switch event {
                case let .progress(index, total, name):
                    downloadFraction = Double(index) / Double(max(total, 1))
                    downloadStatus = "Downloading \(index + 1) of \(total): \(name)"
                case let .fileError(name, message):
                    failures.append("\(name): \(message)")
                case .done:
                    downloadFraction = 1
                default: break
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            downloadStatus = nil
            return
        }
        if failures.isEmpty {
            downloadStatus = "Downloaded \(chosen.count) file\(chosen.count == 1 ? "" : "s") to \(destinationDescription)"
        } else {
            downloadStatus = nil
            errorMessage = "\(failures.count) of \(chosen.count) downloads failed:\n" + failures.joined(separator: "\n")
        }
    }
}
