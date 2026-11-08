// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// The soundboard window: pads that play sounds on cue into one strip, by section.
// Click a pad to play it, again to stop it; several can play at once. Right-click a
// pad to rename it, set its level, make it loop, move it or remove it.

import AppKit
import PPShared
import SwiftUI
import UniformTypeIdentifiers

/// The top bar's button for the Soundboard window; lit while a pad plays.
struct SoundboardButton: View {
    @EnvironmentObject var model: Model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let playing = !model.snapshot.padsPlaying.isEmpty
        Button { openWindow(id: "soundboard") } label: {
            Label("Soundboard", systemImage: playing ? "square.grid.3x3.fill" : "square.grid.3x3")
                .foregroundStyle(playing ? Color.accentColor : Color.primary)
                .labelStyle(.iconOnly)
        }
        .help("Soundboard: sounds on cue, into one strip")
    }
}

struct SoundboardView: View {
    @EnvironmentObject var model: Model
    @State private var renaming: SoundPad?
    @State private var newName = ""
    @State private var levelFor: SoundPad?

    static let groupColors: [String: Color] = ["Crowd": .orange, "Comedy": .pink, "Horns and Sirens": .red, "Drums": .teal]

    var body: some View {
        let snap = model.snapshot
        let pads = snap.settings.pads
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Picker("Plays into", selection: Binding(
                    get: { snap.padsInto },
                    set: { key in
                        guard let first = key.first, let slot = Int(key.dropFirst()) else { return }
                        model.send("pads-into", first == "s" ? "strip" : first == "b" ? "bus" : "out", "\(slot)")
                    })) {
                    ForEach(targets(snap), id: \.key) { t in Text(t.label).tag(t.key) }
                }
                .fixedSize()
                .help("Where the pads play: a mix bus your stream hears, say, or an output to hear them yourself.")
                Spacer()
                Button("Stop All") { model.send("pad-stop-all") }
                    .disabled(snap.padsPlaying.isEmpty)
                Button("Add Sounds…") { addSounds() }
                Menu {
                    Button("Put Back the Built-in Sounds") { model.send("pad-builtin") }
                    Button("Show Sounds in Finder") {
                        let folder = URL(fileURLWithPath: snap.recordFolder).appendingPathComponent("Soundboard")
                        NSWorkspace.shared.open(folder)
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuIndicator(.hidden).fixedSize()
            }
            .padding(10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(sections(pads), id: \.name) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.name.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6)
                                .foregroundStyle(.secondary)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 116, maximum: 160), spacing: 8)], spacing: 8) {
                                ForEach(section.pads) { pad in
                                    PadButton(pad: pad, progress: snap.padsPlaying[pad.id],
                                              color: Self.groupColors[pad.group] ?? .accentColor) {
                                        model.send("pad", pad.id)
                                    }
                                    .contextMenu { menu(pad, in: pads) }
                                    .popover(isPresented: Binding(get: { levelFor?.id == pad.id }, set: { if !$0 { levelFor = nil } })) {
                                        PadLevel(pad: pad) { model.send("pad-set", pad.id, "gain", String(format: "%.1f", $0)) }
                                    }
                                }
                            }
                        }
                    }
                    if pads.isEmpty {
                        Text("No pads. Add Sounds… adds WAV, FLAC, AIFF, MP3 or AAC files, or put back the built-in ones from the … menu.")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(40)
                    }
                }
                .padding(12)
            }
            Divider()
            Text("Click a pad to play it, and again to stop it. Right-click for its name, level, loop and place.")
                .font(.caption).foregroundStyle(.secondary).padding(8)
        }
        .frame(minWidth: 420, minHeight: 300)
        .alert("Rename \(renaming?.label ?? "")", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let pad = renaming, !newName.trimmingCharacters(in: .whitespaces).isEmpty {
                    model.send(["pad-set", pad.id, "label", newName])
                }
                renaming = nil
            }
        }
    }

    @ViewBuilder func menu(_ pad: SoundPad, in pads: [SoundPad]) -> some View {
        Button("Rename…") {
            newName = pad.label
            renaming = pad
        }
        Button(String(format: "Level (%+.1f dB)…", pad.gainDb)) { levelFor = pad }
        Toggle("Loop", isOn: Binding(get: { pad.loop }, set: { model.send("pad-set", pad.id, "loop", $0 ? "on" : "off") }))
        Divider()
        let i = pads.firstIndex { $0.id == pad.id } ?? 0
        Button("Move Earlier") { model.send("pad-move", pad.id, "-1") }.disabled(i == 0)
        Button("Move Later") { model.send("pad-move", pad.id, "1") }.disabled(i >= pads.count - 1)
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: pad.path)]) }
        Divider()
        Button("Remove", role: .destructive) { model.send("pad-remove", pad.id) }
    }

    /// The pads by section, in the order they first appear; yours (no section) last.
    func sections(_ pads: [SoundPad]) -> [(name: String, pads: [SoundPad])] {
        var order: [String] = []
        for p in pads where !order.contains(p.group) { order.append(p.group) }
        if let yours = order.firstIndex(of: "") { order.append(order.remove(at: yours)) }
        return order.map { g in (g.isEmpty ? "Yours" : g, pads.filter { $0.group == g }) }
    }

    func targets(_ snap: Snapshot) -> [(key: String, label: String)] {
        var out: [(String, String)] = snap.settings.buses.map { ("b\($0.slot)", $0.label) }
        out += snap.settings.outputs.map { ("o\($0.slot)", $0.label) }
        out += snap.settings.strips.compactMap { st in
            if case .virtual = st.source { return ("s\(st.slot)", st.label) }
            return nil
        }
        return out
    }

    func addSounds() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        panel.message = "Choose sounds for the soundboard"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { model.send(["pad-add", url.path]) }
    }
}

