// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris

import PPShared
import SwiftUI

enum Stage {
    case input, bus, output

    var verb: String {
        switch self {
        case .input: return "strip"
        case .bus: return "bus"
        case .output: return "out"
        }
    }

    var color: Color {
        switch self {
        case .input: return .green
        case .bus: return .blue
        case .output: return .orange
        }
    }

    var meterPrefix: String {
        switch self {
        case .input: return "s"
        case .bus: return "b"
        case .output: return "o"
        }
    }
}

struct StripView: View {
    @EnvironmentObject var model: Model
    var stage: Stage
    var slot: Int
    var label: String
    var detail: String
    var gain: Float
    var muted: Bool
    var offline: Bool
    var silent = false
    var effects = 0
    var effectsOn = true

    var cueKey: String { "\(stage.meterPrefix)\(slot)" }
    @State private var renaming = false
    @State private var newName = ""

    var remove: String {
        switch stage {
        case .input: return "strip-remove"
        case .bus: return "bus-remove"
        case .output: return "out-remove"
        }
    }

    var body: some View {
        let db = Decibels.fromGain(gain)
        VStack(spacing: 6) {
            Text(label).font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                .padding(.horizontal, 3)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(stage.color.opacity(0.28), in: RoundedRectangle(cornerRadius: 4))
            Text(offline ? "OFFLINE" : silent ? "NO SIGNAL" : detail)
                .font(.system(size: 9, weight: offline || silent ? .bold : .regular))
                .foregroundStyle(offline ? Color.red : silent ? Color.orange : Color.secondary)
                .lineLimit(1)
                .help(silent ? "This input is delivering pure silence. Check that this channel has something connected, and that PatchPrimeEngine has Microphone access in System Settings." : detail)
            HStack(spacing: 6) {
                Fader(db: db) {
                    model.sendLevel("\(stage.verb)\(slot)", ["gain", stage.verb, "\(slot)", "\(Decibels.toGain($0))"])
                }
                    .frame(width: 34)
                LiveMeter(levels: model.levels, key: "\(stage.meterPrefix)\(slot)").frame(width: 9)
            }
            Text(Decibels.label(db)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            ToggleButton(title: "MUTE", on: muted, color: .red) {
                model.send("mute", stage.verb, "\(slot)", muted ? "off" : "on")
            }
            EffectsButton(stage: stage, slot: slot, label: label, count: effects, on: effectsOn)
            if let cueTo = model.snapshot.settings.cueOutput {
                if stage == .output && slot == cueTo {
                    Text(model.snapshot.cued.isEmpty ? "CUE OUT" : "CUEING")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(model.snapshot.cued.isEmpty ? Color.secondary : Color.yellow)
                        .frame(maxWidth: .infinity, minHeight: 20)
                } else {
                    let cued = model.snapshot.cued.contains(cueKey)
                    ToggleButton(title: "CUE", on: cued, color: .yellow) {
                        model.send("cue", stage.verb, "\(slot)", cued ? "off" : "on")
                    }
                    .help("Hear this alone on the cue output, \(model.snapshot.settings.cuePreFader ? "before" : "after") its fader")
                }
            }
        }
        .padding(8)
        .frame(width: 92)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            Button("Rename…") {
                newName = label
                renaming = true
            }
            Button("Remove", role: .destructive) { model.send(remove, "\(slot)") }
        }
        .alert("Rename \(label)", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { model.send("label", stage.verb, "\(slot)", newName) }
        }
    }
}

struct MixerView: View {
    @EnvironmentObject var model: Model

    func detail(_ e: Endpoint) -> String {
        switch e {
        case let .device(signature, left, right):
            return left == right ? "\(signature.name) \(left + 1)" : "\(signature.name) \(left + 1)-\(right + 1)"
        case .virtual:
            return "Virtual"
        }
    }

