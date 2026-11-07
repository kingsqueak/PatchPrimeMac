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

    var body: some View {
        let db = Decibels.fromGain(gain)
        VStack(spacing: 6) {
            Text(label).font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                .padding(.horizontal, 3)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(stage.color.opacity(0.28), in: RoundedRectangle(cornerRadius: 4))
            Text(offline ? "OFFLINE" : detail)
                .font(.system(size: 9, weight: offline ? .bold : .regular))
                .foregroundStyle(offline ? Color.red : Color.secondary)
                .lineLimit(1)
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
        }
        .padding(8)
        .frame(width: 92)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
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
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 18) {
                section("INPUTS", .green) {
                    ForEach(s.strips, id: \.slot) { strip in
                        StripView(stage: .input, slot: strip.slot, label: strip.label, detail: detail(strip.source),
                            gain: strip.gain, muted: strip.muted, offline: model.snapshot.offline.contains(strip.label))
                    }
                }
                section("MIX BUSES", .blue) {
                    ForEach(s.buses, id: \.slot) { bus in
                        StripView(stage: .bus, slot: bus.slot, label: bus.label, detail: "Mix bus", gain: bus.gain,
                            muted: bus.muted, offline: false)
                    }
                }
                section("OUTPUTS", .orange) {
                    ForEach(s.outputs, id: \.slot) { output in
                        StripView(stage: .output, slot: output.slot, label: output.label, detail: detail(output.sink),
                            gain: output.gain, muted: output.muted, offline: model.snapshot.offline.contains(output.label))
                    }
                }
            }
            .padding(14)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

struct RoutingView: View {
    @EnvironmentObject var model: Model

    private func cell(on: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 4)
                .fill(on ? color : Color.primary.opacity(0.08))
                .frame(width: 58, height: 26)
        }
        .buttonStyle(.plain)
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
                            let on = strip.busSends.contains { $0.to == bus.slot }
                            cell(on: on, color: .blue) { model.send("route", "strip", "\(strip.slot)", "bus", "\(bus.slot)", on ? "0" : "1") }
                        }
                        ForEach(s.outputs, id: \.slot) { output in
                            let on = strip.outputSends.contains { $0.to == output.slot }
                            cell(on: on, color: .orange) { model.send("route", "strip", "\(strip.slot)", "out", "\(output.slot)", on ? "0" : "1") }
                        }
                    }
                }
                ForEach(s.buses, id: \.slot) { bus in
                    GridRow {
                        Text(bus.label).font(.caption.bold()).foregroundStyle(.blue)
                        ForEach(s.buses, id: \.slot) { _ in Color.clear.frame(width: 58, height: 26) }
                        ForEach(s.outputs, id: \.slot) { output in
                            let on = bus.outputSends.contains { $0.to == output.slot }
                            cell(on: on, color: .orange) { model.send("route", "bus", "\(bus.slot)", "out", "\(output.slot)", on ? "0" : "1") }
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

    var body: some View {
        let snap = model.snapshot
        Form {
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
            Section("Virtual devices") {
                ForEach(snap.virtuals) { v in
                    HStack {
                        Text(v.name)
                        Spacer()
                        Text(v.isOutput ? "Apps play here" : "Apps record here").foregroundStyle(.secondary)
                        if v.isOutput {
                            Button("Add Strip") { model.send("strip-add", v.name, "virtual", "\(v.slot)") }
                        } else {
                            Button("Add Output") { model.send("out-add", v.name, "virtual", "\(v.slot)") }
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
