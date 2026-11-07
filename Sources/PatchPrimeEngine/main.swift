// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// The engine helper: a background app, started by a LaunchAgent, that owns the audio
// engine, watches devices, keeps settings, and answers the GUI and patchprime-ctl.
// Audio carries on with every window closed.
//
// Everything here runs on the main queue. The realtime code is all in PPCore.

import AVFoundation
import CoreAudio
import Foundation
import PPCore
import PPShared

final class Engine: NSObject, PPEngineService, NSXPCListenerDelegate, @unchecked Sendable {
    let store = Store(folder: Store.defaultFolder)
    var settings = Settings()
    var devices: [AudioDeviceInfo] = []
    var core: OpaquePointer?
    var note: String?
    // What each slot is bound to now, so only real changes touch audio.
    var boundInputs: [Int: String] = [:]
    var boundOutputs: [Int: String] = [:]
    var offline: Set<String> = []
    let rateTimer = DispatchSource.makeTimerSource(queue: .main)
    var pendingSave: DispatchWorkItem?
    let meterTimer = DispatchSource.makeTimerSource(queue: .main)
    let clockTimer = DispatchSource.makeTimerSource(queue: .main)
    let signalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    var sharedMeters = SharedMeters(create: true)
    var peaks = [Float](repeating: 0, count: MeterLayout.count)
    var lastSound: [Int: Date] = [:]
    var boundSince: [Int: Date] = [:]
    var lastRateReading: [String: Double] = [:]
    var clockMarks: [(Double, Double)] = []
    var clockPpm = 0.0
    var clockText = "Patch Prime"

