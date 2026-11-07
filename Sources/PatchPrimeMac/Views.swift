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
    /// Where its sound comes from (a strip) or goes (an output), for the default star.
    var endpoint: Endpoint? = nil

    var cueKey: String { "\(stage.meterPrefix)\(slot)" }

    func starHelp(_ role: (output: Bool, device: String, command: [String]), _ isDefault: Bool) -> String {
        let which = role.output ? "output" : "input"
        var text = isDefault ? "\(role.device) is the system's default \(which)." : "Make \(role.device) the system's default \(which)."
        if case .device = endpoint {
            // A hardware strip is one or two channels of a device; the default is the whole device.
            text += " That's the whole device: macOS can't make a single channel the default."
            if !role.output {
                text += " For apps to record one processed mic, route it to a virtual input such as Stream Mic and star that."
            }
        }
        return text
    }

    /// The system default this strip's device can be: a strip apps play into is an output
    /// for them; an output apps record from is an input; hardware is what it is.
    /// (which default, its device's name, the command that makes it the default)
    var defaultRole: (output: Bool, device: String, command: [String])? {
        guard let endpoint else { return nil }
        switch (stage, endpoint) {
        case let (.input, .virtual(s)):
            return (true, model.snapshot.virtuals.first { $0.slot == s }?.name ?? "", ["default", "output", "\(s)"])
        case let (.output, .virtual(s)):
            return (false, model.snapshot.virtuals.first { $0.slot == s }?.name ?? "", ["default", "input", "\(s)"])
        case let (.input, .device(sig, _, _)):
            return (false, sig.name, ["default-device", "input", sig.name])
        case let (.output, .device(sig, _, _)):
            return (true, sig.name, ["default-device", "output", sig.name])
        default:
            return nil
        }
    }
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
            EffectsButton(stage: stage, slot: slot, label: label, count: effects, on: effectsOn)
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
            HStack(spacing: 4) {
                ToggleButton(title: "M", on: muted, color: .muteRed, textOn: .white) {
                    model.send("mute", stage.verb, "\(slot)", muted ? "off" : "on")
                }
                .help(muted ? "Muted: click to unmute" : "Mute")
                if let cueTo = model.snapshot.settings.cueOutput {
                    if stage == .output && slot == cueTo {
                        // The cue output itself: what it's playing, instead of a C.
                        Text(model.snapshot.cued.isEmpty ? "C OUT" : "C ON")
                            .font(.system(size: 10, weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(model.snapshot.cued.isEmpty ? Color.secondary : Color.yellow)
                            .frame(maxWidth: .infinity, minHeight: 20)
                            .help(model.snapshot.cued.isEmpty ? "Cue plays here" : "Playing what's cued instead of its own mix")
                    } else {
                        let cued = model.snapshot.cued.contains(cueKey)
                        ToggleButton(title: "C", on: cued, color: .yellow) {
                            model.send("cue", stage.verb, "\(slot)", cued ? "off" : "on")
                        }
                        .help("Cue: hear this alone on the cue output, \(model.snapshot.settings.cuePreFader ? "before" : "after") its fader")
                    }
                }
                if let role = defaultRole {
                    let current = role.output ? model.snapshot.defaultOutput : model.snapshot.defaultInput
                    let isDefault = !role.device.isEmpty && current == role.device
                    Button {
                        if !isDefault { model.send(role.command) }
                    } label: {
                        Image(systemName: isDefault ? "star.fill" : "star")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(isDefault ? Color.green : Color.secondary)
                            .frame(maxWidth: .infinity, minHeight: 20)
                            .background(Color.primary.opacity(isDefault ? 0.12 : 0.08), in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .help(starHelp(role, isDefault))
                }
            }
            if stage != .output {
                RouteButton(stage: stage, slot: slot, label: label)
            } else {
                Color.clear.frame(height: 20) // outputs route nowhere; keep the strips lined up
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
                            silent: model.snapshot.silent.contains(strip.label), effects: strip.effects.count, effectsOn: strip.effectsOn,
                            endpoint: strip.source)
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
                            effects: output.effects.count, effectsOn: output.effectsOn, endpoint: output.sink)
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
            PluginsSection()
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
    @AppStorage("mini") private var mini = false
    @State private var window: NSWindow?
    @State private var watcher: FrameWatcher?

    var body: some View {
        Group {
            if mini {
                MiniView { setMini(false) }
            } else {
                full
            }
        }
        .background(WindowReader { w in
            guard window == nil else { return }
            window = w
            // Back where it was left, in the mode it was left in; and kept as it's moved.
            WindowFrames.restore(w, mini: mini)
            // The mode as it is when saving, not as it was when this was set up.
            watcher = FrameWatcher(w) { WindowFrames.save($0, mini: UserDefaults.standard.bool(forKey: "mini")) }
        })
    }

    /// One strip wide, or back to the full mixer, each at its own remembered size and place.
    func setMini(_ on: Bool) {
        guard let w = window else { mini = on; return }
        WindowFrames.save(w.frame, mini: mini) // where the mode being left was
        WindowFrames.restoring = true
        mini = on
        // After SwiftUI has put the other view in (and its minimum size with it), or the
        // old minimum would stretch the restored size.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { WindowFrames.restore(w, mini: on) }
    }

    var full: some View {
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
                Button { setMini(true) } label: { Image(systemName: "rectangle.compress.vertical") }
                    .help("Mini window: every level and mute, one strip wide")
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

/// Where a strip or bus sends its sound, as on the Routing tab: grey "Route" when it goes
/// nowhere, else where it goes; click for a chooser with every bus and output it can feed.
struct RouteButton: View {
    @EnvironmentObject var model: Model
    var stage: Stage
    var slot: Int
    var label: String
    @State private var open = false

    struct Target: Identifiable {
        var id: String { "\(isBus ? "b" : "o")\(slot)" }
        var isBus: Bool
        var slot: Int
        var label: String
        var gain: Float?
    }

    var targets: [Target] {
        let s = model.snapshot.settings
        if stage == .input, let strip = s.strips.first(where: { $0.slot == slot }) {
            return s.buses.map { b in Target(isBus: true, slot: b.slot, label: b.label, gain: strip.busSends.first { $0.to == b.slot }?.gain) }
                + s.outputs.map { o in Target(isBus: false, slot: o.slot, label: o.label, gain: strip.outputSends.first { $0.to == o.slot }?.gain) }
        }
        if stage == .bus, let bus = s.buses.first(where: { $0.slot == slot }) {
            return s.outputs.map { o in Target(isBus: false, slot: o.slot, label: o.label, gain: bus.outputSends.first { $0.to == o.slot }?.gain) }
        }
        return []
    }

    func route(_ t: Target, _ gain: Float) -> [String] {
        [ "route", stage.verb, "\(slot)", t.isBus ? "bus" : "out", "\(t.slot)", "\(gain)"]
    }

    var body: some View {
        let all = targets
        let on = all.filter { $0.gain != nil }
        Button { open = true } label: {
            Text(on.isEmpty ? "Route" : "→ " + on.map(\.label).joined(separator: ", "))
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 3)
                .frame(maxWidth: .infinity, minHeight: 20)
                .foregroundStyle(on.isEmpty ? Color.secondary : Color.primary)
                .background(on.isEmpty ? Color.primary.opacity(0.08) : stage.color.opacity(0.35), in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(on.isEmpty ? "Goes nowhere yet: choose where" : "Goes to " + on.map(\.label).joined(separator: ", "))
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(label) goes to").font(.headline)
                if all.isEmpty {
                    Text("There's nothing to send to yet: add a bus or an output in Setup.").foregroundStyle(.secondary)
                }
                ForEach(all) { t in
                    HStack {
                        Toggle(isOn: Binding(get: { t.gain != nil }, set: { model.send(route(t, $0 ? 1 : 0)) })) {
                            HStack(spacing: 4) {
                                Circle().fill(t.isBus ? Color.blue : Color.orange).frame(width: 7, height: 7)
                                Text(t.label)
                            }
                        }
                        .toggleStyle(.checkbox)
                        Spacer(minLength: 16)
                        if let g = t.gain {
                            Menu(Decibels.label(Decibels.fromGain(g)) + " dB") {
                                ForEach([0, -3, -6, -12, -20], id: \.self) { (db: Int) in
                                    Button("\(db) dB") { model.send(route(t, Decibels.toGain(Float(db)))) }
                                }
                            }
                            .fixedSize()
                        }
                    }
                }
                Text("Blue: mix buses. Orange: outputs.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(minWidth: 240)
        }
    }
}

/// Where the full and mini windows were, kept apart, and brought back sensibly: never
/// below a usable size, and never off the screens there are now.
enum WindowFrames {
    static let fullMinimum = NSSize(width: 640, height: 460)
    static let miniMinimum = NSSize(width: 150, height: 200)

    static func key(_ mini: Bool) -> String { mini ? "frame.mini" : "frame.full" }

    /// While the app moves the window itself (switching modes), those moves aren't the
    /// user's, and mustn't be saved over the other mode's place.
    @MainActor static var restoring = false

    @MainActor static func save(_ frame: NSRect, mini: Bool) {
        guard !restoring else { return }
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: key(mini))
    }

    @MainActor static func restore(_ w: NSWindow, mini: Bool) {
        let minimum = mini ? miniMinimum : fullMinimum
        w.minSize = minimum
        var frame: NSRect
        if let text = UserDefaults.standard.string(forKey: key(mini)) {
            frame = NSRectFromString(text)
        } else if mini {
            // First time small: one strip wide at the full window's right edge.
            frame = NSRect(x: w.frame.maxX - 170, y: w.frame.maxY - 560, width: 170, height: 560)
        } else {
            frame = NSRect(x: w.frame.minX, y: w.frame.maxY - 620, width: 900, height: 620)
        }
        frame.size.width = max(frame.width, minimum.width)
        frame.size.height = max(frame.height, minimum.height)
        // On a screen there is now, or the main one.
        let screens = NSScreen.screens.map(\.visibleFrame)
        if !screens.contains(where: { $0.intersects(frame) && $0.intersection(frame).width >= 80 && $0.intersection(frame).height >= 60 }),
           let main = NSScreen.main?.visibleFrame ?? screens.first {
            frame.size.width = min(frame.width, main.width)
            frame.size.height = min(frame.height, main.height)
            frame.origin = NSPoint(x: main.midX - frame.width / 2, y: main.midY - frame.height / 2)
        }
        restoring = true
        w.setFrame(frame, display: true, animate: w.isVisible)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { restoring = false } // after the animation
    }
}

/// Saves a window's frame whenever it's moved or resized.
final class FrameWatcher {
    private var tokens: [NSObjectProtocol] = []

    init(_ w: NSWindow, _ save: @escaping @MainActor (NSRect) -> Void) {
        for name in [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification, NSWindow.willCloseNotification] {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: w, queue: .main) { [weak w] _ in
                MainActor.assumeIsolated { if let w { save(w.frame) } }
            })
        }
    }

    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
}

/// Finds the window a view is in.
struct WindowReader: NSViewRepresentable {
    var found: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { found(w) } }
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {}
}

/// The mini window: every strip, bus and output as a row with a level and a mute.
struct MiniView: View {
    @EnvironmentObject var model: Model
    var expand: () -> Void

    var body: some View {
        let s = model.snapshot.settings
        VStack(spacing: 0) {
            HStack {
                Text("PatchPrimeMac").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Button(action: expand) { Image(systemName: "rectangle.expand.vertical") }
                    .buttonStyle(.borderless)
                    .help("Back to the full mixer")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Divider()
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(s.strips, id: \.slot) { MiniRow(stage: .input, slot: $0.slot, label: $0.label, gain: $0.gain, muted: $0.muted) }
                    if !s.buses.isEmpty { Divider() }
                    ForEach(s.buses, id: \.slot) { MiniRow(stage: .bus, slot: $0.slot, label: $0.label, gain: $0.gain, muted: $0.muted) }
                    if !s.outputs.isEmpty { Divider() }
                    ForEach(s.outputs, id: \.slot) { MiniRow(stage: .output, slot: $0.slot, label: $0.label, gain: $0.gain, muted: $0.muted) }
                }
                .padding(8)
            }
        }
        .frame(minWidth: 150, idealWidth: 170, maxWidth: .infinity, minHeight: 200, idealHeight: 560, maxHeight: .infinity)
    }
}

