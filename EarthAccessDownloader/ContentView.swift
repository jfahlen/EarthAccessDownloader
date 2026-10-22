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

            Section {
                DisclosureGroup("Python (needs earthaccess installed)") {
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
                    ForEach(ResultRow.rows(from: model.granules)) { row in
                        switch row {
                        case let .granule(granule):
                            GranuleRow(model: model, granule: granule).tag(granule.id)
                        case let .flightline(prefix, product, granules):
                            FlightlineRow(model: model, prefix: prefix, product: product, granules: granules)
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

private struct FlightlineRow: View {
    @Bindable var model: SearchViewModel
    let prefix: String
    let product: String
    let granules: [Granule]
    @State private var expanded = true

    private var files: [GranuleFile] { granules.flatMap(\.files) }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(granules) { granule in
                GranuleRow(model: model, granule: granule).tag(granule.id)
            }
        } label: {
            HStack {
                Toggle(isOn: Binding(get: { model.isAllSelected(files) },
                                     set: { model.setSelected(files, $0) })) { EmptyView() }
                    .toggleStyle(TriStateCheckboxStyle(
                        mixed: !model.isAllSelected(files) && model.isAnySelected(files)))
                Image(systemName: "airplane")
                VStack(alignment: .leading) {
                    Text("Flightline \(prefix)").font(.body.weight(.semibold)).textSelection(.enabled)
                    Text("\(product) · \(granules.count) segments · \(files.count) files")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("All") { model.setSelected(files, true) }
                    .buttonStyle(.borderless)
                    .help("Select all files in every segment of this flightline")
                Button("None") { model.setSelected(files, false) }
                    .buttonStyle(.borderless)
                    .help("Deselect all files in this flightline")
            }
        }
    }
}

private struct GranuleRow: View {
    @Bindable var model: SearchViewModel
    let granule: Granule
    @State private var expanded = false

    private var granuleToggle: Binding<Bool> {
        Binding(get: { model.isAllSelected(granule.files) },
                set: { model.setSelected(granule.files, $0) })
    }

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
                // Mixed state shows as a dash when only some files are selected.
                Toggle(isOn: granuleToggle) { EmptyView() }
                    .toggleStyle(TriStateCheckboxStyle(
                        mixed: !model.isAllSelected(granule.files) && model.isAnySelected(granule.files)))
                VStack(alignment: .leading) {
                    Text(granule.name).font(.body.weight(.medium)).textSelection(.enabled)
                    Text("\(granule.product) · \(granule.start.map(Self.display) ?? "unknown date") · \(granule.files.count) files")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if granule.flightlinePrefix != nil {
                    Button("Flightline") {
                        Task { await model.extendFlightlines(of: [granule]) }
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.isExtending)
                    .help("Add the other segments of this granule's flightline")
                }
                Button("All") { model.setSelected(granule.files, true) }
                    .buttonStyle(.borderless)
                    .help("Select all files in this granule")
                Button("None") { model.setSelected(granule.files, false) }
                    .buttonStyle(.borderless)
                    .help("Deselect all files in this granule")
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
                Button("Choose Folder…") { chooseFolder() }
                Text(model.destination?.path ?? "No folder chosen")
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("\(model.selection.count) file\(model.selection.count == 1 ? "" : "s") selected"
                     + (model.selectedBytes > 0 ? " · \(formatBytes(model.selectedBytes))" : ""))
                    .monospacedDigit()
                Button("Download") { Task { await model.download() } }
                    .disabled(model.selection.isEmpty || model.destination == nil || model.isDownloading)
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