    func section<Content: View>(_ title: String, _ color: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 10, weight: .bold)).foregroundStyle(color).padding(.leading, 2)
            HStack(alignment: .top, spacing: 8) { content() }
        }
    }

    var body: some View {
        let s = model.snapshot.settings
        VStack(spacing: 0) {
        CueBar()
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 18) {
                section("INPUTS", .green) {
                    ForEach(s.strips, id: \.slot) { strip in
                        StripView(stage: .input, slot: strip.slot, label: strip.label, detail: detail(strip.source),
                            gain: strip.gain, muted: strip.muted, offline: model.snapshot.offline.contains(strip.label),
                            silent: model.snapshot.silent.contains(strip.label), effects: strip.effects.count, effectsOn: strip.effectsOn)
                    }
                }
                section("MIX BUSES", .blue) {
                    ForEach(s.buses, id: \.slot) { bus in
                        StripView(stage: .bus, slot: bus.slot, label: bus.label, detail: "Mix bus", gain: bus.gain,
                            muted: bus.muted, offline: false, effects: bus.effects.count, effectsOn: bus.effectsOn)
                    }
                }
                section("OUTPUTS", .orange) {
                    ForEach(s.outputs, id: \.slot) { output in
                        StripView(stage: .output, slot: output.slot, label: output.label, detail: detail(output.sink),
                            gain: output.gain, muted: output.muted, offline: model.snapshot.offline.contains(output.label),
                            effects: output.effects.count, effectsOn: output.effectsOn)
                    }
                }
            }
            .padding(14)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        }
    }
}

/// Cue (solo in the headphones): where it plays, before or after the fader, its level.
struct CueBar: View {
    @EnvironmentObject var model: Model

    var body: some View {
        let s = model.snapshot.settings
        HStack(spacing: 10) {
            Text("CUE").font(.system(size: 10, weight: .bold)).foregroundStyle(.yellow)
            Picker("", selection: Binding(get: { s.cueOutput ?? -1 },
                set: { model.send("cue-output", $0 < 0 ? "off" : "\($0)") })) {
                Text("Off").tag(-1)
                ForEach(s.outputs, id: \.slot) { Text($0.label).tag($0.slot) }
            }
            .labelsHidden().fixedSize()
            .help("The output cue plays to, usually headphones. While anything is cued, it plays that instead of its own mix.")
            if s.cueOutput != nil {
                Picker("", selection: Binding(get: { s.cuePreFader }, set: { model.send("cue-mode", $0 ? "pfl" : "afl") })) {
                    Text("PFL").tag(true)
                    Text("AFL").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("PFL: before the fader (after a strip's effects), so a muted mic can be checked. AFL: after the fader.")
                Spinner(info: EffectParamInfo(name: "cue", label: "Cue level", unit: "dB", min: -60, max: 12,
                    initial: 0, kind: "linear", options: []), value: s.cueLevelDb) { model.send("cue-level", String($0)) }
                Text("dB").font(.caption).foregroundStyle(.secondary)
                if !model.snapshot.cued.isEmpty {
                    Button("Clear Cue") { model.send("cue-clear") }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }
}

struct RoutingView: View {
    @EnvironmentObject var model: Model

    /// Click turns a route on at 0 dB or off. Scroll sets its level; so does right-click.
    private func cell(_ gain: Float?, color: Color, _ route: [String]) -> some View {
        Button {
            model.send(route + [gain == nil ? "1" : "0"])
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(gain != nil ? color : Color.primary.opacity(0.08))
                if let gain {
                    Text(Decibels.label(Decibels.fromGain(gain))).font(.system(size: 10, design: .monospaced)).foregroundStyle(.black)
                }
            }
            .frame(width: 58, height: 26)
        }
        .buttonStyle(.plain)
        .onWheel { steps in
            // A route that's on: half a dB a notch, down to -60 dB (it stays on).
            guard let gain else { return }
            let db = min(Decibels.top, max(Decibels.floor + 0.5, Decibels.fromGain(gain) + Float(steps) * 0.5))
            model.sendLevel(route.joined(separator: " "), route + ["\(Decibels.toGain(db))"])
        }
        .help("Click: on at 0 dB, or off. Scroll: level. Right-click: set a level.")
        .contextMenu {
            ForEach([0, -3, -6, -12, -20], id: \.self) { (db: Int) in
                Button("\(db) dB") { model.send(route + ["\(Decibels.toGain(Float(db)))"]) }
            }
            Button("Off") { model.send(route + ["0"]) }
        }
    }

    var body: some View {
        let s = model.snapshot.settings
        ScrollView([.horizontal, .vertical]) {
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    Text("")
                    ForEach(s.buses, id: \.slot) { Text($0.label).font(.caption.bold()).foregroundStyle(.blue).lineLimit(1).frame(width: 58) }
                    ForEach(s.outputs, id: \.slot) { Text($0.label).font(.caption.bold()).foregroundStyle(.orange).lineLimit(1).frame(width: 58) }
                }
                ForEach(s.strips, id: \.slot) { strip in
                    GridRow {
                        Text(strip.label).font(.caption.bold()).foregroundStyle(.green).gridColumnAlignment(.trailing)
                        ForEach(s.buses, id: \.slot) { bus in
                            cell(strip.busSends.first { $0.to == bus.slot }?.gain, color: .blue, ["route", "strip", "\(strip.slot)", "bus", "\(bus.slot)"])
                        }
                        ForEach(s.outputs, id: \.slot) { output in
                            cell(strip.outputSends.first { $0.to == output.slot }?.gain, color: .orange, ["route", "strip", "\(strip.slot)", "out", "\(output.slot)"])
                        }
                    }
                }
                ForEach(s.buses, id: \.slot) { bus in
                    GridRow {
                        Text(bus.label).font(.caption.bold()).foregroundStyle(.blue)
                        ForEach(s.buses, id: \.slot) { _ in Color.clear.frame(width: 58, height: 26) }
                        ForEach(s.outputs, id: \.slot) { output in
                            cell(bus.outputSends.first { $0.to == output.slot }?.gain, color: .orange, ["route", "bus", "\(bus.slot)", "out", "\(output.slot)"])
                        }
                    }
                }
            }
            .padding(16)
        }
    }
}

struct SetupView: View {
    @EnvironmentObject var model: Model
    @State private var name = ""
    @State private var stripDevice = ""
    @State private var channel = 1
    @State private var outDevice = ""
    @State private var virtualName = ""
    @State private var virtualOutput = true
    // A rate or buffer change restarts the engine, so it's confirmed first.
    @State private var pending: (words: [String], what: String)?

