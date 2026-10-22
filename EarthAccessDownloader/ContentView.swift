//
//  ContentView.swift
//  EarthAccessDownloader
//
//  Created by Jay Fahlen on 10/21/26.
//

import AppKit
import SwiftUI

struct ContentView: View {
    @State private var model = SearchViewModel()

    var body: some View {
        HSplitView {
            SearchForm(model: model)
                .frame(minWidth: 320, idealWidth: 340, maxWidth: 420, maxHeight: .infinity)
            ResultsView(model: model)
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 860, maxWidth: .infinity, minHeight: 720, maxHeight: .infinity)
    }
}

// MARK: - Search form

private struct SearchForm: View {
    @Bindable var model: SearchViewModel

    var body: some View {
        Form {
            Section {
                Toggle("Filter by time window", isOn: $model.useTime)
                DatePicker("From", selection: $model.startDate, displayedComponents: .date)
                    .disabled(!model.useTime)
                DatePicker("To", selection: $model.endDate, displayedComponents: .date)
                    .disabled(!model.useTime)
            } header: { Text("Time window") }

            Section("Location (leave blank to ignore)") {
                Picker("Mode", selection: $model.mode) {
                    ForEach(LocationMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch model.mode {
                case .point:
                    CoordField("Latitude", $model.lat)
                    CoordField("Longitude", $model.lon)
                case .box:
                    CoordField("Lower-left lat", $model.llLat)
                    CoordField("Lower-left lon", $model.llLon)
                    CoordField("Upper-right lat", $model.urLat)
                    CoordField("Upper-right lon", $model.urLon)
                case .offset:
                    CoordField("Lower-left lat", $model.llLat)
                    CoordField("Lower-left lon", $model.llLon)
                    CoordField("East offset (m)", $model.offsetEast, prompt: "meters")
                    CoordField("North offset (m)", $model.offsetNorth, prompt: "meters")
                    if let text = model.resolvedBoxDescription {
                        Text(text).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Products") {
                ForEach(["EMIT", "AVIRIS"], id: \.self) { instrument in
                    DisclosureGroup(instrument) {
                        ForEach(Product.all.filter { $0.instrument == instrument }) { product in
                            Toggle(product.label, isOn: Binding(
                                get: { model.selectedProducts.contains(product.id) },
                                set: { on in
                                    if on { model.selectedProducts.insert(product.id) }
                                    else { model.selectedProducts.remove(product.id) }
                                }))
                        }
                    }
                }
            }

            Section("Download") {
                Picker("Download on", selection: $model.downloadRemotely) {
                    Text("This Mac").tag(false)
                    Text("Remote (ssh)").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if model.downloadRemotely {
                    TextField("Host", text: $model.sshHost, prompt: Text("user@host or ssh alias"))
                    TextField("Folder", text: $model.remoteDir, prompt: Text("remote folder, e.g. ~/data"))
                    TextField("Python", text: $model.remotePython, prompt: Text("remote python3"))
                    HStack {
                        Button("Test Connection") { Task { await model.testRemote() } }
                            .disabled(model.sshHost.trimmingCharacters(in: .whitespaces).isEmpty)
                        if let check = model.remoteCheck {
                            Text(check).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                DisclosureGroup("Local Python (needs earthaccess installed)") {
                    TextField("Python", text: $model.pythonPath, prompt: Text("python3"))
                        .labelsHidden()
                }
            }

        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    Task { await model.search() }
                } label: {
                    Text("Search").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isSearching)
                if model.isSearching { ProgressView().controlSize(.small) }
            }
            .padding([.horizontal, .bottom], 12)
        }
    }
}

private struct CoordField: View {
    let label: String
    let prompt: String
    @Binding var text: String

    init(_ label: String, _ text: Binding<String>, prompt: String = "decimal degrees") {
        self.label = label
        self.prompt = prompt
        _text = text
    }

    var body: some View {
        TextField(label, text: $text, prompt: Text(prompt))
            .multilineTextAlignment(.trailing)
    }
}

// MARK: - Results

private struct ResultsView: View {
    @Bindable var model: SearchViewModel

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.red.opacity(0.08))
            }
            if model.granules.isEmpty {
                ContentUnavailableView(
                    model.hasSearched ? "No matching granules" : "Search for EMIT or AVIRIS data",
                    systemImage: model.hasSearched ? "tray" : "magnifyingglass",
                    description: Text(model.hasSearched
                        ? "Try a wider time window or location, or more products."
                        : "Pick a time window and location, then press Search."))
            } else {
                SelectionBar(model: model)
                if let status = model.extendStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding([.horizontal, .bottom], 8)
                }
                Divider()
                List(selection: $model.selectedGranules) {
                    ForEach(ResultRow.groupedByInstrument(from: model.granules), id: \.instrument) { group in
                        Section {
                            ForEach(group.rows) { row in
                                ResultRowView(model: model, row: row, accent: group.instrument.instrumentColor)
                            }
                        } header: {
                            Text(group.instrument)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(group.instrument.instrumentColor)
                        }
                    }
                }
            }
            Divider()
            DownloadBar(model: model)
        }
    }
}

private struct SelectionBar: View {
    @Bindable var model: SearchViewModel

