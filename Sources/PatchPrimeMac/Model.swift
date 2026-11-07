// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// What the GUI knows. It holds a copy of the engine's state and sends commands.
// Audio doesn't depend on this app: quitting it changes nothing.

import Foundation
import PPShared
import SwiftUI

/// Meter levels live apart from the rest, so a moving meter redraws only itself, not
/// the whole window.
@MainActor
final class Levels: ObservableObject {
    @Published var values: [String: Float] = [:]
}

@MainActor
final class Model: ObservableObject {
    @Published var snapshot = Snapshot()
    @Published var reachable = true
    @Published var lastError: String?
    let levels = Levels()
    private var held: [String: Float] = [:]
    private var timer: Timer?
    private var busy = false
    private let link = EngineLink()
    let offlineSample: Bool

    init(sample: Snapshot? = nil) {
        offlineSample = sample != nil
        if let sample {
            snapshot = sample
            for (k, v) in sample.stripPeaks { held["s\(k)"] = v }
            for (k, v) in sample.busPeaks { held["b\(k)"] = v }
            for (k, v) in sample.outputPeaks { held["o\(k)"] = v }
            levels.values = held
        }
    }

    func start() {
        guard !offlineSample, timer == nil else { return }
        let made = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // Common modes: a default timer stops while the mouse is held down.
        RunLoop.main.add(made, forMode: .common)
        timer = made
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

    /// Only a real change of state reaches SwiftUI. Meters change all the time and
    /// the rest almost never.
    private func publish(_ snap: Snapshot) {
        var quiet = snap
        quiet.stripPeaks = [:]
        quiet.busPeaks = [:]
        quiet.outputPeaks = [:]
        if quiet != snapshot { snapshot = quiet }
        update("s", snap.stripPeaks)
        update("b", snap.busPeaks)
        update("o", snap.outputPeaks)
        var moved = false
        for (key, value) in held where abs((levels.values[key] ?? 0) - value) > 0.00001 {
            moved = true
            _ = key
            break
        }
        if moved { levels.values = held }
    }

    private func update(_ prefix: String, _ peaks: [Int: Float]) {
        for (slot, peak) in peaks {
            let key = "\(prefix)\(slot)"
            let next = max(peak, (held[key] ?? 0) * 0.82) // falls about 20 dB a second
            held[key] = next < 0.00001 ? 0 : next
        }
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
        s.settings.strips = [re20, pr30, desktop]
        s.settings.buses[0].outputSends = [Send(to: 0, gain: 1)]
        s.settings.buses[1].outputSends = [Send(to: 1, gain: 1)]
        s.stripPeaks = [0: 0.3, 1: 0.08, 2: 0]
        s.busPeaks = [0: 0.25, 1: 0.06]
        s.outputPeaks = [0: 0.25, 1: 0.9]
        s.offline = ["Headphones"]
        s.devices = [DeviceRow(uid: "m2", name: "M2", transport: "USB", inputs: 2, outputs: 2),
            DeviceRow(uid: "sp", name: "Mac Studio Speakers", transport: "Built-in", inputs: 0, outputs: 2)]
        s.virtuals = [VirtualRow(slot: 0, isOutput: true, name: "Desktop"), VirtualRow(slot: 1, isOutput: false, name: "Stream Mic")]
        return s
    }
}
