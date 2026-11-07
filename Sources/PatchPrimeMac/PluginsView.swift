// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// Plugins: the scan (only when asked), and a browser of everything installed, with what
// the scan found and the user's filter. The same browser will pick plugins for chains.

import PPShared
import SwiftUI

/// In Setup: the counts, the scan, and the browser.
struct PluginsSection: View {
    @EnvironmentObject var model: Model
    @State private var browsing = false

    var body: some View {
        let scan = model.snapshot.pluginScan
        Section {
            HStack {
                if scan.scanning {
                    ProgressView(value: Double(scan.done), total: Double(max(scan.total, 1))).frame(width: 160)
                    Text("\(scan.done) of \(scan.total)").font(.caption.monospacedDigit())
                    Button("Stop") { model.send("plugins-scan-stop") }
                } else {
                    Text("\(scan.ok) checked and working\(scan.failed > 0 ? ", \(scan.failed) not" : "")")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Scan New") { model.send("plugins-scan", "new") }
                    .disabled(scan.scanning)
                    .help("Check plugins that are new or updated since the last scan")
                Button("Rescan All") { model.send("plugins-scan", "all") }
                    .disabled(scan.scanning)
                Button("Browse…") { browsing = true }
            }
            if scan.scanning, !scan.current.isEmpty {
                Text("Checking " + scan.current.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        } header: {
            Text("Plugins")
        } footer: {
            Text("Scanning loads each plugin to check it works, a few at a time in the background, so it never disturbs live audio. It only runs when you start it, and only checks what's new or updated.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $browsing) {
            PluginBrowser { browsing = false }.environmentObject(model)
        }
    }
}

struct PluginBrowser: View {
    @EnvironmentObject var model: Model
    var done: () -> Void
    @State private var rows: [PluginRow] = []
    @State private var search = ""
    @State private var showHidden = false
    @State private var loading = true
    @State private var order = [KeyPathComparator(\PluginRow.entry.maker), KeyPathComparator(\PluginRow.entry.name)]
    @State private var selection: Set<PluginRow.ID> = []

    func reload() {
        model.ask(["plugins-list"]) { reply in
            loading = false
            guard reply.ok, let list = try? JSONDecoder().decode([PluginRow].self, from: Data(reply.text.utf8)) else { return }
            rows = list
        }
    }

    var shown: [PluginRow] {
        let words = search.lowercased().split(separator: " ")
        return rows.filter { r in
            (showHidden || !r.hidden) && words.allSatisfy { w in
                let hay = "\(r.entry.format.rawValue) \(r.entry.maker) \(r.entry.name) \(r.entry.categories.joined(separator: " "))".lowercased()
                return hay.contains(w)
            }
        }.sorted(using: order)
    }

    static func statusText(_ r: PluginRow) -> String {
        if !r.entry.fitsStrips { return "Surround only" }
        switch r.status {
        case .ok: return "Works"
        case .failed: return "Failed"
        case .timedOut: return "Hung"
        case .crashed: return "Crashed"
        case nil: return "Not checked"
        }
    }

    var body: some View {
        let list = shown
        let filter = model.snapshot.settings.pluginFilter
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Plugins").font(.headline)
                TextField("Search maker, name or category", text: $search)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                Toggle("Show hidden", isOn: $showHidden).toggleStyle(.checkbox)
                Spacer()
                Menu("Kinds") {
                    ForEach(PluginKind.allCases, id: \.self) { kind in
                        Toggle(kind.label, isOn: Binding(get: { !filter.hiddenKinds.contains(kind) },
                            set: { model.send("plugin-filter", "kind", kind.rawValue, $0 ? "show" : "hide"); after() }))
                    }
                }
                .fixedSize()
                .help("Which kinds of plugin to list. Instruments, generators and MIDI processors don't belong on a mixer strip, so they're hidden at first.")
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Table(list, selection: $selection, sortOrder: $order) {
                TableColumn("Format", value: \.entry.format.rawValue) { r in
                    Text(r.entry.format.rawValue).font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .width(54)
                TableColumn("Maker", value: \.entry.maker) { r in Text(r.entry.maker).foregroundStyle(r.hidden ? .secondary : .primary) }
                    .width(min: 90, ideal: 130)
                TableColumn("Plugin", value: \.entry.name) { r in
                    HStack(spacing: 4) {
                        Text(r.entry.name).foregroundStyle(r.hidden ? .secondary : .primary)
                        if r.entry.variants.count > 1 {
                            Text(r.entry.variants.map { $0.channels.isEmpty ? "–" : $0.channels }.joined(separator: " "))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .width(min: 160, ideal: 230)
                TableColumn("Category") { r in Text(r.entry.categories.joined(separator: ", ")).foregroundStyle(.secondary) }
                    .width(min: 80, ideal: 140)
                TableColumn("Status") { r in
                    Text(Self.statusText(r)).foregroundStyle(
                        r.status == .ok ? Color.green : r.status == nil || !r.entry.fitsStrips ? Color.secondary : Color.orange)
                        .help(r.message)
                }
                .width(90)
                TableColumn("Window") { r in Text(r.status == nil ? "" : r.hasView ? "Yes" : "No").foregroundStyle(.secondary) }
                    .width(60)
                TableColumn("Hidden") { r in
                    Toggle("", isOn: Binding(get: { r.hidden },
                        set: { model.send("plugin-filter", "plugin", r.entry.id, $0 ? "hide" : "show"); after() }))
                        .toggleStyle(.checkbox).labelsHidden()
                }
                .width(50)
            }
            .contextMenu(forSelectionType: PluginRow.ID.self) { ids in
                if let id = ids.first, let r = rows.first(where: { $0.id == id }) {
                    Button(r.hidden ? "Show \(r.entry.name)" : "Hide \(r.entry.name)") {
                        model.send("plugin-filter", "plugin", r.entry.id, r.hidden ? "show" : "hide"); after()
                    }
                    let makerHidden = filter.hiddenMakers.contains(r.entry.maker)
                    Button(makerHidden ? "Show Everything by \(r.entry.maker)" : "Hide Everything by \(r.entry.maker)") {
                        model.send("plugin-filter", "maker", r.entry.maker, makerHidden ? "show" : "hide"); after()
                    }
                    ForEach(r.entry.categories, id: \.self) { c in
                        let hidden = filter.hiddenCategories.contains(c)
                        Button(hidden ? "Show the \(c) Category" : "Hide the \(c) Category") {
                            model.send("plugin-filter", "category", c, hidden ? "show" : "hide"); after()
                        }
                    }
                }
            }
            HStack {
                Text(loading ? "Listing…" : "\(list.count) shown of \(rows.count)\(rows.filter(\.hidden).count > 0 ? ", \(rows.filter(\.hidden).count) hidden" : "")")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("Right-click a plugin to hide it, its maker or its category.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(8)
        }
        .frame(minWidth: 820, idealWidth: 900, minHeight: 480, idealHeight: 620)
        .onAppear(perform: reload)
        .onChange(of: model.snapshot.pluginScan.scanning) { _, now in if !now { reload() } }
    }

    /// After a filter change, list again once the helper has it.
    func after() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { reload() }
    }
}