    var body: some View {
        let snap = model.snapshot
        Form {
            Section("Clock") {
                Picker("Clock", selection: Binding(
                    get: { snap.settings.clockDevice?.name ?? "" },
                    set: { model.send("clock", $0.isEmpty ? "patchprime" : $0) })) {
                    Text("Patch Prime (recommended)").tag("")
                    ForEach(snap.devices.filter { $0.transport != "Bluetooth" && $0.transport != "Virtual" }) { Text($0.name).tag($0.name) }
                }
                Text(snap.clockText).font(.caption).foregroundStyle(.secondary)
            }
            AudioSection(snap: snap) { words, what in pending = (words, what) }
            Section("Add an input") {
                TextField("Label", text: $name)
                Picker("Device", selection: $stripDevice) {
                    Text("Choose").tag("")
                    ForEach(snap.devices.filter { $0.inputs > 0 }) { Text($0.name).tag($0.name) }
                }
                Stepper("Channel \(channel)", value: $channel, in: 1...64)
                Button("Add Input") {
                    model.send("strip-add", name.isEmpty ? stripDevice : name, "device", stripDevice, "\(channel)", "\(channel)")
                    name = ""
                }
                .disabled(stripDevice.isEmpty)
            }
            Section("Add a mix bus") {
                Button("Add Bus") { model.send("bus-add", "Bus \(snap.settings.buses.count + 1)") }
            }
            Section("Add a hardware output") {
                Picker("Device", selection: $outDevice) {
                    Text("Choose").tag("")
                    ForEach(snap.devices.filter { $0.outputs > 0 }) { Text($0.name).tag($0.name) }
                }
                Button("Add Output") { model.send("out-add", outDevice, "device", outDevice, "1", "2") }
                    .disabled(outDevice.isEmpty)
            }
            Section("System defaults") {
                LabeledContent("Default output", value: snap.defaultOutput)
                LabeledContent("Default input", value: snap.defaultInput)
            }
            Section("Virtual devices") {
                ForEach(snap.virtuals) { v in
                    HStack {
                        Text(v.name)
                        Spacer()
                        Text(v.isOutput ? "Apps play here" : "Apps record here").foregroundStyle(.secondary)
                        if v.isOutput {
                            Button("Add Strip") { model.send("strip-add", v.name, "virtual", "\(v.slot)") }
                            Button("Make Default") { model.send("default", "output", "\(v.slot)") }
                                .disabled(snap.defaultOutput == v.name)
                        } else {
                            Button("Add Output") { model.send("out-add", v.name, "virtual", "\(v.slot)") }
                            Button("Make Default") { model.send("default", "input", "\(v.slot)") }
                                .disabled(snap.defaultInput == v.name)
                        }
                        Button("Delete") { model.send("virtual-remove", "\(v.slot)") }
                    }
                }
                TextField("New device name", text: $virtualName)
                Picker("Kind", selection: $virtualOutput) {
                    Text("Apps play here").tag(true)
                    Text("Apps record here").tag(false)
                }
                Button("Create Virtual Device") {
                    let used = snap.virtuals.map(\.slot)
                    if let slot = (0..<16).first(where: { !used.contains($0) }) {
                        model.send(["virtual-add", "\(slot)", virtualOutput ? "out" : "in", virtualName])
                        virtualName = ""
                    }
                }
                .disabled(virtualName.isEmpty)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(pending?.what ?? "", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Restart the Engine") {
                if let words = pending?.words { model.send(words) }
                pending = nil
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text("All audio through PatchPrimeMac stops for a moment while the engine restarts and every device locks again. Turn speakers down first if you're unsure.")
        }
    }
}

/// Sample rate and buffer sizes: the engine's, and each device's.
struct AudioSection: View {
    let snap: Snapshot
    let ask: ([String], String) -> Void

    static func khz(_ rate: Double) -> String {
        rate.truncatingRemainder(dividingBy: 1000) == 0 ? "\(Int(rate / 1000)) kHz" : String(format: "%.1f kHz", rate / 1000)
    }

    static func ms(_ frames: Int, _ rate: Double) -> String {
        rate > 0 ? String(format: "%.1f ms", Double(frames) / rate * 1000) : ""
    }

    var body: some View {
        let s = snap.settings
        Section {
            Picker("Sample rate", selection: Binding(
                get: { s.sampleRate },
                set: { if $0 != s.sampleRate { ask(["rate", "\(Int($0))"], "Change the sample rate to \(Self.khz($0))?") } })) {
                ForEach(PPShared.Settings.rates, id: \.self) { Text(Self.khz($0)).tag($0) }
            }
            Picker("Buffer size", selection: Binding(
                get: { s.bufferFrames },
                set: { if $0 != s.bufferFrames { ask(["buffer", "\($0)"], "Change the buffer size to \($0) frames?") } })) {
                ForEach(PPShared.Settings.buffers, id: \.self) { Text("\($0) frames (\(Self.ms($0, s.sampleRate)))").tag($0) }
            }
            if snap.engineRate > 0, snap.engineRate != s.sampleRate || snap.engineBlock != s.bufferFrames {
                Text("Running at \(Self.khz(snap.engineRate)), \(snap.engineBlock) frames.")
                    .font(.caption).foregroundStyle(.orange)
            }
            ForEach(snap.devices.filter { $0.buffer > 0 }) { d in
                DeviceAudioRow(device: d, settings: s, ask: ask)
            }
        } header: {
            Text("Audio")
        } footer: {
            Text("The virtual devices always run at the engine's rate. Hardware follows it if it can; otherwise it's resampled. Smaller buffers mean less delay and more work for the Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct DeviceAudioRow: View {
    let device: DeviceRow
    let settings: PPShared.Settings
    let ask: ([String], String) -> Void

    var body: some View {
        let keeps = settings.keepOwnRate.contains(device.uid)
        let resampled = abs(device.rate - settings.sampleRate) > 0.5
        let own = settings.deviceBuffers[device.uid]
        let choices = PPShared.Settings.buffers.filter {
            device.bufferMax == 0 || ($0 >= device.bufferMin && $0 <= device.bufferMax)
        }
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(device.name).bold()
                Spacer()
                Text("\(AudioSection.khz(device.rate))\(resampled ? ", resampled" : ""), \(device.buffer) frames (\(AudioSection.ms(device.buffer, device.rate)))")
                    .font(.caption).foregroundStyle(resampled ? .orange : .secondary)
            }
            HStack {
                Toggle("Keep its own rate", isOn: Binding(
                    get: { keeps },
                    set: { ask(["device-rate", device.name, $0 ? "own" : "follow"],
                        $0 ? "Leave \(device.name) at its own rate?" : "Run \(device.name) at the engine's rate?") }))
                    .disabled(!keeps && !device.rates.contains(settings.sampleRate))
                Spacer()
                Picker("Buffer", selection: Binding(
                    get: { own ?? 0 },
                    set: { value in
                        ask(["device-buffer", device.name, value == 0 ? "default" : "\(value)"],
                            value == 0 ? "Give \(device.name) the engine's buffer size?" : "Give \(device.name) \(value)-frame buffers?")
                    })) {
                    Text("Same as engine (\(settings.bufferFrames))").tag(0)
                    ForEach(choices, id: \.self) { Text("\($0) frames").tag($0) }
                }
                .frame(maxWidth: 260)
            }
            if !device.rates.contains(settings.sampleRate) {
                Text("\(device.name) can't run at \(AudioSection.khz(settings.sampleRate)), so it's resampled.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: Model
    @State private var tab = 0
    @State private var confirmHardware = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("", selection: $tab) {
                    Text("Mixer").tag(0)
                    Text("Routing").tag(1)
                    Text("Setup").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
                SceneMenu()
                Spacer()
                statusText
                Button(model.snapshot.settings.hardwareOutputEnabled ? "Hardware Output On" : "Hardware Output Off") {
                    if model.snapshot.settings.hardwareOutputEnabled {
                        model.send("hardware", "off")
                    } else {
                        confirmHardware = true
                    }
                }
                .tint(model.snapshot.settings.hardwareOutputEnabled ? .orange : nil)
                .buttonStyle(.borderedProminent)
            }
            .padding(10)
            Divider()
            Group {
                switch tab {
                case 0: MixerView()
                case 1: RoutingView()
                default: SetupView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(.red).padding(6)
            }
            if let note = model.snapshot.note {
                Text(note).font(.caption).foregroundStyle(.orange).padding(6)
            }
        }
        .frame(minWidth: 640, minHeight: 460)
        .alert("Turn on hardware output?", isPresented: $confirmHardware) {
            Button("Cancel", role: .cancel) {}
            Button("Turn On") { model.send("hardware", "on") }
        } message: {
            Text("Audio will reach your real outputs, limited to -6 dBFS. Check your amplifier and speaker levels first.")
        }
    }

    @ViewBuilder var statusText: some View {
        if !model.reachable {
            Text("Engine isn't running").foregroundStyle(.red).font(.caption)
        } else if !model.snapshot.running {
            Text("Driver not loaded").foregroundStyle(.red).font(.caption)
        } else if model.snapshot.underruns + model.snapshot.overruns > 0 {
            Text("Audio dropouts: \(model.snapshot.underruns + model.snapshot.overruns)").foregroundStyle(.orange).font(.caption)
        } else {
            Text("Running").foregroundStyle(.secondary).font(.caption)
        }
    }
}

/// Scenes: load one (it changes only the mix, so it's safe mid-stream), save the mix
/// as one, replace or delete one.
struct SceneMenu: View {
    @EnvironmentObject var model: Model
    @State private var saving = false
    @State private var name = ""
    @State private var deleting: String?

    var body: some View {
        let scenes = model.snapshot.scenes
        let last = model.snapshot.settings.lastScene
        Menu {
            if scenes.isEmpty {
                Text("No scenes yet")
            }
            ForEach(scenes, id: \.self) { scene in
                Button {
                    model.send(["scene-load", scene])
                } label: {
                    if scene == last { Label(scene, systemImage: "checkmark") } else { Text(scene) }
                }
            }
            Divider()
            Button("Save Mix as Scene…") {
                name = ""
                saving = true
            }
            if let last, scenes.contains(last) {
                Button("Update \"\(last)\" with This Mix") { model.send(["scene-save", last]) }
            }
            if !scenes.isEmpty {
                Menu("Delete") {
                    ForEach(scenes, id: \.self) { scene in
                        Button(scene, role: .destructive) { deleting = scene }
                    }
                }
            }
        } label: {
            Label(last.map { scenes.contains($0) ? $0 : "Scenes" } ?? "Scenes", systemImage: "square.stack.3d.up")
        }
        .fixedSize()
        .help("A scene is the mix: levels, mutes, sends, effects and the system defaults. Loading one never adds or removes anything, so it's safe while live.")
        .alert("Save the mix as a scene", isPresented: $saving) {
            TextField("Scene name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Save") { model.send(["scene-save", name]) }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        } message: {
            Text(model.snapshot.scenes.contains(name.trimmingCharacters(in: .whitespaces))
                ? "A scene with this name will be replaced." : "Levels, mutes, sends, effects and the system defaults.")
        }
        .alert("Delete the scene \"\(deleting ?? "")\"?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
                if let d = deleting { model.send(["scene-delete", d]) }
                deleting = nil
            }
        } message: {
            Text("The mix you have now isn't changed.")
        }
    }
}
