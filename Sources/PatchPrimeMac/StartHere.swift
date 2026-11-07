// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// The first-run panel above the mixer: where you listen, your apps' sound through
// Patch Desktop, your mics, a mic for apps, and hardware output, each a step with a
// button, ticked off as it's done. It's hidden with Hide, and comes back if the mix
// is emptied.

import SwiftUI
import PPShared

struct StartHereView: View {
    @EnvironmentObject var model: Model
    @AppStorage("startHereHidden") private var hidden = false
    @Environment(\.openWindow) private var openWindow
    var showRouting: () -> Void
    @State private var listenDevice = ""
    @State private var micDevice = ""
    @State private var micChannel = 1
    @State private var micName = ""

    static func shows(_ s: PPShared.Settings, hidden: Bool) -> Bool {
        !hidden || (s.strips.isEmpty && s.outputs.isEmpty && s.buses.isEmpty)
    }

    var body: some View {
        let snap = model.snapshot
        let s = snap.settings
        let hardwareOut = s.outputs.first { if case .device = $0.sink { return true }; return false }
        let desktop = s.strips.first { if case .virtual = $0.source { return true }; return false }
        let mics = s.strips.filter { if case .device = $0.source { return true }; return false }
        let appMic = s.outputs.first { if case .virtual = $0.sink { return true }; return false }
        let hardwareDevices = snap.devices.filter { $0.transport != "Virtual" }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Start here").font(.title2.bold())
                Spacer()
                Button("Read the Guide") { openWindow(id: "help") }
                Button("Hide") { hidden = true }
                    .help("Hide this panel. It comes back if the mix is ever emptied.")
            }
            step(1, "Where you listen", done: hardwareOut != nil) {
                if let o = hardwareOut {
                    Text("**\(o.label)** is an output.")
                } else {
                    HStack {
                        Picker("Speakers or headphones", selection: $listenDevice) {
                            Text("Choose").tag("")
                            ForEach(hardwareDevices.filter { $0.outputs > 0 }) { Text($0.name).tag($0.name) }
                        }
                        .frame(maxWidth: 380)
                        Button("Add Output") { model.send("out-add", listenDevice, "device", listenDevice, "1", "2") }
                            .disabled(listenDevice.isEmpty)
                    }
                }
            }
            step(2, "Your apps' sound", done: desktop != nil && snap.defaultOutput.hasPrefix("Patch ")) {
                if desktop != nil && snap.defaultOutput.hasPrefix("Patch ") {
                    Text("Every app now plays into **\(snap.defaultOutput)**, the Mac's sound output, and comes into the mixer as the **\(desktop?.label ?? "Desktop")** strip. Apps that choose their own output device (call, streaming and radio apps, music software) have a setting for it: set it to \(snap.defaultOutput), or create a virtual device for that app in Setup to give it a strip of its own. To go back to playing straight to your speakers, pick them in System Settings → Sound.")
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Creates **Patch Desktop**, makes it the Mac's sound output so every app plays into the mixer, adds it as a strip and sends it to \(hardwareOut?.label ?? "your output").")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Set Up Patch Desktop") { setUpDesktop() }
                        .disabled(hardwareOut == nil)
                    if hardwareOut == nil { Text("Add where you listen first.").font(.caption).foregroundStyle(.secondary) }
                }
            }
            step(3, "Your microphones and instruments", done: !mics.isEmpty) {
                if !mics.isEmpty {
                    Text("\(mics.map(\.label).joined(separator: ", ")). Add more in Setup. They aren't sent to your speakers until you route them (Routing tab), so a microphone can't feed back.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    TextField("Name", text: $micName).frame(width: 120)
                    Picker("Device", selection: $micDevice) {
                        Text("Choose").tag("")
                        ForEach(hardwareDevices.filter { $0.inputs > 0 }) { Text($0.name).tag($0.name) }
                    }
                    .frame(maxWidth: 300)
                    Stepper("Channel \(micChannel)", value: $micChannel, in: 1...64)
                    Button("Add Input") {
                        model.send("strip-add", micName.isEmpty ? micDevice : micName, "device", micDevice, "\(micChannel)", "\(micChannel)")
                        micName = ""
                    }
                    .disabled(micDevice.isEmpty)
                }
            }
            step(4, "A microphone for apps (optional)", done: appMic != nil) {
                if let o = appMic {
                    Text("Apps that record from **\(snap.defaultInput)** hear the **\(o.label)** output: your microphones, with their effects. Route more to it in the Routing tab.")
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Creates **Patch Mic**, makes it the Mac's microphone, and sends your inputs to it, so call and streaming apps hear your microphones with their effects.")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Set Up Patch Mic") { setUpMic() }
                        .disabled(mics.isEmpty)
                }
            }
            step(5, "Turn on hardware output", done: s.hardwareOutputEnabled) {
                Text(s.hardwareOutputEnabled
                     ? "On. Every hardware output is limited to −6 dBFS."
                     : "Nothing reaches your speakers until you click **Hardware Output Off** at the top right. Turn your amplifier down first.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Routing") { showRouting() }
            }
        }
        .padding(16)
        .frame(maxWidth: 820, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
        .padding(14)
    }