struct MiniRow: View {
    @EnvironmentObject var model: Model
    var stage: Stage
    var slot: Int
    var label: String
    var gain: Float
    var muted: Bool
    @State private var moving: Float?

    static func position(_ db: Float) -> Double { Double((db - Decibels.floor) / (Decibels.top - Decibels.floor)) }
    static func db(_ p: Double) -> Float { Decibels.floor + Float(p) * (Decibels.top - Decibels.floor) }

    var body: some View {
        let db = moving ?? Decibels.fromGain(gain)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle().fill(stage.color).frame(width: 6, height: 6)
                Text(label).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 2)
                Text(Decibels.label(db)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                ToggleButton(title: "M", on: muted, color: .muteRed, textOn: .white) {
                    model.send("mute", stage.verb, "\(slot)", muted ? "off" : "on")
                }
                .frame(width: 24)
                VStack(spacing: 2) {
                    NativeSlider(position: Self.position(db),
                        change: { p in
                            let v = Self.db(p)
                            moving = v
                            model.sendLevel("\(stage.verb)\(slot)", ["gain", stage.verb, "\(slot)", "\(Decibels.toGain(v))"])
                        },
                        end: { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { moving = nil } },
                        reset: {
                            moving = nil
                            model.send("gain", stage.verb, "\(slot)", "1")
                        })
                    LiveMeter(levels: model.levels, key: "\(stage.meterPrefix)\(slot)", horizontal: true)
                        .frame(height: 3)
                }
            }
        }
        .help("Double-click the slider for 0 dB; scroll to adjust")
    }
}
