// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// What the GUI knows. It holds a copy of the engine's state and sends commands.
// Audio doesn't depend on this app: quitting it changes nothing.

import Foundation
import PPDSP
import PPShared
import SwiftUI

/// Meter layers, by key. Levels go straight to them, so a moving meter costs one layer
/// change and no SwiftUI at all.
@MainActor
final class Levels {
    private var views: [String: WeakMeter] = [:]
    var values: [String: Float] = [:]

    func attach(_ view: MeterLayerView, key: String) {
        views[key] = WeakMeter(view: view)
        view.level = values[key] ?? 0
    }

    func set(_ key: String, _ value: Float) {
        values[key] = value
        views[key]?.view?.level = value
    }
}

private struct WeakMeter {
    weak var view: MeterLayerView?
}

@MainActor
final class Model: ObservableObject {
    @Published var snapshot = Snapshot()
    @Published var reachable = true
    /// The engine's state has arrived. Until then the settings are empty only because
    /// they haven't been read, not because nothing is set up.
    @Published var loaded = false
    @Published var lastError: String?
    let levels = Levels()
    /// The built-in effects, from the same code the engine runs.
    let catalog: [EffectInfo] = {
        guard let text = pp_fx_catalog_json() else { return [] }
        defer { pp_fx_free_string(text) }
        return EffectCatalog.decode(String(cString: text))
    }()
    private var held: [String: Float] = [:]
    private var timer: Timer?
    private var meterTimer: Timer?
    private var meters: SharedMeters?
    private var busy = false
    private let link = EngineLink()
    let offlineSample: Bool

    init(sample: Snapshot? = nil) {
        offlineSample = sample != nil
        if let sample {
            snapshot = sample
            loaded = true
            held = ["s0": 0.3, "s1": 0.08, "b0": 0.25, "b1": 0.06, "o0": 0.25, "o1": 0.9]
            for (key, value) in held { levels.set(key, value) }
        }
    }

    func start() {
        guard !offlineSample, timer == nil else { return }
        // Common modes: a default timer stops while the mouse is held down.
        let state = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(state, forMode: .common)
        timer = state
        let meter = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readMeters() }
        }
        RunLoop.main.add(meter, forMode: .common)
        meterTimer = meter
        poll()
    }

    private func readMeters() {
        if meters == nil { meters = SharedMeters(create: false) }
        guard let meters else { return }
        let s = snapshot.settings
        func take(_ key: String, _ index: Int) {
            let next = max(meters.values[index], (held[key] ?? 0) * 0.9)
            let value = next < 0.00001 ? 0 : next
            if abs((held[key] ?? 0) - value) > 0.00001 {
                held[key] = value
                levels.set(key, value)
            }
        }
        for strip in s.strips { take("s\(strip.slot)", MeterLayout.strip(strip.slot)) }
        for bus in s.buses { take("b\(bus.slot)", MeterLayout.bus(bus.slot)) }
        for output in s.outputs { take("o\(output.slot)", MeterLayout.output(output.slot)) }
    }

    private func poll() {
        guard !busy else { return }
        busy = true
        let link = self.link
        Task.detached(priority: .utility) {
            let reply = link.send(["snapshot"], timeout: 2)
            let snap = reply.ok ? (try? JSONDecoder().decode(Snapshot.self, from: Data(reply.text.utf8))) : nil
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.busy = false
                if self.reachable != reply.ok { self.reachable = reply.ok }
                guard let snap else { return }
                self.publish(snap)
            }
        }
    }

    /// Only a real change of state reaches SwiftUI.
    private func publish(_ snap: Snapshot) {
        // A restarted helper has made a new meters block: drop the old one and open it again.
        if snap.engineStarted != snapshot.engineStarted { meters = nil }
        if snap != snapshot { snapshot = snap }
        if !loaded { loaded = true }
    }

    private var levelPending: [String: [String]] = [:]
    private var levelBusy = false

    /// For a moving control: only the newest value of each goes out, one at a time, so
    /// a drag can't queue up changes behind the hand.
    func sendLevel(_ key: String, _ words: [String]) {
        guard !offlineSample else { return }
        levelPending[key] = words
        pumpLevels()
    }

    private func pumpLevels() {
        guard !levelBusy, let key = levelPending.keys.first, let words = levelPending.removeValue(forKey: key) else { return }
        levelBusy = true
        let link = self.link
        Task.detached(priority: .userInitiated) {
            _ = link.send(words, timeout: 2)
            await MainActor.run { [weak self] in
                self?.levelBusy = false
                self?.pumpLevels()
            }
        }
    }

    func send(_ words: String...) { send(words) }

    /// Asks the engine and hands back the reply on the main thread.
    func ask(_ words: [String], _ done: @escaping @MainActor (Reply) -> Void) {
        guard !offlineSample else { return }
        let link = self.link
        Task.detached(priority: .userInitiated) {
            let reply = link.send(words, timeout: 1)
            await MainActor.run { done(reply) }
        }
    }

    /// Several commands that depend on each other, in order, off the main thread. The
    /// closure gets a way to send one and returns an error to show, or nil.
    func sequence(_ steps: @escaping @Sendable (_ send: ([String]) -> Reply) -> String?) {
        guard !offlineSample else { return }
        let link = self.link
        Task.detached(priority: .userInitiated) {
            let error = steps { link.send($0, timeout: 8) }
            await MainActor.run { [weak self] in self?.lastError = error }
        }
    }

    func send(_ words: [String]) {
        guard !offlineSample else { return }
        let link = self.link
        Task.detached(priority: .userInitiated) {
            let reply = link.send(words, timeout: 8)
            await MainActor.run { [weak self] in
                self?.lastError = reply.ok ? nil : reply.text
            }
        }
    }
}

