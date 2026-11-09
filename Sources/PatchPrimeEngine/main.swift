// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// The engine helper: a background app, started by a LaunchAgent, that owns the audio
// engine, watches devices, keeps settings, and answers the GUI and patchprime-ctl.
// Audio carries on with every window closed.
//
// Everything here runs on the main queue. The realtime code is all in PPCore.

import AppKit
import AVFoundation
import CoreAudio
import Foundation
import PPCore
import PPDSP
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
    // Devices given their rate and buffer since the engine last started, with the
    // rate they had, so a change made elsewhere (Audio MIDI Setup) is noticed.
    var prepared: [AudioObjectID: Double] = [:]
    var watchedRates: Set<AudioObjectID> = []
    var pendingRestart: DispatchWorkItem?
    var engineRate = 0.0
    var engineBlock = 0
    // Recordings being written, by "s0", "b1", "o2"; whether those of a take are.
    var recordings: [String: Recording] = [:]
    var recordNote: String?
    // Health (see Health.swift): asleep between the Mac's sleep and its wake work;
    // the last try at starting the core.
    var asleep = false
    var wakeWork: DispatchWorkItem?
    var lastStartAttempt = Date.distantPast
    var player: Player?
    var padPlayers: [String: (player: Player, slot: Int)] = [:] // soundboard pads playing, by id
    // The built-in effects, and the chains last given to the mixer, by "s0", "b1", "o2",
    // so only a real change reaches it.
    let catalog: [EffectInfo] = {
        guard let text = pp_fx_catalog_json() else { return [] }
        defer { pp_fx_free_string(text) }
        return EffectCatalog.decode(String(cString: text))
    }()
    var presets = PresetStore(folder: Store.defaultFolder)
    let scenes = SceneStore(folder: Store.defaultFolder)
    var appliedFx: [String: String] = [:]
    var appliedSafety: [Int: Float] = [:]
    var appliedKeys: [String: Int] = [:]
    // Problems with how strips and outputs are wired, found afresh each time.
    var wiring: [String] = []
    let startedAt = Date().timeIntervalSince1970
    let scanner = PluginScanner()
    let plugins = PluginHost()
    /// What's cued: "s0", "b1", "o2". Not saved, as on Linux: cue is for the moment.
    var cued: Set<String> = []
    // Chains measuring their levels for an open editor, and when it last asked.
    // Measuring costs a little, so it stops a couple of seconds after the asking does.
    var metering: [String: Date] = [:]
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
    // The engine's own clock: its cycle count, and when it last moved.
    var lastCycles: UInt64 = 0
    var cyclesMoved = Date()
    var lastStallRestart = Date.distantPast
    var clockPpm = 0.0
    var clockText = "Patch Prime"

    func start() {
        scanner.changed = {} // the GUI polls the snapshot
        plugins.mixerNow = { [weak self] in self?.core.flatMap { pp_engine_mixer($0) } }
        plugins.stateChanged = { [weak self] key, state in self?.saveState(key, state) }
        plugins.goneNow = { [weak self] in
            guard let self, let core = self.core, let mixer = pp_engine_mixer(core) else { return }
            if self.plugins.reapDead(mixer) { self.apply() }
        }
        let loaded = store.load()
        settings = loaded.settings
        note = loaded.note
        if !presets.load() { note = presets.lastError }
        seedPads()
        refreshDevices()
        watchHealth()
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
        clockTimer.setEventHandler { [weak self] in
            self?.checkHealth()
            self?.steerClock()
            if let player = self?.player, player.finished { self?.stopPlayer() } // played to the end
            self?.tidyPads()
        }
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
        guard core == nil, !asleep, let hidden = deviceForUID("PatchPrimeMac.Engine") else { return }
        // The virtual devices all follow the hidden one's rate.
        if !setNominalRate(hidden, settings.sampleRate) {
            note = "The virtual devices didn't change to \(Int(settings.sampleRate)) Hz, so the engine runs at \(Int(nominalRate(hidden))) Hz."
        }
        let rate = nominalRate(hidden)
        let created = pp_engine_create(hidden, rate, Int32(settings.bufferFrames))
        let status = pp_engine_start(created)
        guard status == 0 else {
            pp_engine_destroy(created)
            engineLog.error("The audio core didn't start (error \(status, privacy: .public)); trying again in a few seconds.")
            return
        }
        core = created
        engineRate = rate
        plugins.rate = rate
        plugins.block = settings.bufferFrames
        engineBlock = settings.bufferFrames
        watchRate(hidden)
    }

    /// Stops the engine and starts it again with the current settings. Used for a new
    /// rate or buffer size; every route is bound again, so each device re-locks.
    func restartCore() {
        engineLog.notice("Restarting the audio core.")
        stopCore()
        lastStartAttempt = Date()
        startCoreIfPossible()
        apply()
    }

    /// Stops the audio core and lets go of everything bound to it.
    func stopCore() {
        pendingRestart?.cancel()
        pendingRestart = nil
        if core != nil, !recordings.isEmpty {
            // The mixer they tap is going: what was recorded until now is kept.
            for rec in recordings.values {
                rec.attached = false
                pp_tap_end(rec.tap)
            }
            recordNote = "Recording stopped: the engine restarted (a sample rate or buffer change, the Mac going to sleep, or macOS's audio system). What was recorded until then is kept."
        }
        stopPlayer() // its feed is the old mixer's, at the old rate
        stopAllPads()
        if let core { pp_engine_destroy(core) }
        core = nil
        plugins.releaseAll(now: true) // no audio thread has them now
        boundInputs = [:]
        boundOutputs = [:]
        prepared = [:]
        appliedFx = [:]
        appliedSafety = [:]
        appliedKeys = [:]
        metering = [:]
    }

    func restartSoon() {
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.restartCore() }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Before the engine first opens a device: its rate (to the engine's, unless it's
    /// told to keep its own or can't), then this process's buffer size on it.
    func prepare(_ device: AudioDeviceInfo) {
        guard prepared[device.id] == nil else { return }
        let uid = device.signature.uid
        if !settings.keepOwnRate.contains(uid), supportsRate(device.id, engineRate) {
            if !setNominalRate(device.id, engineRate) {
                note = "\(device.signature.name) didn't change to \(Int(engineRate)) Hz, so it's resampled."
            }
        }
        setBufferFrames(device.id, settings.buffer(for: uid))
        prepared[device.id] = nominalRate(device.id)
        watchRate(device.id)
    }

    /// If a device in use changes rate from outside, the engine starts again with it.
    /// If the hidden device does (someone set a virtual device's rate in Audio MIDI
    /// Setup), that becomes the setting.
    func watchRate(_ id: AudioObjectID) {
        guard !watchedRates.contains(id) else { return }
        watchedRates.insert(id)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(id, &address, .main) { [weak self] _, _ in
            guard let self, self.core != nil else { return }
            let now = nominalRate(id)
            if id == deviceForUID("PatchPrimeMac.Engine") {
                if abs(now - self.engineRate) > 0.5, Settings.rates.contains(now) {
                    var next = self.settings
                    next.sampleRate = now
                    self.settings = next
                    try? self.store.save(next)
                    self.restartSoon()
                }
            } else if let was = self.prepared[id], abs(now - was) > 0.5 {
                self.restartSoon()
            }
        }
    }

    func refreshDevices() {
        let previous = devices
        devices = listAudioDevices()
        startCoreIfPossible()
        if let core {
            for gone in previous where !devices.contains(where: { $0.id == gone.id }) {
                pp_engine_device_lost(core, gone.id)
                prepared[gone.id] = nil
                watchedRates.remove(gone.id)
                boundInputs = boundInputs.filter { !$0.value.hasPrefix("device:\(gone.id):") }
                boundOutputs = boundOutputs.filter { !$0.value.hasPrefix("device:\(gone.id):") }
            }
        }
        apply()
    }

    func signatures() -> [DeviceSignature] {
        devices.filter { !$0.signature.uid.hasPrefix("PatchPrimeMac.") }.map(\.signature)
    }

    enum Side { case input, output }

    /// A saved device, found again. With a side, only devices with that side are
    /// looked at (apart from the exact one saved, so a strip saved against the wrong
    /// half still shows why it's silent): a device macOS splits into an input half
    /// and an output half with the same name and serial (a radio's USB codec) is then
    /// found again even when its UIDs change, after it's moved to another port.
    func resolve(_ signature: DeviceSignature, _ side: Side? = nil) -> AudioDeviceInfo? {
        let candidates = devices.filter { d in
            guard !d.signature.uid.hasPrefix("PatchPrimeMac.") else { return false }
            switch side {
            case nil: return true
            case .input: return d.inputs > 0 || d.signature.uid == signature.uid
            case .output: return d.outputs > 0 || d.signature.uid == signature.uid
            }
        }
        guard let match = DeviceSignature.match(signature, in: candidates.map(\.signature)) else { return nil }
        return devices.first { $0.signature == match }
    }

    /// A device a command names: by its UID, or by its name. A name two devices share
    /// (the halves of a radio's USB codec) needs a side to tell them apart, or the UID.
    func named(_ text: String, _ side: Side? = nil) -> (AudioDeviceInfo?, String?) {
        let real = devices.filter { !$0.signature.uid.hasPrefix("PatchPrimeMac.") }
        if let exact = real.first(where: { $0.signature.uid == text }) { return (exact, nil) }
        var same = real.filter { $0.signature.name == text }
        guard !same.isEmpty else { return (nil, "no device called \"\(text)\"") }
        if let side { same = same.filter { side == .input ? $0.inputs > 0 : $0.outputs > 0 } }
        guard !same.isEmpty else { return (nil, "\(text) has no \(side == .input ? "inputs" : "outputs")") }
        guard same.count == 1 else {
            return (nil, "\(same.count) devices are called \"\(text)\"; give its UID instead (patchprime-ctl devices lists them)")
        }
        return (same[0], nil)
    }

    func key(_ endpoint: Endpoint, _ side: Side) -> String? {
        switch endpoint {
        case let .virtual(slot):
            return "virtual:\(slot)"
        case let .device(signature, left, right):
            guard let device = resolve(signature, side) else { return nil }
            return "device:\(device.id):\(left):\(right)"
        }
    }

    /// Makes the engine match the settings. Safe to call at any time, and touches
    /// audio only where something differs.
    func apply() {
        guard let core, let mixer = pp_engine_mixer(core) else { return }
        // A strip, bus or output that's gone stops recording.
        let gone = recordings.keys.filter { label(of: $0) == nil }
        if !gone.isEmpty { stopRecording(gone) }
        retargetPlayer()
        tidyPads()
        offline = []
        wiring = []
        for slot in 0..<Int(PP_MAX_INPUTS) {
            let strip = settings.strips.first { $0.slot == slot }
            var wanted = strip.flatMap { key($0.source, .input) }
            if let strip, case let .device(signature, _, _) = strip.source, let d = resolve(signature, .input), d.inputs == 0 {
                // Saved against a device's output half (an older version could do that).
                wanted = nil
                wiring.append("\(strip.label) is set to \(d.signature.name)'s output side, which has no inputs. Choose its input side.")
            }
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
                        if let device = resolve(signature, .input), bindInput(core, slot, device, left, right) {
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
            var wanted = output.flatMap { key($0.sink, .output) }
            if let output, case let .device(signature, _, _) = output.sink, let d = resolve(signature, .output), d.outputs == 0 {
                wanted = nil
                wiring.append("\(output.label) is set to \(d.signature.name)'s input side, which has no outputs. Choose its output side.")
            }
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
                        if let device = resolve(signature, .output) {
                            prepare(device)
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
        applyEffects(mixer)
        applyCue(mixer)
        syncDeviceNames()

        pp_engine_enable_hardware_output(core, settings.hardwareOutputEnabled ? 1 : 0, settings.hardwareLimit)
    }

    /// Where a plugin key points: "s0#2#au:...#1" is strip 0, effect 2.
    func place(_ key: String) -> (verb: String, slot: Int, index: Int, type: String)? {
        let parts = key.split(separator: "#").map(String.init)
        guard parts.count >= 3, let first = parts[0].first, let slot = Int(parts[0].dropFirst()), let index = Int(parts[1]),
              let verb = ["s": "strip", "b": "bus", "o": "out"][String(first)] else { return nil }
        return (verb, slot, index, parts[2])
    }

    /// A plugin's own state, saved into its chain (it's what the plugin's window changed).
    func saveState(_ key: String, _ state: String) {
        guard let p = place(key) else { return }
        var next = settings
        _ = editChain(&next, p.verb, p.slot) { chain in
            guard chain.indices.contains(p.index), chain[p.index].type == p.type else { return "moved" }
            chain[p.index].state = state
            return nil
        }
        if next != settings { _ = commit(next, "saved", later: true) }
    }

    /// Every loaded plugin's state into the settings now, before they're saved somewhere.
    func captureStates() {
        for (key, state) in plugins.allStates() { saveState(key, state) }
        pendingSave?.perform()
    }

    /// Plugins that aren't running, and why: read fresh each time.
    var pluginNotes: [String] {
        plugins.problems.sorted { $0.key < $1.key }.map { key, problem in
            let parts = key.split(separator: "#")
            let name = allEffects.first { $0.type == String(parts.count > 2 ? parts[2] : "") }?.plugin ?? "A plugin"
            return "\(name): \(problem)"
        }
    }

    var allEffects: [EffectSetting] {
        settings.strips.flatMap(\.effects) + settings.buses.flatMap(\.effects) + settings.outputs.flatMap(\.effects)
    }

    // MARK: Virtual device names

    /// macOS shows each virtual device as "Patch <label>": the label of the strip or output
    /// that uses it, so one name covers both. A device nothing uses keeps its own name.
    static let devicePrefix = "Patch "
    var appliedNames: [Int: String] = [:]
    var lastWantedNames: [Int: String] = [:]

    static func bare(_ name: String) -> String {
        name.hasPrefix(devicePrefix) ? String(name.dropFirst(devicePrefix.count)) : name
    }

    func virtualDevices() -> [(slot: Int, output: Bool, name: String)] {
        driverList().split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3, let slot = Int(parts[0]) else { return nil }
            return (slot, parts[1] == "out", parts[2])
        }
    }

    func syncDeviceNames() {
        var wanted: [Int: String] = [:]
        for strip in settings.strips { if case let .virtual(slot) = strip.source, wanted[slot] == nil { wanted[slot] = strip.label } }
        for output in settings.outputs { if case let .virtual(slot) = output.sink, wanted[slot] == nil { wanted[slot] = output.label } }
        // Only ask the driver when the names wanted have changed (apply runs for every fader move).
        guard wanted != lastWantedNames || appliedNames.isEmpty else { return }
        lastWantedNames = wanted
        for device in virtualDevices() {
            let name = Self.devicePrefix + Self.bare(wanted[device.slot] ?? device.name)
            if device.name != name { _ = driverCommand("rename \(device.slot) \(name)") }
            appliedNames[device.slot] = name
        }
    }

    func applyCue(_ mixer: OpaquePointer) {
        // Cued things that are gone, or cue switched off, uncue.
        let exists = Set(settings.strips.map { "s\($0.slot)" } + settings.buses.map { "b\($0.slot)" }
            + settings.outputs.filter { $0.slot != settings.cueOutput }.map { "o\($0.slot)" })
        cued = settings.cueOutput == nil ? [] : cued.intersection(exists)
        pp_mixer_set_cue_output(mixer, Int32(settings.cueOutput ?? -1))
        pp_mixer_set_cue_level(mixer, Float(pow(10, settings.cueLevelDb / 20)))
        pp_mixer_set_cue_pre_fader(mixer, settings.cuePreFader ? 1 : 0)
        for slot in 0..<Int(PP_MAX_INPUTS) { pp_mixer_set_cued(mixer, Int32(PP_KIND_STRIP), Int32(slot), cued.contains("s\(slot)") ? 1 : 0) }
        for slot in 0..<Int(PP_MAX_BUSES) { pp_mixer_set_cued(mixer, Int32(PP_KIND_BUS), Int32(slot), cued.contains("b\(slot)") ? 1 : 0) }
        for slot in 0..<Int(PP_MAX_OUTPUTS) { pp_mixer_set_cued(mixer, Int32(PP_KIND_OUTPUT), Int32(slot), cued.contains("o\(slot)") ? 1 : 0) }
    }

    func applyEffects(_ mixer: OpaquePointer) {
        func set(_ key: String, _ kind: Int32, _ slot: Int, _ effects: [EffectSetting], _ on: Bool = true, _ mono: Bool = false) {
            let spec = effects.spec(on: on)
            let marked = (mono ? "mono\n" : "") + spec
            guard appliedFx[key] != marked else { return }
            if pp_mixer_set_effects(mixer, kind, Int32(slot), spec) >= 0 {
                appliedFx[key] = marked
            }
        }
        // Plugins: what each chain holds, where.
        var wantedPlugins: [String: (kind: Int32, slot: Int, index: Int, effect: EffectSetting, channels: Int)] = [:]
        func plugins(_ chain: String, _ kind: Int32, _ slot: Int, _ effects: [EffectSetting], mono: Bool) {
            for (i, e) in effects.enumerated() where e.isPlugin {
                wantedPlugins[PluginHost.key(chain, i, e, mono ? 1 : 2)] = (kind, slot, i, e, mono ? 1 : 2)
            }
        }
        for strip in settings.strips {
            plugins("s\(strip.slot)", Int32(PP_KIND_STRIP), strip.slot, strip.effects, mono: appliedFx["s\(strip.slot)"]?.hasPrefix("mono\n") ?? false)
        }
        for bus in settings.buses { plugins("b\(bus.slot)", Int32(PP_KIND_BUS), bus.slot, bus.effects, mono: false) }
        for output in settings.outputs { plugins("o\(output.slot)", Int32(PP_KIND_OUTPUT), output.slot, output.effects, mono: false) }
        self.plugins.sync(mixer, wanted: wantedPlugins)
        func setKey(_ key: String, _ kind: Int32, _ slot: Int, _ effects: [EffectSetting]) {
            let from = effects.key ?? -1
            guard appliedKeys[key] != from else { return }
            if pp_mixer_set_key(mixer, kind, Int32(slot), Int32(from)) == 0 {
                appliedKeys[key] = from
            }
        }
        // Keys off first, then on, so a change can't look like a loop half way through.
        for strip in 0..<Int(PP_MAX_INPUTS) where (settings.strips.first { $0.slot == strip }?.effects.key ?? -1) == -1 {
            setKey("s\(strip)", Int32(PP_KIND_STRIP), strip, [])
        }
        for strip in settings.strips { setKey("s\(strip.slot)", Int32(PP_KIND_STRIP), strip.slot, strip.effects) }
        for slot in 0..<Int(PP_MAX_BUSES) { setKey("b\(slot)", Int32(PP_KIND_BUS), slot, settings.buses.first { $0.slot == slot }?.effects ?? []) }
        for slot in 0..<Int(PP_MAX_OUTPUTS) { setKey("o\(slot)", Int32(PP_KIND_OUTPUT), slot, settings.outputs.first { $0.slot == slot }?.effects ?? []) }
        for slot in 0..<Int(PP_MAX_INPUTS) {
            let strip = settings.strips.first { $0.slot == slot }
            // A one-channel source runs its effects once. The cache key carries it, so
            // switching between mono and stereo builds the chain again.
            // Not with a reverb (it spreads a mono voice into stereo) or a leveler (it
            // measures loudness over the channels it gets): those stay as they sounded.
            var mono = false
            if let strip, case let .device(_, left, right) = strip.source {
                mono = left == right && !strip.effects.contains { $0.type == "reverb" || $0.type == "leveler" }
                    && strip.effects.filter(\.isPlugin).allSatisfy { ($0.channels ?? "") == "m" }
            }
            pp_mixer_set_input_mono(mixer, Int32(slot), mono ? 1 : 0)
            set("s\(slot)", Int32(PP_KIND_STRIP), slot, strip?.effects ?? [], strip?.effectsOn ?? true, mono)
        }
        for slot in 0..<Int(PP_MAX_BUSES) {
            let bus = settings.buses.first { $0.slot == slot }
            set("b\(slot)", Int32(PP_KIND_BUS), slot, bus?.effects ?? [], bus?.effectsOn ?? true)
        }
        for slot in 0..<Int(PP_MAX_OUTPUTS) {
            let output = settings.outputs.first { $0.slot == slot }
            set("o\(slot)", Int32(PP_KIND_OUTPUT), slot, output?.effects ?? [], output?.effectsOn ?? true)
            // Hardware gets the safety limiter at the hardware limit; the hard clip
            // in the engine stays behind it.
            var ceiling: Float = 0
            if let output, case .device = output.sink, settings.hardwareLimit > 0, settings.hardwareLimit < 1 {
                ceiling = 20 * log10(settings.hardwareLimit)
            }
            if appliedSafety[slot] != ceiling {
                pp_mixer_set_output_safety(mixer, Int32(slot), ceiling)
                appliedSafety[slot] = ceiling
            }
        }
    }

    /// "s0", "b1", "o2" to the mixer's kind and slot.
    // MARK: Recording

    /// A strip's, bus's or output's name, by "s0", "b1", "o2", if it's there.
    func label(of key: String) -> String? {
        guard let (kind, slot) = chainAddress(key) else { return nil }
        switch Int(kind) {
        case Int(PP_KIND_STRIP): return settings.strips.first { $0.slot == slot }?.label
        case Int(PP_KIND_BUS): return settings.buses.first { $0.slot == slot }?.label
        default: return settings.outputs.first { $0.slot == slot }?.label
        }
    }

    /// Whether a strip's recording is after its effects and fader: a hardware input's
    /// as chosen; a virtual one's (Desktop), a bus's and an output's always.
    func recordsProcessed(_ key: String) -> Bool {
        guard key.hasPrefix("s"), let slot = Int(key.dropFirst()),
              let strip = settings.strips.first(where: { $0.slot == slot }) else { return true }
        if case .device = strip.source { return settings.recordProcessed }
        return true
    }

    /// Starts recording these, together: one file each, all from the same sample. A
    /// take puts them in a folder of their own.
    func startRecording(_ keys: [String], take: Bool) -> Reply {
        guard let core, let mixer = pp_engine_mixer(core), engineRate > 0 else {
            return Reply(ok: false, text: "the engine isn't running")
        }
        let format = RecordingFormat(rawValue: settings.recordFormat) ?? .flac
        guard format.allows(rate: engineRate) else {
            return Reply(ok: false, text: "AAC goes up to 48 kHz; the mixer runs at \(Int(engineRate / 1000)) kHz. Choose FLAC or WAV.")
        }
        let keys = keys.filter { recordings[$0] == nil && label(of: $0) != nil }
        guard !keys.isEmpty else { return Reply(ok: false, text: take ? "nothing armed to record" : "nothing to record") }
        let now = Date()
        var folder = RecordingFiles.folder
        if take {
            folder = RecordingFiles.unique(folder.appendingPathComponent("Take \(RecordingFiles.stamp(now))", isDirectory: true))
        }
        let start = pp_mixer_block(mixer) + 2 // the same block for every track
        var started: [String] = []
        for key in keys {
            guard let (kind, slot) = chainAddress(key), let name = label(of: key) else { continue }
            var mono = false
            if kind == Int32(PP_KIND_STRIP), let strip = settings.strips.first(where: { $0.slot == slot }),
               case let .device(_, left, right) = strip.source {
                mono = left == right
            }
            let processed = recordsProcessed(key)
            let latency = processed ? Int(pp_fx_latency(pp_mixer_effects(mixer, kind, Int32(slot)))) : 0
            let fileName = take ? "\(RecordingFiles.stem(name)).\(format.fileExtension)"
                                : "\(RecordingFiles.stem(name)) \(RecordingFiles.stamp(now)).\(format.fileExtension)"
            let url = RecordingFiles.reserve(folder.appendingPathComponent(fileName))
            guard let tap = pp_tap_create(mono ? 1 : 2, Int32(min(engineRate * 4, Double(1 << 20)))) else {
                try? FileManager.default.removeItem(at: url) // the empty file reserved for it
                continue
            }
            pp_tap_set_processed(tap, processed ? 1 : 0)
            pp_tap_set_window(tap, start, UInt64.max)
            guard pp_mixer_attach_tap(mixer, kind, Int32(slot), tap) == 0 else {
                pp_tap_destroy(tap)
                try? FileManager.default.removeItem(at: url)
                continue
            }
            let rec = Recording(key: key, tap: tap, url: url, take: take, format: format, rate: engineRate, latency: latency)
            recordings[key] = rec
            rec.start { [weak self] in self?.finished($0) }
            started.append(key)
        }
        recordNote = nil
        return started.isEmpty ? Reply(ok: false, text: "couldn't start recording")
                               : Reply(ok: true, text: "recording \(started.joined(separator: " "))")
    }

    /// Stops these recordings on the same block.
    func stopRecording(_ keys: [String]) {
        let block = core.flatMap { pp_engine_mixer($0) }.map { pp_mixer_block($0) + 1 } ?? 0
        for key in keys {
            guard let rec = recordings[key] else { continue }
            if block == 0 || !rec.attached { pp_tap_end(rec.tap) } else { rec.stop(atBlock: block) }
        }
    }

    /// A recording's file is closed: let its tap go once the audio thread is past it.
    func finished(_ rec: Recording) {
        if recordings[rec.key] === rec { recordings[rec.key] = nil }
        if let error = rec.error { recordNote = "Recording \(rec.url.lastPathComponent): \(error)" }
        if pp_tap_dropped(rec.tap) > 0 {
            recordNote = "\(rec.url.lastPathComponent): the disk couldn't keep up, so \(String(format: "%.1f", Double(pp_tap_dropped(rec.tap)) / max(1, engineRate))) s of it is silence (in its place, so a take's tracks still line up)."
        }
        let tap = rec.tap
        if rec.attached, let core, let mixer = pp_engine_mixer(core), let (kind, slot) = chainAddress(rec.key) {
            pp_mixer_detach_tap(mixer, kind, Int32(slot))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { pp_tap_destroy(tap) }
    }

    // MARK: Player

    /// Where the player plays: the chosen strip, bus or output, or the first bus (or
    /// output) when that's gone or none was chosen.
    func playTarget() -> String? {
        if !settings.playInto.isEmpty, label(of: settings.playInto) != nil { return settings.playInto }
        if let bus = settings.buses.first { return "b\(bus.slot)" }
        return settings.outputs.first.map { "o\($0.slot)" }
    }

    func play(_ path: String) -> Reply {
        stopPlayer()
        guard let core, let mixer = pp_engine_mixer(core), engineRate > 0 else {
            return Reply(ok: false, text: "the engine isn't running")
        }
        guard let target = playTarget(), let (kind, slot) = chainAddress(target) else {
            return Reply(ok: false, text: "there's nothing to play into: add a mix bus or an output")
        }
        let (opened, problem) = Player.open(URL(fileURLWithPath: path), rate: engineRate)
        guard let opened else { return Reply(ok: false, text: problem ?? "couldn't play that") }
        player = opened
        opened.start(looping: settings.playLoop)
        pp_mixer_set_feed(mixer, 0, opened.feed, kind, Int32(slot))
        return Reply(ok: true, text: "playing into \(label(of: target) ?? target)")
    }

    func stopPlayer() {
        guard let player else { return }
        self.player = nil
        if let core, let mixer = pp_engine_mixer(core) { pp_mixer_set_feed(mixer, 0, nil, 0, 0) }
        player.stop() // its thread frees the feed when it's done
    }

    /// Points the player at its target again (after the target changed).
    func retargetPlayer() {
        guard let player, let core, let mixer = pp_engine_mixer(core) else { return }
        guard let target = playTarget(), let (kind, slot) = chainAddress(target) else { stopPlayer(); return }
        pp_mixer_set_feed(mixer, 0, player.feed, kind, Int32(slot))
    }

    func chainAddress(_ key: String) -> (Int32, Int)? {
        guard let first = key.first, let slot = Int(key.dropFirst()) else { return nil }
        switch first {
        case "s": return (Int32(PP_KIND_STRIP), slot)
        case "b": return (Int32(PP_KIND_BUS), slot)
        case "o": return (Int32(PP_KIND_OUTPUT), slot)
        default: return nil
        }
    }

    /// Runs `change` on the chain a command names (strip|bus|out and a slot).
    func editChain(_ settings: inout Settings, _ kind: String, _ slot: Int,
        _ change: (inout [EffectSetting]) -> String?) -> String? {
        switch kind {
        case "strip":
            guard let i = settings.strips.firstIndex(where: { $0.slot == slot }) else { return "no strip \(slot)" }
            return change(&settings.strips[i].effects)
        case "bus":
            guard let i = settings.buses.firstIndex(where: { $0.slot == slot }) else { return "no bus \(slot)" }
            return change(&settings.buses[i].effects)
        case "out":
            guard let i = settings.outputs.firstIndex(where: { $0.slot == slot }) else { return "no output \(slot)" }
            return change(&settings.outputs[i].effects)
        default:
            return "strip, bus or out"
        }
    }

    /// Records which chain preset is on a strip, bus or output.
    func markPreset(_ settings: inout Settings, _ kind: String, _ slot: Int, _ name: String?) {
        switch kind {
        case "strip": if let i = settings.strips.firstIndex(where: { $0.slot == slot }) { settings.strips[i].preset = name }
        case "bus": if let i = settings.buses.firstIndex(where: { $0.slot == slot }) { settings.buses[i].preset = name }
        case "out": if let i = settings.outputs.firstIndex(where: { $0.slot == slot }) { settings.outputs[i].preset = name }
        default: break
        }
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
        prepare(device)
        let saved = settings.savedRates[device.signature.uid] ?? 0
        return pp_engine_bind_input_device(core, Int32(slot), device.id, Int32(left), Int32(right), saved) == 0
    }

    /// A rate is saved only when two readings a minute apart agree, so a controller
    /// still settling can't store a wrong value.
    func saveRates() {
        guard let core else { return }
        var changed = false
        for strip in settings.strips {
            if case let .device(signature, _, _) = strip.source, let device = resolve(signature, .input),
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
        // If the engine's clock stops (coreaudiod restarted, or another audio driver was
        // installed or removed under it), nothing else will start it again: it does so
        // here after 2 s, no more than once every 10 s.
        let cycles = pp_engine_stats(core).cycles
        if cycles != lastCycles {
            lastCycles = cycles
            cyclesMoved = Date()
        } else if Date().timeIntervalSince(cyclesMoved) > 2, Date().timeIntervalSince(lastStallRestart) > 10 {
            lastStallRestart = Date()
            cyclesMoved = Date()
            lastCycles = 0
            note = "The engine's clock stopped (macOS's audio system changed under it), so it was restarted."
            engineLog.notice("The engine's clock stopped; restarting.")
            restartCore()
            return
        }
        if let mixer = pp_engine_mixer(core) {
            pp_mixer_collect(mixer)
            if plugins.reapDead(mixer) { apply() } // load them again
            let now = Date()
            for (key, asked) in metering where now.timeIntervalSince(asked) > 2 {
                if let (kind, slot) = chainAddress(key), let fx = pp_mixer_effects(mixer, kind, Int32(slot)) {
                    pp_fx_set_metering(fx, 0)
                }
                metering[key] = nil
            }
        }
        var want = 0.0
        var text = "Patch Prime"
        if let wanted = settings.clockDevice {
            // A split device moved to another port matches both halves by serial; they
            // share one clock, so the input half will do.
            if let device = resolve(wanted) ?? resolve(wanted, .input) {
                var seconds = 0.0, sample = 0.0
                if pp_engine_device_clock(core, device.id, &seconds, &sample) == 1 {
                    if let last = clockMarks.last, seconds <= last.0 || sample < last.1 { clockMarks = [] }
                    clockMarks.append((seconds, sample))
                    clockMarks.removeAll { seconds - $0.0 > 20 }
                    if clockMarks.count >= 20, let fit = fitRate(clockMarks, nominal: nominalRate(device.id)) {
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

    func fitRate(_ marks: [(Double, Double)], nominal: Double) -> Double? {
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
        return ((n * sxy - sx * sy) / d / nominal - 1) * 1e6
    }

    func shutDown() {
        captureStates()
        pendingSave?.perform()
        // Recordings get their files finished, so they open (a FLAC or AAC file cut off
        // part way may not).
        for rec in recordings.values { pp_tap_end(rec.tap) }
        let asked = Date()
        while recordings.values.contains(where: { !$0.isClosed }), Date().timeIntervalSince(asked) < 3 {
            Thread.sleep(forTimeInterval: 0.02)
        }
        stopPlayer()
        stopAllPads()
        if let core { pp_engine_destroy(core) }
        core = nil
        plugins.releaseAll(now: true)
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
        let restart = candidate.sampleRate != settings.sampleRate || candidate.bufferFrames != settings.bufferFrames
            || candidate.deviceBuffers != settings.deviceBuffers || candidate.keepOwnRate != settings.keepOwnRate
        settings = candidate
        if restart, core != nil {
            restartCore()
        } else {
            apply()
        }
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

    /// A device by name, for a strip (it must have inputs) or an output (outputs). Some
    /// devices show up twice under one name, an input half and an output half (a USB
    /// CODEC such as a radio's): the direction picks the right one.
    func endpoint(_ words: ArraySlice<String>, input: Bool) -> (Endpoint?, String?) {
        let w = Array(words)
        if w.count == 2, w[0] == "virtual", let slot = Int(w[1]) {
            return (.virtual(slot: slot), nil)
        }
        guard w.count == 4, w[0] == "device", let left = Int(w[2]), let right = Int(w[3]) else {
            return (nil, "expected: device <name> <left> <right>, or virtual <slot>. Channels count from 1.")
        }
        let named = devices.filter { ($0.signature.name == w[1] || $0.signature.uid == w[1]) && !$0.signature.uid.hasPrefix("PatchPrimeMac.") }
        guard !named.isEmpty else { return (nil, "no device called \"\(w[1])\"") }
        guard let device = named.first(where: { input ? $0.inputs > 0 : $0.outputs > 0 }) else {
            return (nil, "\(w[1]) has no \(input ? "inputs" : "outputs")")
        }
        let available = input ? device.inputs : device.outputs
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
        if let reply = handlePads(verb, Array(args), &next) { return reply }
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
        case "move" where args.count == 3:
            // move strip|bus|out <slot> <steps>: shifts it within its own section (negative
            // is left). Only the order on screen changes; routing and effects follow the slot.
            let a = Array(args)
            guard let slot = Int(a[1]), let steps = Int(a[2]) else { break }
            func shift<T>(_ list: inout [T], _ slotOf: (T) -> Int) -> Bool {
                guard let i = list.firstIndex(where: { slotOf($0) == slot }) else { return false }
                let to = min(max(i + steps, 0), list.count - 1)
                if to != i { list.insert(list.remove(at: i), at: to) }
                return true
            }
            let found: Bool
            switch a[0] {
            case "strip": found = shift(&next.strips, \.slot)
            case "bus": found = shift(&next.buses, \.slot)
            case "out": found = shift(&next.outputs, \.slot)
            default: return Reply(ok: false, text: "move strip|bus|out <slot> <steps>")
            }
            return found ? commit(next, "done") : Reply(ok: false, text: "no \(a[0]) \(slot)")
        case "record" where args.count == 2:
            // record strip|bus|out <slot>: starts or stops recording it alone; stopping
            // a take's track stops the whole take.
            let a = Array(args)
            let prefix = ["strip": "s", "bus": "b", "out": "o"][a[0]] ?? ""
            guard !prefix.isEmpty, let slot = Int(a[1]) else { break }
            let key = prefix + "\(slot)"
            if let rec = recordings[key] {
                stopRecording(rec.take ? recordings.values.filter(\.take).map(\.key) : [key])
                return Reply(ok: true, text: "stopping")
            }
            return startRecording([key], take: false)
        case "take" where args.count <= 1:
            // take [start|stop]: records every armed strip together, or stops the take.
            let takeKeys = recordings.values.filter(\.take).map(\.key)
            if !takeKeys.isEmpty, args.first != "start" {
                stopRecording(takeKeys)
                return Reply(ok: true, text: "stopping the take")
            }
            guard takeKeys.isEmpty, args.first != "stop" else { return Reply(ok: true, text: "done") }
            return startRecording(settings.armed, take: true)
        case "arm" where args.count == 3:
            let a = Array(args)
            let prefix = ["strip": "s", "bus": "b", "out": "o"][a[0]] ?? ""
            guard !prefix.isEmpty, let slot = Int(a[1]), a[2] == "on" || a[2] == "off" else { break }
            let key = prefix + "\(slot)"
            next.armed.removeAll { $0 == key }
            if a[2] == "on" { next.armed.append(key) }
            return commit(next, "done")
        case "multitrack" where args.count == 1:
            guard args.first == "on" || args.first == "off" else { break }
            next.multitrack = args.first == "on"
            return commit(next, "done")
        case "play" where args.count >= 1:
            return play(args.joined(separator: " "))
        case "play-stop":
            stopPlayer()
            return Reply(ok: true, text: "stopped")
        case "play-pause" where args.count == 1:
            guard let player, args.first == "on" || args.first == "off" else { return Reply(ok: false, text: "nothing is playing") }
            player.setPaused(args.first == "on")
            return Reply(ok: true, text: "done")
        case "play-seek" where args.count == 1:
            guard let player, let seconds = Double(args.first!) else { return Reply(ok: false, text: "nothing is playing") }
            player.seek(seconds)
            return Reply(ok: true, text: "done")
        case "play-loop" where args.count == 1:
            guard args.first == "on" || args.first == "off" else { break }
            next.playLoop = args.first == "on"
            player?.setLooping(next.playLoop)
            return commit(next, "done")
        case "play-into" where args.count == 2:
            let a = Array(args)
            let prefix = ["strip": "s", "bus": "b", "out": "o"][a[0]] ?? ""
            guard !prefix.isEmpty, let slot = Int(a[1]), label(of: prefix + "\(slot)") != nil else {
                return Reply(ok: false, text: "play-into strip|bus|out <n>")
            }
            next.playInto = prefix + "\(slot)"
            let reply = commit(next, "done")
            retargetPlayer()
            return reply
        case "record-format" where args.count == 1:
            guard let format = RecordingFormat(rawValue: args.first!) else { return Reply(ok: false, text: "record-format flac|wav|aac") }
            next.recordFormat = format.rawValue
            return commit(next, "done; the next recording is \(format.rawValue.uppercased())")
        case "record-inputs" where args.count == 1:
            guard args.first == "raw" || args.first == "processed" else { return Reply(ok: false, text: "record-inputs raw|processed") }
            next.recordProcessed = args.first == "processed"
            let reply = commit(next, "done")
            // At once, also for a recording already running.
            for rec in recordings.values { pp_tap_set_processed(rec.tap, recordsProcessed(rec.key) ? 1 : 0) }
            return reply
        case "state":
            let data = (try? JSONEncoder().encode(settings)) ?? Data()
            return Reply(ok: true, text: String(data: data, encoding: .utf8) ?? "{}")
        case "devices":
            let lines = devices.filter { !$0.signature.uid.hasPrefix("PatchPrimeMac.") }.map {
                "\($0.signature.name)  [\($0.signature.transport)]  \($0.inputs) in, \($0.outputs) out, \(Int($0.rate)) Hz" + ($0.signature.serial.isEmpty ? "" : ", serial \($0.signature.serial)") + "\n    uid \($0.signature.uid)"
            }
            return Reply(ok: true, text: lines.joined(separator: "\n"))
        case "strip-add" where args.count >= 2:
            let (source, error) = endpoint(args.dropFirst(), input: true)
            guard let source else { return Reply(ok: false, text: error ?? "bad source") }
            guard let slot = nextSlot(next.strips.map(\.slot), Int(PP_MAX_INPUTS)) else { return Reply(ok: false, text: "no strips left") }
            next.strips.append(Strip(slot: slot, label: Self.bare(args.first!), source: source))
            return commit(next, "strip \(slot) added")
        case "strip-source" where args.count >= 3, "out-sink" where args.count >= 3:
            // Points an existing strip or output at another device, keeping its sends,
            // effects and level: strip-source <n> device <name> <left> <right>.
            let a = Array(args)
            guard let slot = Int(a[0]) else { break }
            let (endpoint, error) = endpoint(args.dropFirst(), input: verb == "strip-source")
            guard let endpoint else { return Reply(ok: false, text: error ?? "bad device") }
            if verb == "strip-source" {
                guard let i = next.strips.firstIndex(where: { $0.slot == slot }) else { return Reply(ok: false, text: "no strip \(slot)") }
                next.strips[i].source = endpoint
            } else {
                guard let i = next.outputs.firstIndex(where: { $0.slot == slot }) else { return Reply(ok: false, text: "no output \(slot)") }
                next.outputs[i].sink = endpoint
            }
            return commit(next, "done")
        case "strip-remove" where args.count == 1:
            guard let slot = Int(args.first!) else { break }
            next.strips.removeAll { $0.slot == slot }
            // Duckers that listened to it listen to nothing now.
            func unkey(_ chain: inout [EffectSetting]) { for i in chain.indices where chain[i].key == slot { chain[i].key = nil } }
            for i in next.strips.indices { unkey(&next.strips[i].effects) }
            for i in next.buses.indices { unkey(&next.buses[i].effects) }
            for i in next.outputs.indices { unkey(&next.outputs[i].effects) }
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
            let (sink, error) = endpoint(args.dropFirst(), input: false)
            guard let sink else { return Reply(ok: false, text: error ?? "bad output") }
            guard let slot = nextSlot(next.outputs.map(\.slot), Int(PP_MAX_OUTPUTS)) else { return Reply(ok: false, text: "no outputs left") }
            next.outputs.append(Output(slot: slot, label: Self.bare(args.first!), sink: sink))
            return commit(next, "output \(slot) added")
        case "out-remove" where args.count == 1:
            guard let slot = Int(args.first!) else { break }
            next.outputs.removeAll { $0.slot == slot }
            if next.cueOutput == slot { next.cueOutput = nil } // cue had nowhere to play
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
            let (found, problem) = named(args.first!)
            guard let device = found else { return Reply(ok: false, text: problem ?? "no such device") }
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
                rememberDefault(.output)
                rememberDefault(.systemOutput)
                ok = setDefaultDevice(.output, id)
                setDefaultDevice(.systemOutput, id)
            case "input":
                rememberDefault(.input)
                ok = setDefaultDevice(.input, id)
            default:
                return Reply(ok: false, text: "default output|input <slot>")
            }
            return Reply(ok: ok, text: ok ? "done" : "macOS refused that")
        case "default-device" where args.count == 2:
            let a = Array(args)
            // The half that fits: a device can show up as an input half and an output half.
            guard a[0] == "input" || a[0] == "output" else { return Reply(ok: false, text: "default-device input|output <name or UID>") }
            let (found, problem) = named(a[1], a[0] == "input" ? .input : .output)
            guard let device = found else { return Reply(ok: false, text: problem ?? "no such device") }
            if a[0] == "input" {
                return Reply(ok: setDefaultDevice(.input, device.id), text: "done")
            }
            setDefaultDevice(.systemOutput, device.id)
            return Reply(ok: setDefaultDevice(.output, device.id), text: "done")
        case "rate" where args.count == 1:
            guard let hz = Double(args.first!), Settings.rates.contains(hz) else {
                return Reply(ok: false, text: "rate 44100|48000|96000|192000")
            }
            next.sampleRate = hz
            return commit(next, "engine restarted at \(Int(hz)) Hz")
        case "buffer" where args.count == 1:
            guard let frames = Int(args.first!), Settings.buffers.contains(frames) else {
                return Reply(ok: false, text: "buffer 32|64|128|256|512|1024")
            }
            next.bufferFrames = frames
            return commit(next, "engine restarted with \(frames)-frame buffers")
        case "device-buffer" where args.count == 2, "device-rate" where args.count == 2:
            let a = Array(args)
            let (found, problem) = named(a[0])
            guard let device = found else { return Reply(ok: false, text: problem ?? "no such device") }
            let uid = device.signature.uid
            if verb == "device-rate" {
                switch a[1] {
                case "follow": next.keepOwnRate.remove(uid)
                case "own": next.keepOwnRate.insert(uid)
                default: return Reply(ok: false, text: "device-rate <name> follow|own")
                }
            } else if a[1] == "default" {
                next.deviceBuffers[uid] = nil
            } else if let frames = Int(a[1]), Settings.buffers.contains(frames) {
                next.deviceBuffers[uid] = frames
            } else {
                return Reply(ok: false, text: "device-buffer <name> 32|64|128|256|512|1024|default")
            }
            return commit(next, "done, engine restarted")
        case "effects-catalog":
            let data = (try? JSONEncoder().encode(catalog)) ?? Data()
            return Reply(ok: true, text: String(data: data, encoding: .utf8) ?? "[]")
        case "fx-add" where args.count >= 3, "fx-remove" where args.count == 3, "fx-move" where args.count == 4,
             "fx-set" where args.count == 5, "fx-on" where args.count == 4:
            let a = Array(args)
            guard let slot = Int(a[1]) else { break }
            var later = false
            var emptied = false
            let problem = editChain(&next, a[0], slot) { chain in
                switch verb {
                case "fx-add":
                    guard let info = catalog.first(where: { $0.type == a[2] }) else {
                        return "no effect called \(a[2]). Try: " + catalog.map(\.type).joined(separator: ", ")
                    }
                    guard chain.count < maxEffects else { return "that chain is full (\(maxEffects) effects)" }
                    let at = a.count > 3 ? min(max(Int(a[3]) ?? chain.count, 0), chain.count) : chain.count
                    chain.insert(info.fresh(), at: at)
                case "fx-remove":
                    guard let i = Int(a[2]), chain.indices.contains(i) else { return "no effect \(a[2])" }
                    chain.remove(at: i)
                    emptied = chain.isEmpty
                case "fx-move":
                    guard let from = Int(a[2]), let to = Int(a[3]), chain.indices.contains(from), chain.indices.contains(to)
                    else { return "no such effect" }
                    chain.insert(chain.remove(at: from), at: to)
                case "fx-on":
                    guard let i = Int(a[2]), chain.indices.contains(i) else { return "no effect \(a[2])" }
                    chain[i].enabled = a[3] == "on"
                default: // fx-set
                    guard let i = Int(a[2]), chain.indices.contains(i) else { return "no effect \(a[2])" }
                    guard let info = catalog.first(where: { $0.type == chain[i].type }),
                        let param = info.param(a[3]), let value = Double(a[4])
                    else { return "\(chain[i].type) has no parameter \(a[3])" }
                    chain[i].params[a[3]] = param.valid(value)
                    // The compressor's own controls start where its knob was.
                    if chain[i].type == "compressor", a[3] == "advanced", param.valid(value) == 1 {
                        var knob = [Double](repeating: 0, count: 5)
                        pp_fx_compressor_knob(chain[i].params["amount"] ?? 40, &knob)
                        for (n, name) in ["threshold", "ratio", "attack", "release", "makeup"].enumerated() {
                            if let p = info.param(name) { chain[i].params[name] = p.valid(knob[n]) }
                        }
                    }
                    later = true
                }
                return nil
            }
            if let problem { return Reply(ok: false, text: problem) }
            if emptied { markPreset(&next, a[0], slot, nil) } // no chain, so no preset on it
            return commit(next, "done", later: later)
        case "fx-key" where args.count == 4:
            // fx-key strip|bus|out <n> <i> <strip>|none: which strip a ducker listens to.
            let a = Array(args)
            guard let slot = Int(a[1]), let index = Int(a[2]) else { break }
            let from = a[3] == "none" ? nil : Int(a[3])
            if a[3] != "none", from == nil { return Reply(ok: false, text: "fx-key strip|bus|out <n> <i> <strip>|none") }
            if let problem = editChain(&next, a[0], slot, { chain in
                guard chain.indices.contains(index) else { return "no effect \(index)" }
                guard chain[index].type == "ducker" else { return "only a ducker listens to another strip" }
                chain[index].key = from
                return nil
            }) { return Reply(ok: false, text: problem) }
            return commit(next, from.map { "listening to strip \($0)" } ?? "listening to nothing")
        case "fx-meters" where args.count == 2:
            // Each effect's level in and out (linear peaks since the last ask) and its
            // own meters (gain reduction and so on), as JSON. Measuring starts with the
            // first ask and stops when the asking does.
            let a = Array(args)
            guard let slot = Int(a[1]), let core, let mixer = pp_engine_mixer(core) else { break }
            let prefix = ["strip": "s", "bus": "b", "out": "o"][a[0]] ?? ""
            let key = prefix + "\(slot)"
            guard let (kind, _) = chainAddress(key), let fx = pp_mixer_effects(mixer, kind, Int32(slot)) else {
                return Reply(ok: false, text: "fx-meters strip|bus|out <n>")
            }
            if metering[key] == nil { pp_fx_set_metering(fx, 1) }
            metering[key] = Date()
            let stride = Int(PP_FX_LEVEL_FLOATS)
            var levels = [Float](repeating: 0, count: stride * maxEffects)
            let n = Int(pp_fx_take_levels(fx, &levels, Int32(maxEffects)))
            var report = FxMeters()
            let keyPeak = pp_fx_key_peak(fx)
            report.key = keyPeak >= 0 ? keyPeak : nil
            report.keyRms = keyPeak >= 0 ? max(0, pp_fx_key_rms(fx)) : nil
            for i in 0..<n {
                let l = Array(levels[(i * stride)..<((i + 1) * stride)])
                let groups = min(2, max(1, Int(l[0])))
                var level = FxMeters.Level()
                level.inPeak = Array(l[1..<(1 + groups)])
                level.inRms = Array(l[3..<(3 + groups)])
                level.outPeak = Array(l[5..<(5 + groups)])
                level.outRms = Array(l[7..<(7 + groups)])
                report.levels.append(level)
                var own = [Float](repeating: 0, count: 16)
                let m = Int(pp_fx_take_meters(fx, Int32(i), &own, 16))
                report.meters.append(Array(own.prefix(m)))
            }
            let data = (try? JSONEncoder().encode(report)) ?? Data()
            return Reply(ok: true, text: String(data: data, encoding: .utf8) ?? "{}")
        case "fx-all" where args.count == 3:
            let a = Array(args)
            guard let slot = Int(a[1]), a[2] == "on" || a[2] == "off" else { break }
            let on = a[2] == "on"
            switch a[0] {
            case "strip":
                guard let i = next.strips.firstIndex(where: { $0.slot == slot }) else { return Reply(ok: false, text: "no strip \(slot)") }
                next.strips[i].effectsOn = on
            case "bus":
                guard let i = next.buses.firstIndex(where: { $0.slot == slot }) else { return Reply(ok: false, text: "no bus \(slot)") }
                next.buses[i].effectsOn = on
            case "out":
                guard let i = next.outputs.firstIndex(where: { $0.slot == slot }) else { return Reply(ok: false, text: "no output \(slot)") }
                next.outputs[i].effectsOn = on
            default:
                return Reply(ok: false, text: "fx-all strip|bus|out <n> on|off")
            }
            return commit(next, on ? "effects on" : "effects bypassed")
        case "fx-add-plugin" where args.count >= 3:
            // fx-add-plugin strip|bus|out <n> <plugin id> [position]: the version that
            // fits the chain (Waves' (m) on a mono mic, (s) on stereo).
            let a = Array(args)
            guard let slot = Int(a[1]) else { break }
            guard let entry = AudioUnitCatalog.list(kinds: [.effect, .musicEffect]).first(where: { $0.id == a[2] }) else {
                return Reply(ok: false, text: "no plugin \(a[2]). Try: plugins-list")
            }
            var monoSource = false
            if a[0] == "strip", let strip = next.strips.first(where: { $0.slot == slot }), case let .device(_, l, r) = strip.source {
                monoSource = l == r
            }
            guard let variant = entry.variant(channels: monoSource ? 1 : 2) else {
                return Reply(ok: false, text: "\(entry.name) only comes in surround versions")
            }
            var effect = EffectSetting(type: variant.id)
            effect.plugin = "\(entry.maker) \(entry.name)"
            effect.channels = variant.channels
            if let problem = editChain(&next, a[0], slot, { chain in
                guard chain.count < maxEffects else { return "that chain is full (\(maxEffects) effects)" }
                let at = a.count > 3 ? min(max(Int(a[3]) ?? chain.count, 0), chain.count) : chain.count
                chain.insert(effect, at: at)
                return nil
            }) { return Reply(ok: false, text: problem) }
            return commit(next, "added \(variant.name)")
        case "plugins-list":
            // Every plugin (the filter only marks what's hidden), with what the scan found.
            let filter = settings.pluginFilter
            let rows = AudioUnitCatalog.list().map { p -> PluginRow in
                let checks = p.variants.compactMap { scanner.cache.check($0, version: p.version) }
                let bad = checks.first { $0.status != .ok }
                return PluginRow(entry: p, status: scanner.cache.status(p), message: bad?.message ?? "",
                    hidden: !filter.shows(p), hasView: checks.contains { $0.hasView },
                    latencySeconds: checks.map(\.latencySeconds).max() ?? 0)
            }
            let data = (try? JSONEncoder().encode(rows)) ?? Data()
            return Reply(ok: true, text: String(data: data, encoding: .utf8) ?? "[]")
        case "plugins-scan" where args.count == 1:
            guard args.first == "new" || args.first == "all" else { return Reply(ok: false, text: "plugins-scan new|all") }
            scanner.start(AudioUnitCatalog.list(), filter: settings.pluginFilter, everything: args.first == "all")
            return Reply(ok: true, text: scanner.total == 0 ? "nothing to check" : "checking \(scanner.total) plugin variants, \(scanner.parallel) at a time")
        case "plugins-scan-stop":
            scanner.stop()
            return Reply(ok: true, text: "stopped")
        case "fx-window" where args.count == 4:
            // fx-window strip|bus|out <n> <i> open|close: the plugin's own window.
            let a = Array(args)
            guard let slot = Int(a[1]), let index = Int(a[2]), let prefix = ["strip": "s", "bus": "b", "out": "o"][a[0]] else { break }
            guard let key = plugins.loadedKeys.first(where: { place($0).map { $0.verb == a[0] && $0.slot == slot && $0.index == index } ?? false })
                ?? plugins.openWindows.first(where: { $0.hasPrefix("\(prefix)\(slot)#\(index)#") }) else {
                return Reply(ok: false, text: "no plugin loaded there (yet)")
            }
            if a[3] == "close" {
                plugins.closeWindow(key)
                return Reply(ok: true, text: "closed")
            }
            var label = ""
            switch a[0] {
            case "strip": label = next.strips.first { $0.slot == slot }?.label ?? ""
            case "bus": label = next.buses.first { $0.slot == slot }?.label ?? ""
            default: label = next.outputs.first { $0.slot == slot }?.label ?? ""
            }
            var chain: [EffectSetting] = []
            var copy = next
            _ = editChain(&copy, a[0], slot) { chain = $0; return nil }
            let name = chain.indices.contains(index) ? chain[index].plugin ?? "Plugin" : "Plugin"
            plugins.openWindow(key, title: "\(label): \(name)") { problem in
                if let problem { self.note = problem }
            }
            return Reply(ok: true, text: "opening")
        case "plugins-timing":
            return Reply(ok: true, text: (plugins.lastDead + plugins.timings).joined(separator: "\n"))
        case "plugins-host":
            return Reply(ok: true, text: "\(plugins.hostPID)")
        case "plugins-status":
            let s = scanner
            let line = s.scanning ? "scanning: \(s.done) of \(s.total); now \(s.current.joined(separator: ", "))" : "not scanning"
            let ok = s.cache.checks.values.filter { $0.status == .ok }.count
            let bad = s.cache.checks.values.filter { $0.status != .ok }
            var lines = [line, "checked: \(ok) ok, \(bad.count) not"]
            for (id, c) in s.cache.checks.sorted(by: { $0.key < $1.key }) where c.status != .ok {
                lines.append("  \(id): \(c.status.rawValue), \(c.message)")
            }
            return Reply(ok: true, text: lines.joined(separator: "\n"))
        case "plugin-filter" where args.count >= 3:
            // plugin-filter kind|maker|category|plugin <name> hide|show
            let a = Array(args)
            let name = a[1..<(a.count - 1)].joined(separator: " ")
            let hide = a.last == "hide"
            guard a.last == "hide" || a.last == "show" else { break }
            func change(_ set: inout Set<String>) { if hide { set.insert(name) } else { set.remove(name) } }
            switch a[0] {
            case "kind":
                guard let k = PluginKind(rawValue: name) else {
                    return Reply(ok: false, text: "kinds: " + PluginKind.allCases.map(\.rawValue).joined(separator: ", "))
                }
                if hide { next.pluginFilter.hiddenKinds.insert(k) } else { next.pluginFilter.hiddenKinds.remove(k) }
            case "maker": change(&next.pluginFilter.hiddenMakers)
            case "category": change(&next.pluginFilter.hiddenCategories)
            case "plugin": change(&next.pluginFilter.hiddenPlugins)
            default: return Reply(ok: false, text: "plugin-filter kind|maker|category|plugin <name> hide|show")
            }
            return commit(next, hide ? "hidden" : "shown")
        case "cue-output" where args.count == 1:
            if args.first == "off" {
                next.cueOutput = nil
                return commit(next, "cue off")
            }
            guard let slot = Int(args.first!), next.outputs.contains(where: { $0.slot == slot }) else {
                return Reply(ok: false, text: "cue-output <output>|off")
            }
            next.cueOutput = slot
            return commit(next, "cue plays to \(next.outputs.first { $0.slot == slot }!.label)")
        case "cue-mode" where args.count == 1:
            guard args.first == "pfl" || args.first == "afl" else { return Reply(ok: false, text: "cue-mode pfl|afl") }
            next.cuePreFader = args.first == "pfl"
            return commit(next, next.cuePreFader ? "cue before the fader" : "cue after the fader")
        case "cue-level" where args.count == 1:
            guard let db = Double(args.first!), db >= -60, db <= 12 else { return Reply(ok: false, text: "cue-level <dB, -60 to 12>") }
            next.cueLevelDb = db
            return commit(next, "done", later: true)
        case "cue" where args.count == 3:
            // cue strip|bus|out <n> on|off
            let a = Array(args)
            guard let slot = Int(a[1]), let prefix = ["strip": "s", "bus": "b", "out": "o"][a[0]], a[2] == "on" || a[2] == "off" else {
                return Reply(ok: false, text: "cue strip|bus|out <n> on|off")
            }
            guard settings.cueOutput != nil else { return Reply(ok: false, text: "choose a cue output first (cue-output <output>)") }
            let key = prefix + "\(slot)"
            if a[2] == "on" { cued.insert(key) } else { cued.remove(key) }
            apply()
            return Reply(ok: true, text: cued.isEmpty ? "nothing cued" : "cued: " + cued.sorted().joined(separator: ", "))
        case "cue-clear":
            cued = []
            apply()
            return Reply(ok: true, text: "nothing cued")
        case "scene-list":
            let names = scenes.names()
            return Reply(ok: true, text: names.isEmpty ? "no scenes" : names.map { $0 == settings.lastScene ? "\($0) (last loaded)" : $0 }.joined(separator: "\n"))
        case "scene-save" where args.count >= 1:
            captureStates()
            next = settings
            let name = PresetStore.clean(args.joined(separator: " "))
            func uid(_ kind: DefaultKind) -> String {
                let id = defaultDevice(kind)
                return id == kAudioObjectUnknown ? "" : stringProperty(id, kAudioDevicePropertyDeviceUID) ?? ""
            }
            let scene = MixScene(name: name, from: settings, defaultOutput: uid(.output), defaultInput: uid(.input))
            do {
                try scenes.save(scene)
            } catch {
                return Reply(ok: false, text: name.isEmpty ? "a scene needs a name" : "couldn't save the scene: \(error.localizedDescription)")
            }
            next.lastScene = name
            return commit(next, "saved \"\(name)\"")
        case "scene-load" where args.count >= 1:
            let name = args.joined(separator: " ")
            guard let scene = scenes.load(name) else { return Reply(ok: false, text: "no scene called \"\(name)\"") }
            var (loaded, count) = scene.applied(to: next)
            loaded.lastScene = scene.name
            // The defaults, if those devices are here; ours are remembered as usual.
            for (uid, kind) in [(scene.defaultOutput, DefaultKind.output), (scene.defaultInput, .input)] where !uid.isEmpty {
                guard let id = deviceForUID(uid), id != defaultDevice(kind) else { continue }
                if uid.hasPrefix("PatchPrimeMac.") {
                    rememberDefault(kind)
                    if kind == .output { rememberDefault(.systemOutput) }
                }
                setDefaultDevice(kind, id)
                if kind == .output { setDefaultDevice(.systemOutput, id) }
            }
            let reply = commit(loaded, "loaded \"\(scene.name)\": \(count) strips, buses and outputs")
            return reply
        case "scene-delete" where args.count >= 1:
            let name = args.joined(separator: " ")
            guard scenes.remove(name) else { return Reply(ok: false, text: "no scene called \"\(name)\"") }
            if PresetStore.clean(name) == settings.lastScene {
                next.lastScene = nil
                return commit(next, "deleted")
            }
            return Reply(ok: true, text: "deleted")
        case "preset-list":
            var lines = ["built in: " + BuiltInChains.names.joined(separator: ", "),
                "yours: " + (presets.chainNames.isEmpty ? "none" : presets.chainNames.joined(separator: ", "))]
            for (type, names) in presets.effectNames.sorted(by: { $0.key < $1.key }) {
                lines.append("\(type): " + names.joined(separator: ", "))
            }
            if let problem = presets.lastError { lines.append("NOTE: \(problem)") }
            return Reply(ok: true, text: lines.joined(separator: "\n"))
        case "preset-save" where args.count >= 3, "preset-load" where args.count >= 3:
            // preset-save|load strip|bus|out <n> <name...>
            let a = Array(args)
            guard let slot = Int(a[1]) else { break }
            let name = a[2...].joined(separator: " ")
            if verb == "preset-save" {
                captureStates()
                next = settings
                var current: [EffectSetting] = []
                var copy = next
                if let problem = editChain(&copy, a[0], slot, { current = $0; return nil }) {
                    return Reply(ok: false, text: problem)
                }
                guard !current.isEmpty else { return Reply(ok: false, text: "there are no effects to save") }
                guard presets.saveChain(name, current) else {
                    return Reply(ok: false, text: presets.lastError ?? "a preset needs a name")
                }
                markPreset(&next, a[0], slot, PresetStore.clean(name))
                return commit(next, "saved \"\(PresetStore.clean(name))\"")
            }
            guard let chain = presets.chain(name) else { return Reply(ok: false, text: "no preset called \"\(name)\"") }
            let known = chain.filter { e in catalog.contains { $0.type == e.type } }.prefix(maxEffects)
            if let problem = editChain(&next, a[0], slot, { chain in
                chain = known.map { e in
                    var e = e.filled(from: catalog)
                    if a[0] == "strip", e.key == slot { e.key = nil } // it can't listen to itself
                    return e
                }
                return nil
            }) {
                return Reply(ok: false, text: problem)
            }
            markPreset(&next, a[0], slot, PresetStore.clean(name))
            return commit(next, "loaded \"\(PresetStore.clean(name))\"")
        case "preset-delete" where args.count >= 1:
            let name = args.joined(separator: " ")
            if BuiltInChains.chain(PresetStore.clean(name)) != nil, presets.presets.chains[PresetStore.clean(name)] == nil {
                return Reply(ok: false, text: "the built-in presets can't be deleted")
            }
            return presets.removeChain(name) ? Reply(ok: true, text: "deleted") : Reply(ok: false, text: presets.lastError ?? "no preset called \"\(name)\"")
        case "fx-preset-save" where args.count >= 4, "fx-preset-load" where args.count >= 4:
            // fx-preset-save|load strip|bus|out <n> <i> <name...>
            let a = Array(args)
            guard let slot = Int(a[1]), let index = Int(a[2]) else { break }
            let name = a[3...].joined(separator: " ")
            if verb == "fx-preset-save" {
                captureStates()
                next = settings
                var effect: EffectSetting?
                var copy = next
                if let problem = editChain(&copy, a[0], slot, { chain in
                    guard chain.indices.contains(index) else { return "no effect \(index)" }
                    effect = chain[index]
                    return nil
                }) { return Reply(ok: false, text: problem) }
                guard let effect, presets.saveEffect(name, effect) else {
                    return Reply(ok: false, text: presets.lastError ?? "a preset needs a name")
                }
                return Reply(ok: true, text: "saved \"\(PresetStore.clean(name))\"")
            }
            if let problem = editChain(&next, a[0], slot, { chain in
                guard chain.indices.contains(index) else { return "no effect \(index)" }
                guard let preset = presets.effect(chain[index].type, name) else { return "no \(chain[index].type) preset called \"\(name)\"" }
                var loaded = preset.filled(from: catalog)
                loaded.enabled = chain[index].enabled
                chain[index] = loaded
                return nil
            }) { return Reply(ok: false, text: problem) }
            return commit(next, "loaded \"\(PresetStore.clean(name))\"")
        case "fx-preset-delete" where args.count >= 2:
            let a = Array(args)
            return presets.removeEffect(a[0], a[1...].joined(separator: " "))
                ? Reply(ok: true, text: "deleted") : Reply(ok: false, text: "no \(a[0]) preset called \"\(a[1...].joined(separator: " "))\"")
        case "fx-list" where args.count == 2:
            let a = Array(args)
            guard let slot = Int(a[1]) else { break }
            var lines: [String] = []
            var copy = next
            let problem = editChain(&copy, a[0], slot) { chain in
                for (i, e) in chain.enumerated() {
                    let label = e.plugin.map { "\($0) (AU\(e.channels.map { $0.isEmpty ? "" : ", \($0)" } ?? ""))" }
                        ?? catalog.first { $0.type == e.type }?.label ?? e.type
                    let params = e.params.keys.sorted().map { "\($0)=\(e.params[$0]!)" }.joined(separator: " ")
                    lines.append("\(i) \(label)\(e.enabled ? "" : " (bypassed)"): \(params)")
                }
                return nil
            }
            if let problem { return Reply(ok: false, text: problem) }
            return Reply(ok: true, text: lines.isEmpty ? "no effects" : lines.joined(separator: "\n"))
        case "hardware" where args.count == 1:
            next.hardwareOutputEnabled = args.first == "on"
            return commit(next, "hardware output \(next.hardwareOutputEnabled ? "ON" : "off")")
        case "virtual-list":
            return Reply(ok: true, text: driverList().isEmpty ? "no virtual devices" : driverList())
        case "virtual-add" where args.count >= 3:
            // virtual-add <slot> out|in <name>: macOS shows it as "Patch <name>".
            let a = Array(args)
            let name = Self.devicePrefix + Self.bare(a[2...].joined(separator: " "))
            let answer = driverCommand("add \(a[0]) \(a[1]) \(name)")
            appliedNames = [:]
            return Reply(ok: answer == "ok", text: answer)
        case "virtual-rename" where args.count >= 2:
            // The device and the strip or output using it share one name.
            let a = Array(args)
            guard let slot = Int(a[0]) else { break }
            let label = Self.bare(a[1...].joined(separator: " "))
            for i in next.strips.indices { if case .virtual(slot) = next.strips[i].source { next.strips[i].label = label } }
            for i in next.outputs.indices { if case .virtual(slot) = next.outputs[i].sink { next.outputs[i].label = label } }
            let answer = driverCommand("rename \(slot) \(Self.devicePrefix + label)")
            appliedNames = [:]
            guard answer == "ok" else { return Reply(ok: false, text: answer) }
            return commit(next, "renamed")
        case "virtual-remove" where args.count == 1:
            let answer = driverCommand("remove \(args.first!)")
            appliedNames = [:]
            return Reply(ok: answer == "ok", text: answer)
        case "debug-stall" where args.count == 1:
            // For testing the watchdog: the main thread does nothing for this long.
            guard let seconds = Double(args.first!), seconds > 0, seconds <= 60 else { break }
            engineLog.notice("debug-stall: blocking the main thread for \(seconds, privacy: .public) s.")
            Thread.sleep(forTimeInterval: seconds)
            return Reply(ok: true, text: "stalled \(seconds) s")
        case "debug-stop-core":
            // For testing the restart: the core stops as if it had failed to start.
            stopCore()
            lastStartAttempt = Date()
            return Reply(ok: true, text: "core stopped; it should start again within a few seconds")
        case "debug-sleep":
            goingToSleep()
            return Reply(ok: true, text: "as if the Mac went to sleep")
        case "debug-wake":
            wokeUp()
            return Reply(ok: true, text: "as if the Mac woke; the core starts in 3 s")
        case "help":
            return Reply(ok: true, text: """
            status | devices | state | hardware on|off
            strip-add <label> device <name> <left> <right>   channels count from 1
            strip-add <label> virtual <slot>                 audio apps play into that device
            strip-source <n> device <name> <left> <right> | out-sink <n> ...   another device, keeping the rest
            out-add <label> device <name> <left> <right> | out-add <label> virtual <slot>
            bus-add <label>
            route strip <n> bus <n> <gain> | route strip <n> out <n> <gain> | route bus <n> out <n> <gain>
            gain strip|bus|out <n> <linear> | mute strip|bus|out <n> on|off
            clock patchprime | clock <device name or UID>
            rate 44100|48000|96000|192000 | buffer 32|64|128|256|512|1024
            device-buffer <name or UID> <frames>|default | device-rate <name or UID> follow|own
            effects-catalog | fx-list strip|bus|out <n>
            fx-add strip|bus|out <n> <type> [position] | fx-remove ... <i> | fx-move ... <from> <to>
            fx-set strip|bus|out <n> <i> <param> <value> | fx-on strip|bus|out <n> <i> on|off
            fx-all strip|bus|out <n> on|off   every effect at once, keeping each one's switch
            fx-key strip|bus|out <n> <i> <strip>|none   which strip a ducker listens to
            preset-list | preset-save|preset-load strip|bus|out <n> <name> | preset-delete <name>
            scene-list | scene-save <name> | scene-load <name> | scene-delete <name>
            cue-output <output>|off | cue-mode pfl|afl | cue-level <dB> | cue strip|bus|out <n> on|off | cue-clear
            plugins-list | plugins-scan new|all | plugins-scan-stop | plugins-status
            plugin-filter kind|maker|category|plugin <name> hide|show
            fx-preset-save|fx-preset-load strip|bus|out <n> <i> <name> | fx-preset-delete <type> <name>
            fx-add-plugin strip|bus|out <n> <plugin id> [position]   an AU, the version that fits
            fx-window strip|bus|out <n> <i> open|close   the plugin's own window
            default output|input <virtual slot> | default-device output|input <device name or UID>
            strip-remove <n> | bus-remove <n> | out-remove <n> | move strip|bus|out <n> <steps>
            record strip|bus|out <n>   start or stop recording it to a file
            record-format flac|wav|aac | record-inputs raw|processed
            multitrack on|off | arm strip|bus|out <n> on|off | take [start|stop]   armed strips, in step
            play <file> | play-stop | play-pause on|off | play-seek <seconds> | play-loop on|off
            play-into strip|bus|out <n>   a strip: in place of its device; a bus or output: added in
            pads | pad <id or name>   plays it, or stops it | pad-stop-all | pads-into strip|bus|out <n>
            pad-add <file> | pad-remove <id> | pad-set <id> label <text>|gain <dB>|loop on|off | pad-move <id> <steps> | pad-builtin
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
        snap.engineStarted = startedAt
        snap.note = ([note, recordNote].compactMap { $0 } + wiring + pluginNotes).joined(separator: "\n").nilIfEmpty
        snap.settings = settings
        snap.offline = Array(offline)
        snap.devices = devices.filter { !$0.signature.uid.hasPrefix("PatchPrimeMac.") }.map { d in
            var row = DeviceRow(uid: d.signature.uid, name: d.signature.name, transport: d.signature.transport,
                inputs: d.inputs, outputs: d.outputs)
            row.rate = nominalRate(d.id)
            row.rates = Settings.rates.filter { supportsRate(d.id, $0) }
            if let range = bufferRange(d.id) {
                row.bufferMin = range.lowerBound
                row.bufferMax = range.upperBound
            }
            row.buffer = prepared[d.id] != nil ? bufferFrames(d.id) : 0
            return row
        }
        snap.scenes = scenes.names()
        snap.cued = cued.sorted()
        var scan = PluginScanState()
        scan.scanning = scanner.scanning
        scan.done = scanner.done
        scan.total = scanner.total
        scan.current = scanner.current
        scan.ok = scanner.cache.checks.values.filter { $0.status == .ok }.count
        scan.failed = scanner.cache.checks.values.filter { $0.status != .ok }.count
        snap.pluginScan = scan
        snap.chainPresets = presets.chainNames
        snap.builtInChains = BuiltInChains.names
        snap.effectPresets = presets.effectNames
        snap.engineRate = engineRate
        snap.recording = recordings.mapValues(\.seconds)
        snap.takeRunning = recordings.values.contains(where: \.take)
        snap.recordFolder = RecordingFiles.folder.path
        snap.playInto = playTarget() ?? ""
        snap.padsInto = padsTarget() ?? ""
        snap.padsPlaying = padPlayers.mapValues { [$0.player.position, $0.player.duration] }
        if let player {
            snap.player = PlayerState(path: player.url.path, paused: player.isPaused, position: player.position,
                                      duration: player.duration)
        }
        snap.engineBlock = engineBlock
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
        for problem in wiring + pluginNotes { lines.append("NOTE: \(problem)") }
        lines.append("clock: \(clockText)")
        lines.append(String(format: "engine %.1f kHz, %d-frame blocks (%.2f ms)", engineRate / 1000, engineBlock,
            Double(engineBlock) / engineRate * 1000))
        for device in devices where prepared[device.id] != nil {
            let rate = nominalRate(device.id)
            let frames = bufferFrames(device.id)
            lines.append(String(format: "device %@: %.1f kHz%@, %d-frame buffer (%.2f ms)", device.signature.name,
                rate / 1000, abs(rate - engineRate) > 0.5 ? " (resampled)" : "", frames, Double(frames) / rate * 1000))
        }
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

// An accessory app: no Dock icon or menu bar, but able to show plugins' own windows.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let engine = Engine()
let listener = NSXPCListener(machServiceName: engineMachService)
listener.delegate = engine
listener.resume()
DispatchQueue.main.async { engine.start() }
app.run()

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
