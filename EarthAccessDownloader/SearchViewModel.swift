//
//  SearchViewModel.swift
//  EarthAccessDownloader
//

import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class SearchViewModel {
    static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Midnight UTC on the day of `date`.
    static func midnightUTC(of date: Date) -> Date {
        let components = utcCalendar.dateComponents([.year, .month, .day], from: date)
        return utcCalendar.date(from: components) ?? date
    }

    /// The day after `date`, at midnight UTC.
    private static func nextMidnightUTC(after date: Date) -> Date {
        utcCalendar.date(byAdding: .day, value: 1, to: midnightUTC(of: date)) ?? date
    }

    private static let filenameTimestampPattern = /(\d{4})(\d{2})(\d{2})[tT](\d{2})(\d{2})(\d{2})/

    /// Parses a granule/flightline filename timestamp like "20240914t172914" (always UTC).
    /// The timestamp may be the entire text or embedded in a full filename (e.g.
    /// "EMIT_L1B_RAD_001_20240914T172914_2425714_013.nc"). Nil if no such timestamp is found or
    /// it doesn't name a real date/time.
    static func parseFilenameTimestamp(_ text: String) -> Date? {
        guard let match = text.firstMatch(of: filenameTimestampPattern),
              let year = Int(match.1), let month = Int(match.2), let day = Int(match.3),
              let hour = Int(match.4), let minute = Int(match.5), let second = Int(match.6)
        else { return nil }
        var components = DateComponents()
        (components.year, components.month, components.day) = (year, month, day)
        (components.hour, components.minute, components.second) = (hour, minute, second)
        guard let date = utcCalendar.date(from: components) else { return nil }
        // Calendar normalizes out-of-range components (e.g. month 13) instead of failing, so
        // round-trip to confirm the parsed date is actually the date that was typed.
        let normalized = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard normalized.year == year, normalized.month == month, normalized.day == day,
              normalized.hour == hour, normalized.minute == minute, normalized.second == second
        else { return nil }
        return date
    }

    // Time window; ignored unless enabled. The start and end are chosen independently (the end
    // only has to be after the start); they default to one day starting a month ago, midnight UTC.
    var useTime = false
    var startDate = SearchViewModel.midnightUTC(of: Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now)
    var endDate = SearchViewModel.nextMidnightUTC(after: Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now)

    /// Whether the end of the time window is after its start.
    var isTimeWindowValid: Bool { endDate > startDate }

    /// Text entry for a granule/flightline filename timestamp (e.g. "20240914t172914"); applied
    /// via `applyFilenameTimestamp()`, not automatically as the user types.
    var filenameTimestampText = ""

    /// Sets the time window to one minute before/after the timestamp currently in
    /// `filenameTimestampText` and turns the filter on. Reports an error if the text doesn't
    /// contain a valid timestamp.
    func applyFilenameTimestamp() {
        guard let date = Self.parseFilenameTimestamp(filenameTimestampText) else {
            errorMessage = "\"\(filenameTimestampText)\" doesn't contain a recognizable timestamp (e.g. 20240914t172914)."
            return
        }
        errorMessage = nil
        useTime = true
        startDate = date.addingTimeInterval(-60)
        endDate = date.addingTimeInterval(60)
    }

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
    var showMap = false
    var isSelectingRegion = false  // the map is waiting for a rectangle to be dragged
    var mapScope = MapScope.all
    var mapBasemap = MapBasemap.standard
    var expandedFlightlines = Set<String>()  // ResultRow ids of open flightline disclosure groups
    var scrollTarget: String?  // row the list should scroll to
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
            return .point(lon: try number(lon, "Longitude (°E)", range: lonRange),
                          lat: try number(lat, "Latitude", range: latRange))
        case .box:
            let s = try number(llLat, "Lower-left latitude", range: latRange)
            let w = try number(llLon, "Lower-left longitude (°E)", range: lonRange)
            let n = try number(urLat, "Upper-right latitude", range: latRange)
            let e = try number(urLon, "Upper-right longitude (°E)", range: lonRange)
            guard n > s else { throw InputError(errorDescription: "Upper-right latitude must be north of lower-left.") }
            guard e > w else { throw InputError(errorDescription: "Upper-right longitude (°E) must be greater (further east) than lower-left.") }
            return .bbox(west: w, south: s, east: e, north: n)
        case .offset:
            let s = try number(llLat, "Lower-left latitude", range: latRange)
            let w = try number(llLon, "Lower-left longitude (°E)", range: lonRange)
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
        return String(format: "Upper right: %.5f°N, %.5f°E  (box W %.5f°E S %.5f°N E %.5f°E N %.5f°N)", n, e, w, s, e, n)
    }

    /// The longitude (degrees east; negative is west) at the center of the current location
    /// input, used to estimate a local time zone for display. Nil if the location fields don't parse.
    private var centerLongitude: Double? {
        guard let loc = try? location() else { return nil }
        switch loc {
        case let .point(lon, _): return lon
        case let .bbox(w, _, e, _): return (w + e) / 2
        }
    }

    /// An approximate local time zone at the current location, estimated from longitude
    /// (degrees east; 15° per hour of offset). Nil if no location is set.
    var approximateLocalTimeZone: TimeZone? {
        guard hasLocation, let lon = centerLongitude else { return nil }
        let hours = Int((lon / 15.0).rounded())
        return TimeZone(secondsFromGMT: hours * 3600)
    }

    /// `date` formatted in the approximate local time zone at the current location, for display
    /// alongside the UTC date/time pickers. Nil if no location is set.
    func localTimeDescription(for date: Date) -> String? {
        guard let zone = approximateLocalTimeZone else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm a"
        formatter.timeZone = zone
        let hours = zone.secondsFromGMT() / 3600
        return "\(formatter.string(from: date)) local (UTC\(hours >= 0 ? "+" : "")\(hours))"
    }

    // MARK: Search

    private static func isoUTC(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = utcCalendar.timeZone
        return formatter.string(from: date)
    }

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
        if useTime, !isTimeWindowValid {
            errorMessage = "End date/time must be after the start date/time."
            return
        }
        let products = Product.all.filter { selectedProducts.contains($0.id) }
        guard !products.isEmpty else { errorMessage = "Select at least one product."; return }

        var request: [String: Any] = [
            "products": products.map { ["short_name": $0.shortName, "version": $0.version, "label": $0.label] },
        ]
        if useTime {
            request["start"] = Self.isoUTC(startDate)
            request["end"] = Self.isoUTC(endDate)
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

    // MARK: Map

    /// Ids of the granules inside highlighted rows, for emphasis on the map.
    var highlightedGranuleIDs: Set<String> {
        func highlighted(_ row: ResultRow) -> [Granule] {
            if selectedGranules.contains(row.id) { return row.allGranules }
            if case let .flightline(_, segments) = row { return segments.flatMap(highlighted) }
            return []
        }
        return Set(ResultRow.rows(from: granules).flatMap(highlighted).map(\.id))
    }

    /// Sets the search area to a rectangle chosen on the map, switching the form to corner entry.
    func setRegion(west: Double, south: Double, east: Double, north: Double) {
        func text(_ v: Double) -> String { String(format: "%.5f", v) }
        mode = .box
        llLat = text(south)
        llLon = text(west)
        urLat = text(north)
        urLon = text(east)
        errorMessage = nil
    }

    /// The granules the map draws under the current scope: everything, the highlighted rows only,
    /// or every segment of the flightlines the highlighted rows belong to.
    var mapGranules: [Granule] {
        let highlighted = highlightedGranuleIDs
        switch mapScope {
        case .all:
            return granules
        case .selected:
            return granules.filter { highlighted.contains($0.id) }
        case .flightlines:
            let lines = Set(granules.filter { highlighted.contains($0.id) }.compactMap(\.flightlinePrefix))
            return granules.filter { highlighted.contains($0.id) || ($0.flightlinePrefix.map(lines.contains) ?? false) }
        }
    }

    /// Highlights the innermost list row containing `granuleID` (a flightline segment, not the
    /// whole flightline), expands its enclosing flightline so the row is visible, and scrolls to it.
    /// With `extend`, toggles the row within the current highlight instead of replacing it.
    func selectOnMap(granuleID: String, extend: Bool) {
        func path(in row: ResultRow) -> [String]? {
            guard row.allGranules.contains(where: { $0.id == granuleID }) else { return nil }
            if case let .flightline(_, segments) = row {
                return [row.id] + (segments.lazy.compactMap(path).first ?? [])
            }
            return [row.id]
        }
        guard let ids = ResultRow.rows(from: granules).lazy.compactMap(path).first, let id = ids.last else { return }
        expandedFlightlines.formUnion(ids.dropLast())
        if !extend { selectedGranules = [id] }
        else if selectedGranules.contains(id) { selectedGranules.remove(id) }
        else { selectedGranules.insert(id) }
        scrollTarget = id
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

    // MARK: Quicklook

    /// Scratch folder for downloaded quicklook images. It lives in the system temporary
    /// directory and is emptied at launch and quit, so the user never manages it.
    nonisolated static let quicklookDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("EarthAccessDownloader-quicklooks", isDirectory: true)

    static func cleanUpQuicklooks() {
        try? FileManager.default.removeItem(at: quicklookDirectory)
    }

    private var quicklookCache: [String: NSImage] = [:]

    /// Downloads (once) and returns the quicklook image of `granule`; for EMIT, its L1B radiance image.
    func quicklook(for granule: Granule) async throws -> NSImage {
        if let cached = quicklookCache[granule.quicklookID] { return cached }
        var request: [String: Any]
        if let acquisition = granule.emitAcquisition {
            request = ["emit_acquisition": acquisition]
        } else if let url = granule.browse {
            request = ["url": url]
        } else {
            throw HelperError(message: "This granule has no quicklook image.")
        }
        request["dest"] = Self.quicklookDirectory
            .appendingPathComponent(granule.quicklookID.replacingOccurrences(of: "/", with: "_"), isDirectory: true).path
        var path: String?
        for try await event in client.run("quicklook", request: request) {
            if case let .file(p) = event { path = p }
        }
        guard let path, let image = NSImage(contentsOfFile: path) else {
            throw HelperError(message: "Could not load the quicklook image.")
        }
        quicklookCache[granule.quicklookID] = image
        return image
    }

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