enum Decibels {
    static let floor: Float = -60
    static let top: Float = 12

    static func toGain(_ db: Float) -> Float { db <= floor ? 0 : pow(10, db / 20) }
    static func fromGain(_ gain: Float) -> Float { gain <= 0 ? floor : max(floor, 20 * log10(gain)) }
    static func label(_ db: Float) -> String { db <= floor ? "-∞" : String(format: "%+.1f", db) }
}

extension Snapshot {
    static var sample: Snapshot {
        var s = Snapshot()
        s.running = true
        let m2 = DeviceSignature(uid: "m2", name: "M2", transport: "USB", serial: "M2")
        s.settings.buses = [Bus(slot: 0, label: "Stream"), Bus(slot: 1, label: "Monitor")]
        s.settings.outputs = [Output(slot: 0, label: "Stream Mic", sink: .virtual(slot: 1)),
            Output(slot: 1, label: "Headphones", sink: .device(m2, left: 0, right: 1))]
        var re20 = Strip(slot: 0, label: "RE20", source: .device(m2, left: 0, right: 0))
        re20.busSends = [Send(to: 0, gain: 1)]
        var pr30 = Strip(slot: 1, label: "PR30", source: .device(m2, left: 1, right: 1))
        pr30.busSends = [Send(to: 0, gain: 1), Send(to: 1, gain: 1)]
        pr30.gain = 0.5
        var desktop = Strip(slot: 2, label: "Desktop", source: .virtual(slot: 0))
        desktop.muted = true
        re20.effects = [EffectSetting(type: "gate", params: ["threshold": -50]),
            EffectSetting(type: "eq", params: ["b1On": 1, "b1Type": 1, "b1Freq": 80, "b2On": 1, "b2Freq": 3500, "b2Gain": 3]),
            EffectSetting(type: "compressor", params: ["amount": 55]),
            EffectSetting(type: "deesser", enabled: false)]
        // The rest of the built-in effects, for the render's other effects pages.
        var ducker = EffectSetting(type: "ducker")
        ducker.key = 0
        pr30.effects = [EffectSetting(type: "expander"), ducker, EffectSetting(type: "limiter", params: ["ceiling": -3]),
            EffectSetting(type: "leveler"), EffectSetting(type: "multiband", params: ["x1": 150, "x2": 1500, "x3": 6000])]
        desktop.effects = [EffectSetting(type: "reverb"), EffectSetting(type: "delay"), EffectSetting(type: "gain"),
            EffectSetting(type: "denoise")]
        s.settings.strips = [re20, pr30, desktop]
        s.settings.buses[0].outputSends = [Send(to: 0, gain: 1)]
        s.settings.buses[1].outputSends = [Send(to: 1, gain: 1)]
        s.offline = ["Headphones"]
        s.silent = ["PR30"]
        s.defaultOutput = "M2"
        s.defaultInput = "M2"
        var m2Row = DeviceRow(uid: "m2", name: "M2", transport: "USB", inputs: 2, outputs: 2)
        m2Row.rate = 48000
        m2Row.rates = PPShared.Settings.rates
        m2Row.bufferMin = 16
        m2Row.bufferMax = 2048
        m2Row.buffer = 128
        var speakers = DeviceRow(uid: "sp", name: "Mac Studio Speakers", transport: "Built-in", inputs: 0, outputs: 2)
        speakers.rate = 48000
        speakers.rates = [44100, 48000, 96000]
        s.devices = [m2Row, speakers]
        s.engineRate = 48000
        s.engineBlock = 128
        s.scenes = ["Radio", "Streaming"]
        s.settings.cueOutput = 1
        s.cued = ["s0"]
        s.settings.lastScene = "Streaming"
        s.builtInChains = BuiltInChains.names
        s.chainPresets = ["RE20 streaming"]
        s.effectPresets = ["compressor": ["Gentle"]]
        s.virtuals = [VirtualRow(slot: 0, isOutput: true, name: "Desktop"), VirtualRow(slot: 1, isOutput: false, name: "Stream Mic")]
        return s
    }
}