    var body: some View {
        HStack {
            Text("\(model.granules.count) granule\(model.granules.count == 1 ? "" : "s")"
                 + (model.truncated ? " (limit reached; narrow your search)" : ""))
                .font(.headline)
            if model.isExtending { ProgressView().controlSize(.small) }
            Spacer()
            Button("Extend Flightline") {
                Task { await model.extendFlightlines(of: model.extendableSelection) }
            }
            .disabled(model.extendableSelection.isEmpty || model.isExtending)
            .help("Find the other segments of the flightlines of the highlighted granules (AVIRIS-3/5)")
            Button("Select All Files") { model.selectAll() }
            Button("Select None") { model.selectNone() }
            Menu("Select by Type") {
                ForEach(model.kinds, id: \.kind) { item in
                    let files = model.files(ofKind: item.kind)
                    let all = model.isAllSelected(files)
                    Button {
                        model.setSelected(files, !all)
                    } label: {
                        Text("\(all ? "✓ " : "")\(item.kind) (\(item.count))")
                    }
                }
            }
            .fixedSize()
        }
        .padding(8)
    }
}

/// Dispatches a `ResultRow` to the view that renders it, so granules, same-acquisition
/// collections, and flightlines (made of either) all get consistent selection, extend-flightline,
/// and bulk select/deselect behavior.
private struct ResultRowView: View {
    @Bindable var model: SearchViewModel
    let row: ResultRow
    let accent: Color

    var body: some View {
        switch row {
        case let .granule(granule):
            GranuleRow(model: model, granule: granule, accent: accent).tag(row.id)
        case let .collection(label, granules):
            CollectionRow(model: model, label: label, granules: granules, accent: accent).tag(row.id)
        case let .flightline(prefix, segments):
            FlightlineRow(model: model, prefix: prefix, segments: segments, accent: accent).tag(row.id)
        }
    }
}

/// A row's leading controls: a tri-state select-all toggle and an icon.
private struct RowHeader: View {
    let isAllSelected: Bool
    let isAnySelected: Bool
    let icon: String
    let accent: Color
    let onToggle: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { isAllSelected }, set: onToggle)) { EmptyView() }
            .toggleStyle(TriStateCheckboxStyle(mixed: !isAllSelected && isAnySelected))
        Image(systemName: icon).foregroundStyle(accent)
    }
}

/// A row's trailing controls: optional "find more segments" button, then All/None.
private struct RowActions: View {
    @Bindable var model: SearchViewModel
    let granules: [Granule]
    let files: [GranuleFile]
    let flightlineHelp: String

    var body: some View {
        if granules.contains(where: { $0.flightlinePrefix != nil }) {
            Button("Flightline") {
                Task { await model.extendFlightlines(of: granules) }
            }
            .buttonStyle(.borderless)
            .disabled(model.isExtending)
            .help(flightlineHelp)
        }
        Button("All") { model.setSelected(files, true) }
            .buttonStyle(.borderless)
            .help("Select all files here")
        Button("None") { model.setSelected(files, false) }
            .buttonStyle(.borderless)
            .help("Deselect all files here")
    }
}

private struct FlightlineRow: View {
    @Bindable var model: SearchViewModel
    let prefix: String
    let segments: [ResultRow]
    let accent: Color
    @State private var expanded = false

    private var granules: [Granule] { segments.flatMap(\.allGranules) }
    private var files: [GranuleFile] { granules.flatMap(\.files) }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(segments) { segment in
                ResultRowView(model: model, row: segment, accent: accent)
            }
        } label: {
            HStack {
                RowHeader(isAllSelected: model.isAllSelected(files), isAnySelected: model.isAnySelected(files),
                          icon: "airplane", accent: accent) { model.setSelected(files, $0) }
                VStack(alignment: .leading) {
                    Text("Flightline \(prefix)").font(.body.weight(.semibold)).foregroundStyle(accent).textSelection(.enabled)
                    Text("\(segments.count) segments · \(files.count) files")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                RowActions(model: model, granules: granules, files: files,
                           flightlineHelp: "Find additional segments of this flightline")
            }
        }
    }
}