    func step<Content: View>(_ n: Int, _ title: String, done: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle")
                .font(.title3)
                .foregroundStyle(done ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                content()
            }
        }
    }

    /// The first free virtual slot, as the engine's state has it.
    static func freeSlot(_ send: ([String]) -> Reply) -> Int? {
        let used = send(["virtual-list"]).text.split(separator: "\n").compactMap(slotOf)
        return (0..<16).first { !used.contains($0) }
    }

    /// "3<tab>out<tab>Patch Desktop" → 3
    static func slotOf(_ line: Substring) -> Int? {
        line.split(whereSeparator: \.isWhitespace).first.flatMap { Int($0) }
    }

    static func state(_ send: ([String]) -> Reply) -> PPShared.Settings? {
        try? JSONDecoder().decode(PPShared.Settings.self, from: Data(send(["state"]).text.utf8))
    }

    /// Making a new device the default can fail until macOS has it, a moment later.
    static func makeDefault(_ which: String, _ slot: Int, _ send: ([String]) -> Reply) -> Reply {
        var reply = send(["default", which, "\(slot)"])
        for _ in 0..<20 where !reply.ok {
            Thread.sleep(forTimeInterval: 0.25)
            reply = send(["default", which, "\(slot)"])
        }
        return reply
    }

    func setUpDesktop() {
        model.sequence { send in
            guard let state = Self.state(send),
                  let out = state.outputs.first(where: { if case .device = $0.sink { return true }; return false })
            else { return "Add an output first." }
            // An existing Patch Desktop is reused rather than made twice.
            let virtuals = send(["virtual-list"]).text
            var slot: Int
            if let line = virtuals.split(separator: "\n").first(where: { $0.hasSuffix("\tout\tPatch Desktop") }),
               let n = Self.slotOf(line) {
                slot = n
            } else {
                guard let free = Self.freeSlot(send) else { return "No free virtual device slot." }
                slot = free
                let r = send(["virtual-add", "\(slot)", "out", "Desktop"])
                if !r.ok { return r.text }
            }
            var strip = Self.state(send)?.strips.first { $0.source == .virtual(slot: slot) }
            if strip == nil {
                let r = send(["strip-add", "Desktop", "virtual", "\(slot)"])
                if !r.ok { return r.text }
                strip = Self.state(send)?.strips.first { $0.source == .virtual(slot: slot) }
            }
            guard let strip else { return "The Desktop strip didn't appear." }
            let r = send(["route", "strip", "\(strip.slot)", "out", "\(out.slot)", "1"])
            if !r.ok { return r.text }
            let d = Self.makeDefault("output", slot, send)
            return d.ok ? nil : d.text
        }
    }

    func setUpMic() {
        model.sequence { send in
            guard let state = Self.state(send) else { return "The engine didn't answer." }
            let mics = state.strips.filter { if case .device = $0.source { return true }; return false }
            guard !mics.isEmpty else { return "Add a microphone first." }
            guard let slot = Self.freeSlot(send) else { return "No free virtual device slot." }
            var r = send(["virtual-add", "\(slot)", "in", "Mic"])
            if !r.ok { return r.text }
            r = send(["out-add", "Mic", "virtual", "\(slot)"])
            if !r.ok { return r.text }
            guard let out = Self.state(send)?.outputs.first(where: { $0.sink == .virtual(slot: slot) })
            else { return "The Mic output didn't appear." }
            for m in mics {
                r = send(["route", "strip", "\(m.slot)", "out", "\(out.slot)", "1"])
                if !r.ok { return r.text }
            }
            let d = Self.makeDefault("input", slot, send)
            return d.ok ? nil : d.text
        }
    }
}
