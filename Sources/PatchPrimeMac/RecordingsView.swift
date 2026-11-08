// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// Recording: the record (or arm) button on each strip, and the Recordings page: the
// format, raw or processed inputs, multitrack takes, and the files, newest first.
// The engine does the recording, so it carries on with the window closed.

import AppKit
import AudioToolbox
import PPShared
import SwiftUI

/// The strip's record button: REC records it alone; with Multitrack on, ARM puts it
/// in the next take. While it records, the time, and a click stops it.
struct RecordButton: View {
    @EnvironmentObject var model: Model
    var stage: Stage
    var slot: Int

    var key: String { "\(stage.meterPrefix)\(slot)" }

    static func time(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }

    var body: some View {
        let snap = model.snapshot
        let seconds = snap.recording[key]
        let multitrack = snap.settings.multitrack
        let armed = snap.settings.armed.contains(key)
        Button {
            if seconds != nil || !multitrack {
                model.send("record", stage.verb, "\(slot)")
            } else {
                model.send("arm", stage.verb, "\(slot)", armed ? "off" : "on")
            }
        } label: {
            HStack(spacing: 4) {
                Circle().fill(seconds != nil ? Color.white : Color.red).frame(width: 7, height: 7)
                Text(seconds.map(Self.time) ?? (multitrack ? "ARM" : "REC"))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
            }
            .foregroundStyle(seconds != nil ? Color.white : armed && multitrack ? Color.red : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 20)
            .background(seconds != nil ? Color.red : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .stroke(armed && multitrack && seconds == nil ? Color.red : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .help(seconds != nil ? "Recording: click to stop"
              : multitrack ? (armed ? "Armed for the next take: click to disarm" : "Arm for the next take")
              : "Record this to a file")
    }
}

/// The top bar's button for the Recordings window; red while anything records.
struct RecordingsButton: View {
    @EnvironmentObject var model: Model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let recording = !model.snapshot.recording.isEmpty
        Button { openWindow(id: "recordings") } label: {
            Label("Recordings", systemImage: recording ? "record.circle.fill" : "record.circle")
                .foregroundStyle(recording ? Color.red : Color.primary)
                .labelStyle(.iconOnly)
        }
        .help("Recordings: the format, multitrack takes, your recordings and the player")
    }
}

/// The player: play and pause, stop, loop, where it is, and where it plays into.
struct PlayerBar: View {
    @EnvironmentObject var model: Model
    var selected: URL?
    var first: URL?
    @State private var dragging: Double?

    var body: some View {
        let snap = model.snapshot
        let player = snap.player
        let loop = snap.settings.playLoop
        HStack(spacing: 10) {
            Button {
                if let player {
                    model.send("play-pause", player.paused ? "off" : "on")
                } else if let url = selected ?? first {
                    model.send(["play", url.path])
                }
            } label: {
                Image(systemName: player == nil || player!.paused ? "play.fill" : "pause.fill").frame(width: 16)
            }
            .disabled(player == nil && selected == nil && first == nil)
            .help(player == nil ? "Play the selected recording" : player!.paused ? "Carry on" : "Pause")
            Button { model.send("play-stop") } label: { Image(systemName: "stop.fill").frame(width: 16) }
                .disabled(player == nil)
                .help("Stop")
            Toggle(isOn: Binding(get: { loop }, set: { model.send("play-loop", $0 ? "on" : "off") })) {
                Image(systemName: "repeat")
            }
            .toggleStyle(.button)
            .help("Loop: play it over and over")
            VStack(alignment: .leading, spacing: 2) {
                Text(player.map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? "Not playing")
                    .font(.caption).lineLimit(1).foregroundStyle(player == nil ? .secondary : .primary)
                HStack(spacing: 6) {
                    Slider(value: Binding(
                        get: { dragging ?? player?.position ?? 0 },
                        set: { dragging = $0 }),
                        in: 0...max(0.01, player?.duration ?? 0.01)) { editing in
                        if !editing, let d = dragging {
                            model.send("play-seek", String(format: "%.3f", d))
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { dragging = nil }
                        }
                    }
                    .controlSize(.small)
                    .disabled(player == nil)
                    Text("\(RecordButton.time(dragging ?? player?.position ?? 0)) / \(RecordButton.time(player?.duration ?? 0))")
                        .font(.system(size: 11, design: .monospaced)).monospacedDigit().fixedSize()
                }
            }
            Picker("Play into", selection: Binding(
                get: { snap.playInto },
                set: { key in
                    guard let first = key.first, let slot = Int(key.dropFirst()) else { return }
                    model.send("play-into", first == "s" ? "strip" : first == "b" ? "bus" : "out", "\(slot)")
                })) {
                ForEach(targets(snap), id: \.key) { t in Text(t.label).tag(t.key) }
            }
            .fixedSize()
            .help("Where it plays. A mix bus or output: added to what's there (into Mix A, say, for your stream to hear it, or your headphones' output to listen alone). An input: in place of its device, through the strip's effects, fader and sends, so you can set up a mic's effects on a recording of it.")
        }
        .buttonStyle(.borderless)
    }

    func targets(_ snap: Snapshot) -> [(key: String, label: String)] {
        var out: [(String, String)] = []
        for st in snap.settings.strips {
            if case .virtual = st.source {
                out.append(("s\(st.slot)", "\(st.label) (instead of its apps)"))
            } else {
                out.append(("s\(st.slot)", "\(st.label) (instead of the device)"))
            }
        }
        out += snap.settings.buses.map { ("b\($0.slot)", $0.label) }
        out += snap.settings.outputs.map { ("o\($0.slot)", $0.label) }
        return out
    }
}

/// A recording on disk.
struct RecordingFile: Identifiable, Hashable {
    var id: URL { url }
    var url: URL
    var take: String?   // the take's folder name, for a take's track
    var seconds: Double
    var bytes: Int64
    var date: Date

    var name: String { url.lastPathComponent }
    var shownName: String { take.map { "\(name) (\($0.lowercased()))" } ?? name }

    static let types: Set<String> = ["flac", "wav", "m4a"]

    /// The recordings folder's files and its takes' tracks, newest first.
    static func list(in folder: URL) -> [RecordingFile] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .creationDateKey]
        guard let top = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return [] }
        var found: [RecordingFile] = []
        func add(_ url: URL, take: String?) {
            guard types.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: Set(keys)) else { return }
            found.append(RecordingFile(url: url, take: take, seconds: duration(url),
                bytes: Int64(values.fileSize ?? 0), date: values.creationDate ?? .distantPast))
        }
        for url in top {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                guard url.lastPathComponent.hasPrefix("Take ") else { continue }
                let tracks = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
                for track in tracks { add(track, take: url.lastPathComponent) }
            } else {
                add(url, take: nil)
            }
        }
        return found.sorted { $0.date != $1.date ? $0.date > $1.date : $0.name < $1.name }
    }

    static func duration(_ url: URL) -> Double {
        var file: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file else { return 0 }
        defer { AudioFileClose(file) }
        var seconds = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        AudioFileGetProperty(file, kAudioFilePropertyEstimatedDuration, &size, &seconds)
        return seconds
    }
}