    func start() {
        let loaded = store.load()
        settings = loaded.settings
        note = loaded.note
        refreshDevices()
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            self?.refreshDevices()
        }
        // A dispatch timer: this process runs on dispatchMain, so a Timer would never fire.
        meterTimer.schedule(deadline: .now(), repeating: 1.0 / 30)
        meterTimer.setEventHandler { [weak self] in self?.updateMeters() }
        meterTimer.resume()
        clockTimer.schedule(deadline: .now(), repeating: 0.25)
        clockTimer.setEventHandler { [weak self] in self?.steerClock() }
        clockTimer.resume()
        signal(SIGTERM, SIG_IGN)
        signalSource.setEventHandler { [weak self] in self?.shutDown() }
        signalSource.resume()
        setDriverRate(ppm: 0)
        rateTimer.schedule(deadline: .now() + 120, repeating: 60)
        rateTimer.setEventHandler { [weak self] in self?.saveRates() }
        rateTimer.resume()
    }

    func startCoreIfPossible() {
        guard core == nil, let hidden = deviceForUID("PatchPrimeMac.Engine") else { return }
        let created = pp_engine_create(hidden, 48000)
        guard pp_engine_start(created) == 0 else {
            pp_engine_destroy(created)
            return
        }
        core = created
    }

    func refreshDevices() {
        let previous = devices
        devices = listAudioDevices()
        startCoreIfPossible()
        if let core {
            for gone in previous where !devices.contains(where: { $0.id == gone.id }) {
                pp_engine_device_lost(core, gone.id)
                boundInputs = boundInputs.filter { !$0.value.hasPrefix("device:\(gone.id):") }
                boundOutputs = boundOutputs.filter { !$0.value.hasPrefix("device:\(gone.id):") }
            }
        }
        apply()
    }

    func signatures() -> [DeviceSignature] {
        devices.filter { !$0.signature.uid.hasPrefix("PatchPrimeMac.") }.map(\.signature)
    }

    func resolve(_ signature: DeviceSignature) -> AudioDeviceInfo? {
        guard let match = DeviceSignature.match(signature, in: signatures()) else { return nil }
        return devices.first { $0.signature == match }
    }

    func key(_ endpoint: Endpoint) -> String? {
        switch endpoint {
        case let .virtual(slot):
            return "virtual:\(slot)"
        case let .device(signature, left, right):
            guard let device = resolve(signature) else { return nil }
            return "device:\(device.id):\(left):\(right)"
        }
    }

    /// Makes the engine match the settings. Safe to call at any time, and touches
    /// audio only where something differs.
    func apply() {
        guard let core, let mixer = pp_engine_mixer(core) else { return }
        offline = []
        for slot in 0..<Int(PP_MAX_INPUTS) {
            let strip = settings.strips.first { $0.slot == slot }
            let wanted = strip.flatMap { key($0.source) }
            if let strip, wanted == nil { offline.insert(strip.label) }
            if boundInputs[slot] != wanted {
                if boundInputs[slot] != nil { pp_engine_unbind_input(core, Int32(slot)) }
                boundInputs[slot] = nil
                if let strip, let wanted {
                    switch strip.source {
                    case let .virtual(s):
                        pp_engine_bind_input_virtual(core, Int32(slot), Int32(s))
                        boundInputs[slot] = wanted
                    case let .device(signature, left, right):
                        if let device = resolve(signature), bindInput(core, slot, device, left, right) {
                            boundInputs[slot] = wanted
                            boundSince[slot] = Date()
                            lastSound[slot] = nil
                        }
                    }
                }
            }
            pp_mixer_set_input_active(mixer, Int32(slot), strip == nil ? 0 : 1)
            pp_mixer_set_input_gain(mixer, Int32(slot), strip?.gain ?? 1)
            pp_mixer_set_input_mute(mixer, Int32(slot), (strip?.muted ?? false) ? 1 : 0)
            for bus in 0..<Int32(PP_MAX_BUSES) {
                pp_mixer_set_input_to_bus(mixer, Int32(slot), bus, strip?.busSends.first { $0.to == Int(bus) }?.gain ?? 0)
            }
            for output in 0..<Int32(PP_MAX_OUTPUTS) {
                pp_mixer_set_input_to_output(mixer, Int32(slot), output, strip?.outputSends.first { $0.to == Int(output) }?.gain ?? 0)
            }
        }
        for slot in 0..<Int(PP_MAX_BUSES) {
            let bus = settings.buses.first { $0.slot == slot }
            pp_mixer_set_bus_active(mixer, Int32(slot), bus == nil ? 0 : 1)
            pp_mixer_set_bus_gain(mixer, Int32(slot), bus?.gain ?? 1)
            pp_mixer_set_bus_mute(mixer, Int32(slot), (bus?.muted ?? false) ? 1 : 0)
            for output in 0..<Int32(PP_MAX_OUTPUTS) {
                pp_mixer_set_bus_to_output(mixer, Int32(slot), output, bus?.outputSends.first { $0.to == Int(output) }?.gain ?? 0)
            }
        }
        for slot in 0..<Int(PP_MAX_OUTPUTS) {
            let output = settings.outputs.first { $0.slot == slot }
            let wanted = output.flatMap { key($0.sink) }
            if let output, wanted == nil { offline.insert(output.label) }
            if boundOutputs[slot] != wanted {
                if boundOutputs[slot] != nil { pp_engine_unbind_output(core, Int32(slot)) }
                boundOutputs[slot] = nil
                if let output, let wanted {
                    switch output.sink {
                    case let .virtual(s):
                        pp_engine_bind_output_virtual(core, Int32(slot), Int32(s))
                        boundOutputs[slot] = wanted
                    case let .device(signature, left, right):
                        if let device = resolve(signature) {
                            let saved = settings.savedRates[device.signature.uid] ?? 0
                            if pp_engine_bind_output_device(core, Int32(slot), device.id, Int32(left), Int32(right), -saved) == 0 {
                                boundOutputs[slot] = wanted
                            }
                        }
                    }
                }
            }
            pp_mixer_set_output_active(mixer, Int32(slot), output == nil ? 0 : 1)
            pp_mixer_set_output_gain(mixer, Int32(slot), output?.gain ?? 1)
            pp_mixer_set_output_mute(mixer, Int32(slot), (output?.muted ?? false) ? 1 : 0)
        }
        pp_engine_enable_hardware_output(core, settings.hardwareOutputEnabled ? 1 : 0, settings.hardwareLimit)
    }

    func bindInput(_ core: OpaquePointer, _ slot: Int, _ device: AudioDeviceInfo, _ left: Int, _ right: Int) -> Bool {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in
                    DispatchQueue.main.async { [weak self] in self?.apply() }
                }
            } else {
                note = "Microphone access is off for PatchPrimeEngine. Turn it on in System Settings > Privacy & Security > Microphone."
            }
            return false
        }
        let saved = settings.savedRates[device.signature.uid] ?? 0
        return pp_engine_bind_input_device(core, Int32(slot), device.id, Int32(left), Int32(right), saved) == 0
    }

    /// A rate is saved only when two readings a minute apart agree, so a controller
    /// still settling can't store a wrong value.
    func saveRates() {
        guard let core else { return }
        var changed = false
        for strip in settings.strips {
            if case let .device(signature, _, _) = strip.source, let device = resolve(signature),
                settings.clockDevice == nil {
                let uid = device.signature.uid
                let ppm = pp_engine_input_ratio_ppm(core, Int32(strip.slot))
                if let last = lastRateReading[uid], ppm != 0, abs(last - ppm) < 1,
                    abs((settings.savedRates[uid] ?? 0) - ppm) > 0.5 {
                    settings.savedRates[uid] = ppm
                    changed = true
                }
                lastRateReading[uid] = ppm
            }
        }
        if changed { try? store.save(settings) }
    }

    func updateMeters() {
        guard let core, let mixer = pp_engine_mixer(core) else { return }
        let now = Date()
        for strip in settings.strips {
            let m = pp_mixer_read_input_meter(mixer, Int32(strip.slot))
            let peak = max(m.peakLeft, m.peakRight)
            peaks[MeterLayout.strip(strip.slot)] = peak
            if peak > 0 { lastSound[strip.slot] = now }
        }
        for bus in settings.buses {
            let m = pp_mixer_read_bus_meter(mixer, Int32(bus.slot))
            peaks[MeterLayout.bus(bus.slot)] = max(m.peakLeft, m.peakRight)
        }
        for output in settings.outputs {
            let m = pp_mixer_read_output_meter(mixer, Int32(output.slot))
            peaks[MeterLayout.output(output.slot)] = max(m.peakLeft, m.peakRight)
        }
        if let shared = sharedMeters {
            peaks.withUnsafeBufferPointer { shared.values.update(from: $0.baseAddress!, count: MeterLayout.count) }
        }
    }

    func silentStrips() -> [String] {
        let now = Date()
        return settings.strips.filter { strip in
            guard case .device = strip.source, !strip.muted, boundInputs[strip.slot] != nil,
                let since = boundSince[strip.slot], now.timeIntervalSince(since) > 3
            else { return false }
            let heard = lastSound[strip.slot] ?? .distantPast
            return now.timeIntervalSince(heard) > 3
        }.map(\.label)
    }

    /// Follows the chosen device's clock, if there is one: 4 readings a second, a 20 s
    /// fit, and never faster than 2 ppm a second, so nobody hears it move. If the device
    /// goes away, the same slew takes the driver back to free running.
    func steerClock() {
        guard let core else { return }
        var want = 0.0
        var text = "Patch Prime"
        if let wanted = settings.clockDevice {
            if let device = resolve(wanted) {
                var seconds = 0.0, sample = 0.0
                if pp_engine_device_clock(core, device.id, &seconds, &sample) == 1 {
                    if let last = clockMarks.last, seconds <= last.0 || sample < last.1 { clockMarks = [] }
                    clockMarks.append((seconds, sample))
                    clockMarks.removeAll { seconds - $0.0 > 20 }
                    if clockMarks.count >= 20, let fit = fitRate(clockMarks) {
                        want = fit
                        text = String(format: "%@, %.1f ppm", device.signature.name, want)
                    } else {
                        text = "\(device.signature.name), measuring"
                        want = clockPpm
                    }
                } else {
                    clockMarks = []
                    text = "Patch Prime (\(wanted.name) isn't in use)"
                }
            } else {
                clockMarks = []
                text = "Patch Prime (\(wanted.name) is offline)"
            }
        } else {
            clockMarks = []
        }
        clockText = text
        let step = 2.0 * 0.25
        let next = clockPpm + max(-step, min(step, want - clockPpm))
        if abs(next - clockPpm) > 0.01 {
            clockPpm = next
            setDriverRate(ppm: clockPpm)
        }
    }

    func fitRate(_ marks: [(Double, Double)]) -> Double? {
        let n = Double(marks.count)
        let x0 = marks[0].0, y0 = marks[0].1
        var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
        for (t, f) in marks {
            let x = t - x0, y = f - y0
            sx += x
            sy += y
            sxx += x * x
            sxy += x * y
        }
        let d = n * sxx - sx * sx
        guard d > 0 else { return nil }
        return ((n * sxy - sx * sy) / d / 48000 - 1) * 1e6
    }

    func shutDown() {
        pendingSave?.perform()
        setDriverRate(ppm: 0)
        SharedMeters.removeName()
        exit(0)
    }

    // MARK: Commands

    func commit(_ candidate: Settings, _ done: String, later: Bool = false) -> Reply {
        let problems = candidate.problems()
        guard problems.isEmpty else {
            return Reply(ok: false, text: problems.joined(separator: "\n"))
        }
        settings = candidate
        apply()
        pendingSave?.cancel()
        pendingSave = nil
        if later {
            // A fader sends many changes. Save once it stops, or it would use up
            // the backups in a second.
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                try? self.store.save(self.settings)
            }
            pendingSave = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
            return Reply(ok: true, text: done)
        }
        do {
            try store.save(settings)
        } catch {
            return Reply(ok: false, text: "couldn't save settings: \(error.localizedDescription)")
        }
        return Reply(ok: true, text: done)
    }

    func endpoint(_ words: ArraySlice<String>) -> (Endpoint?, String?) {
        let w = Array(words)
        if w.count == 2, w[0] == "virtual", let slot = Int(w[1]) {
            return (.virtual(slot: slot), nil)
        }
        guard w.count == 4, w[0] == "device", let left = Int(w[2]), let right = Int(w[3]) else {
            return (nil, "expected: device <name> <left> <right>, or virtual <slot>. Channels count from 1.")
        }
        guard let device = devices.first(where: { $0.signature.name == w[1] && !$0.signature.uid.hasPrefix("PatchPrimeMac.") }) else {
            return (nil, "no device called \"\(w[1])\"")
        }
        let available = max(device.inputs, device.outputs)
        guard left >= 1, right >= 1, left <= available, right <= available else {
            return (nil, "\(w[1]) has \(available) channels, so channel \(max(left, right)) doesn't exist")
        }
        return (.device(device.signature, left: left - 1, right: right - 1), nil)
    }

    func nextSlot(_ used: [Int], _ limit: Int) -> Int? {
        (0..<limit).first { !used.contains($0) }
    }

    func handle(_ w: [String]) -> Reply {
        var next = settings
        guard let verb = w.first else { return Reply(ok: false, text: "no command") }
        let args = w.dropFirst()
        switch verb {
        case "status":
            return Reply(ok: true, text: statusText())
        case "snapshot":
            let data = (try? JSONEncoder().encode(snapshot())) ?? Data()
            return Reply(ok: true, text: String(data: data, encoding: .utf8) ?? "{}")
        case "label" where args.count == 3:
            let a = Array(args)
            guard let slot = Int(a[1]) else { break }
            switch a[0] {
            case "strip":
                guard let i = next.strips.firstIndex(where: { $0.slot == slot }) else { break }
                next.strips[i].label = a[2]
            case "bus":
                guard let i = next.buses.firstIndex(where: { $0.slot == slot }) else { break }
                next.buses[i].label = a[2]
            case "out":
                guard let i = next.outputs.firstIndex(where: { $0.slot == slot }) else { break }
                next.outputs[i].label = a[2]
            default:
                break
            }
            return commit(next, "done")
        case "state":
            let data = (try? JSONEncoder().encode(settings)) ?? Data()
            return Reply(ok: true, text: String(data: data, encoding: .utf8) ?? "{}")
        case "devices":
            let lines = devices.filter { !$0.signature.uid.hasPrefix("PatchPrimeMac.") }.map {
                "\($0.signature.name)  [\($0.signature.transport)]  \($0.inputs) in, \($0.outputs) out, \(Int($0.rate)) Hz" + ($0.signature.serial.isEmpty ? "" : ", serial \($0.signature.serial)")
            }
            return Reply(ok: true, text: lines.joined(separator: "\n"))
        case "strip-add" where args.count >= 2:
            let (source, error) = endpoint(args.dropFirst())
            guard let source else { return Reply(ok: false, text: error ?? "bad source") }
            guard let slot = nextSlot(next.strips.map(\.slot), Int(PP_MAX_INPUTS)) else { return Reply(ok: false, text: "no strips left") }
            next.strips.append(Strip(slot: slot, label: args.first!, source: source))
            return commit(next, "strip \(slot) added")
        case "strip-remove" where args.count == 1:
            guard let slot = Int(args.first!) else { break }
            next.strips.removeAll { $0.slot == slot }
            return commit(next, "strip \(slot) removed")
        case "bus-add" where args.count == 1:
            guard let slot = nextSlot(next.buses.map(\.slot), Int(PP_MAX_BUSES)) else { return Reply(ok: false, text: "no buses left") }
            next.buses.append(Bus(slot: slot, label: args.first!))
            return commit(next, "bus \(slot) added")
        case "bus-remove" where args.count == 1:
            guard let slot = Int(args.first!) else { break }
            next.buses.removeAll { $0.slot == slot }
            for i in next.strips.indices { next.strips[i].busSends.removeAll { $0.to == slot } }
            return commit(next, "bus \(slot) removed")
        case "out-add" where args.count >= 2:
            let (sink, error) = endpoint(args.dropFirst())
            guard let sink else { return Reply(ok: false, text: error ?? "bad output") }
            guard let slot = nextSlot(next.outputs.map(\.slot), Int(PP_MAX_OUTPUTS)) else { return Reply(ok: false, text: "no outputs left") }
            next.outputs.append(Output(slot: slot, label: args.first!, sink: sink))
            return commit(next, "output \(slot) added")
        case "out-remove" where args.count == 1:
            guard let slot = Int(args.first!) else { break }
            next.outputs.removeAll { $0.slot == slot }
            for i in next.strips.indices { next.strips[i].outputSends.removeAll { $0.to == slot } }
            for i in next.buses.indices { next.buses[i].outputSends.removeAll { $0.to == slot } }
            return commit(next, "output \(slot) removed")
        case "send" where args.count == 4:
            // send strip <n> bus|out <n> <gain>, or send bus <n> out <n> <gain> is below
            break
        case "route" where args.count == 5:
            let a = Array(args)
            guard let from = Int(a[1]), let to = Int(a[3]), let gain = Float(a[4]) else { break }
            func update(_ sends: inout [Send]) {
                sends.removeAll { $0.to == to }
                if gain > 0 { sends.append(Send(to: to, gain: gain)) }
            }
            switch (a[0], a[2]) {
            case ("strip", "bus"):
                guard let i = next.strips.firstIndex(where: { $0.slot == from }) else { return Reply(ok: false, text: "no strip \(from)") }
                update(&next.strips[i].busSends)
            case ("strip", "out"):
                guard let i = next.strips.firstIndex(where: { $0.slot == from }) else { return Reply(ok: false, text: "no strip \(from)") }
                update(&next.strips[i].outputSends)
            case ("bus", "out"):
                guard let i = next.buses.firstIndex(where: { $0.slot == from }) else { return Reply(ok: false, text: "no bus \(from)") }
                update(&next.buses[i].outputSends)
            default:
                return Reply(ok: false, text: "route strip <n> bus|out <n> <gain>, or route bus <n> out <n> <gain>")
            }
            return commit(next, "routed")
        case "gain" where args.count == 3, "mute" where args.count == 3:
            let a = Array(args)
            guard let slot = Int(a[1]) else { break }
            let value = Float(a[2]) ?? 0
            let on = a[2] == "on"
            switch a[0] {
            case "strip":
                guard let i = next.strips.firstIndex(where: { $0.slot == slot }) else { return Reply(ok: false, text: "no such strip") }
                if verb == "gain" { next.strips[i].gain = value } else { next.strips[i].muted = on }
            case "bus":
                guard let i = next.buses.firstIndex(where: { $0.slot == slot }) else { return Reply(ok: false, text: "no such bus") }
                if verb == "gain" { next.buses[i].gain = value } else { next.buses[i].muted = on }
            case "out":
                guard let i = next.outputs.firstIndex(where: { $0.slot == slot }) else { return Reply(ok: false, text: "no such output") }
                if verb == "gain" { next.outputs[i].gain = value } else { next.outputs[i].muted = on }
            default:
                break
            }
            return commit(next, "done", later: verb == "gain")
        case "clock" where args.count == 1:
            if args.first == "patchprime" {
                next.clockDevice = nil
                return commit(next, "clock: Patch Prime")
            }
            guard let device = devices.first(where: { $0.signature.name == args.first && !$0.signature.uid.hasPrefix("PatchPrimeMac.") }) else {
                return Reply(ok: false, text: "no device called \"\(args.first!)\"")
            }
            if device.signature.transport == "Bluetooth" {
                return Reply(ok: false, text: "a Bluetooth device's clock isn't steady enough to follow")
            }
            next.clockDevice = device.signature
            return commit(next, "clock: \(device.signature.name)")
        case "default" where args.count == 2:
            let a = Array(args)
            guard let slot = Int(a[1]), let id = deviceForUID("PatchPrimeMac.Device.\(slot)") else {
                return Reply(ok: false, text: "no such virtual device")
            }
            let ok: Bool
            switch a[0] {
            case "output":
                ok = setDefaultDevice(.output, id)
                setDefaultDevice(.systemOutput, id)
            case "input":
                ok = setDefaultDevice(.input, id)
            default:
                return Reply(ok: false, text: "default output|input <slot>")
            }
            return Reply(ok: ok, text: ok ? "done" : "macOS refused that")
        case "default-device" where args.count == 2:
            let a = Array(args)
            guard let device = devices.first(where: { $0.signature.name == a[1] }) else {
                return Reply(ok: false, text: "no device called \"\(a[1])\"")
            }
            if a[0] == "input" {
                return Reply(ok: setDefaultDevice(.input, device.id), text: "done")
            }
            setDefaultDevice(.systemOutput, device.id)
            return Reply(ok: setDefaultDevice(.output, device.id), text: "done")
        case "hardware" where args.count == 1:
            next.hardwareOutputEnabled = args.first == "on"
            return commit(next, "hardware output \(next.hardwareOutputEnabled ? "ON" : "off")")
        case "virtual-list":
            return Reply(ok: true, text: driverList().isEmpty ? "no virtual devices" : driverList())
        case "virtual-add" where args.count >= 3, "virtual-rename" where args.count >= 2, "virtual-remove" where args.count == 1:
            let text = verb.replacingOccurrences(of: "virtual-", with: "") + " " + args.joined(separator: " ")
            let answer = driverCommand(text)
            return Reply(ok: answer == "ok", text: answer)
        case "help":
            return Reply(ok: true, text: """
            status | devices | state | hardware on|off
            strip-add <label> device <name> <left> <right>   channels count from 1
            strip-add <label> virtual <slot>                 audio apps play into that device
            out-add <label> device <name> <left> <right> | out-add <label> virtual <slot>
            bus-add <label>
            route strip <n> bus <n> <gain> | route strip <n> out <n> <gain> | route bus <n> out <n> <gain>
            gain strip|bus|out <n> <linear> | mute strip|bus|out <n> on|off
            clock patchprime | clock <device name>
            default output|input <virtual slot> | default-device output|input <device name>
            strip-remove <n> | bus-remove <n> | out-remove <n>
            virtual-list | virtual-add <slot> out|in <name> | virtual-rename <slot> <name> | virtual-remove <slot>
            """)
        default:
            break
        }
        return Reply(ok: false, text: "don't understand that. Try: help")
    }

    func snapshot() -> Snapshot {
        var snap = Snapshot()
        snap.running = core != nil
        snap.note = note
        snap.settings = settings
        snap.offline = Array(offline)
        snap.devices = devices.filter { !$0.signature.uid.hasPrefix("PatchPrimeMac.") }.map {
            DeviceRow(uid: $0.signature.uid, name: $0.signature.name, transport: $0.signature.transport,
                inputs: $0.inputs, outputs: $0.outputs)
        }
        snap.virtuals = driverList().split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3, let slot = Int(parts[0]) else { return nil }
            return VirtualRow(slot: slot, isOutput: parts[1] == "out", name: parts[2])
        }
        snap.silent = silentStrips()
        snap.clockText = clockText
        snap.defaultOutput = deviceName(defaultDevice(.output))
        snap.defaultInput = deviceName(defaultDevice(.input))
        if let core {
            let stats = pp_engine_stats(core)
            snap.underruns = stats.underruns
            snap.overruns = stats.overruns
            snap.relocks = stats.resyncs
        }
        return snap
    }

    func statusText() -> String {
        var lines: [String] = []
        if core == nil {
            lines.append("ENGINE NOT RUNNING: the driver isn't loaded")
            return lines.joined(separator: "\n")
        }
        guard let core else { return "" }
        let s = pp_engine_stats(core)
        lines.append("engine running; hardware output \(settings.hardwareOutputEnabled ? "ON" : "off")")
        lines.append(String(format: "cycles %llu, underruns %llu, overruns %llu, re-locks %llu, longest gap %.2f ms, %d devices open",
            s.cycles, s.underruns, s.overruns, s.resyncs, s.maxGapMs, s.devices))
        if let note { lines.append("NOTE: \(note)") }
        lines.append("clock: \(clockText)")
        func db(_ v: Float) -> String { v > 0 ? String(format: "%.1f dBFS", 20 * log10(v)) : "silent" }
        for strip in settings.strips {
            let state = offline.contains(strip.label) ? "OFFLINE" : db(peaks[MeterLayout.strip(strip.slot)])
            lines.append("strip \(strip.slot) \(strip.label): \(state)\(strip.muted ? " muted" : ""), ratio \(String(format: "%.2f", pp_engine_input_ratio_ppm(core, Int32(strip.slot)))) ppm")
        }
        for bus in settings.buses {
            lines.append("bus \(bus.slot) \(bus.label): \(db(peaks[MeterLayout.bus(bus.slot)]))\(bus.muted ? " muted" : "")")
        }
        for output in settings.outputs {
            let state = offline.contains(output.label) ? "OFFLINE" : db(peaks[MeterLayout.output(output.slot)])
            lines.append("output \(output.slot) \(output.label): \(state)\(output.muted ? " muted" : "")")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: XPC

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: PPEngineService.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func request(_ data: Data, reply: @escaping (Data) -> Void) {
        DispatchQueue.main.async {
            let words = (try? JSONDecoder().decode([String].self, from: data)) ?? []
            let answer = self.handle(words)
            reply((try? JSONEncoder().encode(answer)) ?? Data())
        }
    }
}

let engine = Engine()
let listener = NSXPCListener(machServiceName: engineMachService)
listener.delegate = engine
listener.resume()
DispatchQueue.main.async { engine.start() }
dispatchMain()