/// A pad: its name, lit while it plays, with its progress along the bottom.
struct PadButton: View {
    var pad: SoundPad
    var progress: [Double]?   // seconds played, length
    var color: Color
    var action: () -> Void

    var body: some View {
        let playing = progress != nil
        let fraction = progress.flatMap { $0.count == 2 && $0[1] > 0 ? min(1, $0[0] / $0[1]) : nil } ?? 0
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 8).fill(playing ? color.opacity(0.85) : color.opacity(0.18))
                RoundedRectangle(cornerRadius: 8).stroke(color.opacity(playing ? 1 : 0.5), lineWidth: 1.5)
                VStack(spacing: 2) {
                    Text(pad.label).font(.system(size: 12, weight: .semibold)).multilineTextAlignment(.center)
                        .lineLimit(2).minimumScaleFactor(0.8)
                    HStack(spacing: 4) {
                        if pad.loop { Image(systemName: "repeat") }
                        if pad.gainDb != 0 { Text(String(format: "%+.0f dB", pad.gainDb)) }
                    }
                    .font(.system(size: 9)).opacity(0.75)
                }
                .foregroundStyle(playing ? Color.white : Color.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(6)
                if playing {
                    GeometryReader { g in
                        Capsule().fill(Color.white.opacity(0.85))
                            .frame(width: max(4, (g.size.width - 12) * fraction), height: 3)
                            .offset(x: 6, y: g.size.height - 7)
                    }
                }
            }
            .frame(height: 58)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(playing ? "Playing: click to stop" : "Play \(pad.label)")
    }
}

/// A pad's level, -60 to +12 dB, double-click for 0.
struct PadLevel: View {
    var pad: SoundPad
    var change: (Double) -> Void
    @State private var db: Double?

    var body: some View {
        VStack(spacing: 8) {
            Text("Level of \(pad.label)").font(.headline)
            HStack {
                Slider(value: Binding(get: { db ?? pad.gainDb }, set: { db = $0.rounded(); change($0.rounded()) }), in: -30...12)
                    .frame(width: 200)
                Text(String(format: "%+.0f dB", db ?? pad.gainDb)).monospacedDigit().frame(width: 52)
            }
            Button("0 dB") { db = 0; change(0) }
        }
        .padding(14)
    }
}