struct RecordingsView: View {
    @EnvironmentObject var model: Model
    @State private var files: [RecordingFile] = []
    @State private var selection: Set<URL> = []
    @State private var problem: String?

    var folder: URL {
        let path = model.snapshot.recordFolder
        return path.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/PatchPrimeMac", isDirectory: true)
            : URL(fileURLWithPath: path, isDirectory: true)
    }

    var body: some View {
        let s = model.snapshot.settings
        let armed = s.armed.filter { key in model.snapshot.settings.label(of: key) != nil }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Picker("Format", selection: Binding(get: { s.recordFormat }, set: { model.send("record-format", $0) })) {
                    Text("FLAC").tag("flac")
                    Text("WAV").tag("wav")
                    Text("AAC").tag("aac")
                }
                .pickerStyle(.segmented).fixedSize()
                .help("FLAC: lossless, about half the size of WAV. WAV: uncompressed. FLAC and WAV are 24-bit. AAC (.m4a): small and plays everywhere, up to 48 kHz. Applies to the next recording.")
                Picker("Inputs", selection: Binding(get: { s.recordProcessed }, set: { model.send("record-inputs", $0 ? "processed" : "raw") })) {
                    Text("Raw").tag(false)
                    Text("Processed").tag(true)
                }
                .pickerStyle(.segmented).fixedSize()
                .help("A hardware input (a microphone): raw is the sound as the device sends it, before the strip's effects and fader; processed is after them, as the mix hears it. Applies at once. Mix buses, outputs and Desktop always record what they send on.")
                Toggle("Multitrack", isOn: Binding(get: { s.multitrack }, set: { model.send("multitrack", $0 ? "on" : "off") }))
                    .toggleStyle(.switch)
                    .help("The strips' REC buttons become ARM: arm the strips you want, then Record Take records them together, each to its own file, all starting on the same sample.")
                if s.multitrack || model.snapshot.takeRunning {
                    Button {
                        model.send("take")
                    } label: {
                        Label(model.snapshot.takeRunning ? "Stop Take" : "Record Take",
                              systemImage: model.snapshot.takeRunning ? "stop.fill" : "record.circle")
                    }
                    .tint(.red)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.snapshot.takeRunning && armed.isEmpty)
                    .help(armed.isEmpty ? "Arm some strips first" : "Records: \(armed.compactMap { s.label(of: $0) }.joined(separator: ", "))")
                }
                Spacer()
                Button("Open Folder") { openFolder() }
            }
            .padding(10)
            Divider()
            PlayerBar(selected: selection.first, first: files.first?.url)
                .padding(.horizontal, 10).padding(.vertical, 8)
            Divider()
            Table(files, selection: $selection) {
                TableColumn("Name") { f in Text(f.shownName).lineLimit(1) }
                TableColumn("Length") { f in Text(RecordButton.time(f.seconds)).monospacedDigit() }.width(70)
                TableColumn("Size") { f in Text(ByteCountFormatter.string(fromByteCount: f.bytes, countStyle: .file)) }.width(80)
                TableColumn("Recorded") { f in Text(f.date.formatted(date: .abbreviated, time: .shortened)) }.width(150)
            }
            .contextMenu(forSelectionType: URL.self) { urls in
                Button("Play") { if let url = urls.first { model.send(["play", url.path]) } }
                    .disabled(urls.count != 1)
                Button("Open in Its Usual App") { open(urls) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(Array(urls)) }
                Divider()
                Button("Move to Trash") { trash(urls) }
            } primaryAction: { urls in
                if let url = urls.first { model.send(["play", url.path]) }
            }
            .overlay {
                if files.isEmpty {
                    Text("No recordings yet. Press REC on a strip, or turn on Multitrack, arm some strips and press Record Take.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).padding(40)
                }
            }
            HStack {
                Text(problem ?? "Recordings go to \(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")). Double-click one to play it.")
                    .font(.caption).foregroundStyle(problem == nil ? Color.secondary : Color.red)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(Array(selection)) }
                    .disabled(selection.isEmpty)
                Button("Move to Trash") { trash(selection) }
                    .disabled(selection.isEmpty)
            }
            .padding(10)
        }
        .onAppear(perform: reload)
        .onChange(of: model.snapshot.recording.count) { reload() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            if !model.snapshot.recording.isEmpty { reload() } // lengths of what's being recorded
        }
    }

    func reload() {
        files = RecordingFile.list(in: folder)
        selection = selection.filter { url in files.contains { $0.url == url } }
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    func open(_ urls: Set<URL>) {
        for url in urls { NSWorkspace.shared.open(url) }
    }

    /// To the Trash, from where they can be put back. A take whose last track goes
    /// goes with it.
    func trash(_ urls: Set<URL>) {
        problem = nil
        let fm = FileManager.default
        for url in urls {
            if model.snapshot.player?.path == url.path { model.send("play-stop") }
            do {
                try fm.trashItem(at: url, resultingItemURL: nil)
                let dir = url.deletingLastPathComponent()
                if dir.lastPathComponent.hasPrefix("Take "), dir.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL,
                   let rest = try? fm.contentsOfDirectory(atPath: dir.path), rest.allSatisfy({ $0.hasPrefix(".") }) {
                    try? fm.trashItem(at: dir, resultingItemURL: nil)
                }
            } catch {
                problem = "Couldn't move \(url.lastPathComponent) to the Trash: \(error.localizedDescription)"
            }
        }
        reload()
    }
}

extension PPShared.Settings {
    /// A strip's, bus's or output's name, by "s0", "b1", "o2".
    func label(of key: String) -> String? {
        guard let first = key.first, let slot = Int(key.dropFirst()) else { return nil }
        switch first {
        case "s": return strips.first { $0.slot == slot }?.label
        case "b": return buses.first { $0.slot == slot }?.label
        case "o": return outputs.first { $0.slot == slot }?.label
        default: return nil
        }
    }
}