/// Combines the granules of several products that describe the same acquisition
/// (e.g. EMIT L1B Radiance + L2A Reflectance for one overflight) into a flat file list.
private struct CollectionRow: View {
    @Bindable var model: SearchViewModel
    let label: String
    let granules: [Granule]
    let accent: Color
    @State private var expanded = false

    private var files: [GranuleFile] { granules.flatMap(\.files) }

    private func product(of file: GranuleFile) -> String {
        granules.first { $0.files.contains(file) }?.product ?? ""
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(files) { file in
                HStack {
                    Toggle(isOn: Binding(
                        get: { model.selection.contains(file.id) },
                        set: { model.setSelected([file], $0) }
                    )) {
                        Text(file.name).textSelection(.enabled)
                    }
                    Spacer()
                    Text(product(of: file)).font(.caption).foregroundStyle(.secondary)
                    Text(file.kind).font(.caption).foregroundStyle(.secondary)
                    if let bytes = file.bytes {
                        Text(formatBytes(bytes))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .trailing)
                    }
                }
            }
        } label: {
            HStack {
                RowHeader(isAllSelected: model.isAllSelected(files), isAnySelected: model.isAnySelected(files),
                          icon: "square.stack.3d.up", accent: accent) { model.setSelected(files, $0) }
                VStack(alignment: .leading) {
                    Text(label).font(.body.weight(.semibold)).foregroundStyle(accent).textSelection(.enabled)
                    Text("\(granules.map(\.product).sorted().joined(separator: " · ")) · \(files.count) files")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                RowActions(model: model, granules: granules, files: files,
                           flightlineHelp: "Add the other segments of this collection's flightline")
            }
        }
    }
}

private struct GranuleRow: View {
    @Bindable var model: SearchViewModel
    let granule: Granule
    let accent: Color
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(granule.files) { file in
                HStack {
                    Toggle(isOn: Binding(
                        get: { model.selection.contains(file.id) },
                        set: { model.setSelected([file], $0) }
                    )) {
                        Text(file.name).textSelection(.enabled)
                    }
                    Spacer()
                    Text(file.kind).font(.caption).foregroundStyle(.secondary)
                    if let bytes = file.bytes {
                        Text(formatBytes(bytes))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .trailing)
                    }
                }
            }
        } label: {
            HStack {
                RowHeader(isAllSelected: model.isAllSelected(granule.files), isAnySelected: model.isAnySelected(granule.files),
                          icon: "doc", accent: accent) { model.setSelected(granule.files, $0) }
                VStack(alignment: .leading) {
                    Text(granule.name).font(.body.weight(.medium)).foregroundStyle(accent).textSelection(.enabled)
                    Text("\(granule.product) · \(granule.start.map(Self.display) ?? "unknown date") · \(granule.files.count) files")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                RowActions(model: model, granules: [granule], files: granule.files,
                           flightlineHelp: "Add the other segments of this granule's flightline")
            }
        }
    }

    private nonisolated static func display(_ iso: String) -> String {
        iso.replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: "Z", with: " UTC")
    }
}

private struct TriStateCheckboxStyle: ToggleStyle {
    let mixed: Bool

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            Image(systemName: configuration.isOn ? "checkmark.square.fill"
                  : mixed ? "minus.square.fill" : "square")
                .foregroundStyle(configuration.isOn || mixed ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
    }
}

private struct DownloadBar: View {
    @Bindable var model: SearchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if !model.downloadRemotely {
                    Button("Choose Folder…") { chooseFolder() }
                }
                Text(model.destinationDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("\(model.selection.count) file\(model.selection.count == 1 ? "" : "s") selected"
                     + (model.selectedBytes > 0 ? " · \(formatBytes(model.selectedBytes))" : ""))
                    .monospacedDigit()
                Button("Download") { Task { await model.download() } }
                    .disabled(!model.canDownload)
            }
            if model.isDownloading {
                ProgressView(value: model.downloadFraction)
            }
            if let status = model.downloadStatus {
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(8)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK { model.destination = panel.url }
    }
}

#Preview {
    ContentView()
}
