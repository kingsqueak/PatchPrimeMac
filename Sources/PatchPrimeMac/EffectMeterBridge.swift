// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// An effect's meters, as on Patch Prime: side by side like a console's meter bridge,
// the level going in (per channel), its gain reduction (dynamics only; the leveler's
// gain both ways) and the level coming out, each with a readout, on a dB scale down to
// -80 (a mic's noise floor). Where a level is compared with a setting, the setting is
// a line across the meter: the gate's, expander's and compressor's threshold on IN,
// the limiter's ceiling on IN and OUT, and the ducker's threshold on its KEY (the strip
// that turns this one down).
//
// Nothing is measured unless an effects window is open and can be seen: the window
// asks for its meters only then, and the engine stops measuring when the asking stops.

import AppKit
import PPShared
import SwiftUI

/// Asks the engine for an effects window's meters, 15 times a second, while the
/// window is open and visible, and keeps what's drawn: peaks fall back smoothly.
@MainActor
final class MeterFeed: ObservableObject {
    /// One effect's levels as drawn, as fractions of the meter (see fraction(_:)).
    struct Shown: Equatable {
        var inPeak: [Double] = []
        var inRms: [Double] = []
        var outPeak: [Double] = []
        var outRms: [Double] = []
    }

    static let floorDb = -80.0
    /// How far a peak falls each update: about 18 dB a second.
    static let fall = 1.2 / -floorDb

    @Published private(set) var meters = FxMeters()
    @Published private(set) var shown: [Shown] = []
    @Published private(set) var key: Double?
    @Published private(set) var keyRms: Double?
    /// False while the window is minimised or covered: then nothing is asked for.
    var visible = true
    private var timer: Timer?
    private var busy = false

    static func fraction(_ linear: Float) -> Double {
        guard linear > 0 else { return 0 }
        return min(1, max(0, (20 * log10(Double(linear)) - floorDb) / -floorDb))
    }

    static func fraction(db: Double) -> Double {
        min(1, max(0, (db - floorDb) / -floorDb))
    }

    func start(_ model: Model, _ address: [String]) {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self, weak model] _ in
            MainActor.assumeIsolated {
                guard let self, let model, self.visible, !self.busy else { return }
                self.busy = true
                model.ask(["fx-meters"] + address) { reply in
                    self.busy = false
                    guard reply.ok, let m = try? JSONDecoder().decode(FxMeters.self, from: Data(reply.text.utf8)) else { return }
                    self.update(m)
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func update(_ m: FxMeters) {
        func falling(_ now: [Float], _ before: [Double]) -> [Double] {
            now.enumerated().map { i, v in max(Self.fraction(v), (i < before.count ? before[i] : 0) - Self.fall) }
        }
        var next: [Shown] = []
        for (i, l) in m.levels.enumerated() {
            let old = i < shown.count ? shown[i] : Shown()
            next.append(Shown(inPeak: falling(l.inPeak, old.inPeak), inRms: l.inRms.map(Self.fraction),
                outPeak: falling(l.outPeak, old.outPeak), outRms: l.outRms.map(Self.fraction)))
        }
        key = m.key.map { max(Self.fraction($0), (key ?? 0) - Self.fall) }
        keyRms = m.keyRms.map(Self.fraction)
        meters = m
        if next != shown { shown = next }
    }

    func shown(_ index: Int) -> Shown { index < shown.count ? shown[index] : Shown() }
    func own(_ index: Int) -> [Float] { index < meters.meters.count ? meters.meters[index] : [] }
}

/// Tells whether the window it's in can be seen (not minimised, not fully covered).
struct WindowVisibility: NSViewRepresentable {
    var changed: (Bool) -> Void

    func makeNSView(context: Context) -> Watcher {
        let view = Watcher()
        view.changed = changed
        return view
    }

    func updateNSView(_ view: Watcher, context: Context) { view.changed = changed }

    final class Watcher: NSView {
        var changed: ((Bool) -> Void)?
        nonisolated(unsafe) private var token: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
            guard let window else { return }
            token = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            report()
        }

        func report() { changed?(window?.occlusionState.contains(.visible) ?? false) }

        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }
}

/// One effect's meter bridge, beside its controls.
struct EffectMeterBridge: View {
    var type: String
    var index: Int
    var on: Bool
    var params: [String: Double]
    var info: EffectInfo?
    @ObservedObject var feed: MeterFeed

    static let height: CGFloat = 132
    static let barWidth: CGFloat = 8

    func param(_ name: String) -> Double? {
        params[name] ?? info?.params.first { $0.name == name }?.initial
    }

    /// The setting drawn across IN (and the limiter's OUT), in dB.
    func inMark(_ own: [Float]) -> Double? {
        switch type {
        case "gate", "expander": return param("threshold")
        case "limiter": return param("ceiling")
        case "compressor": return own.count > 1 ? Double(own[1]) : nil // the threshold the knob set
        default: return nil
        }
    }

    var inMarkName: String { type == "limiter" ? "Ceiling" : "Threshold" }

    static func readout(_ fractions: [Double]) -> String {
        let f = fractions.max() ?? 0
        return f <= 0 ? "−∞" : String(format: "%.1f", (f - 1) * -MeterFeed.floorDb)
    }

    var body: some View {
        let shown = feed.shown(index)
        let own = feed.own(index)
        let reduction = EffectMeterReading.reduction(type, own)
        let bipolar = type == "leveler"
        let mark = inMark(own)
        HStack(alignment: .top, spacing: 4) {
            column("", readout: "") { Scale() }
            if let key = feed.key {
                column("KEY", readout: Self.readout([key]), mark: type == "ducker" ? param("threshold") : nil,
                       markName: "Threshold") {
                    LevelBar(peak: key, rms: feed.keyRms ?? 0)
                }
                .help("The strip it listens to")
            }
            column("IN", readout: Self.readout(shown.inPeak), mark: mark, markName: inMarkName) {
                ForEach(0..<max(1, shown.inPeak.count), id: \.self) { c in
                    LevelBar(peak: c < shown.inPeak.count ? shown.inPeak[c] : 0, rms: c < shown.inRms.count ? shown.inRms[c] : 0)
                }
            }
            if let reduction {
                let db = Double(reduction)
                column(bipolar ? "GAIN" : "GR",
                       readout: bipolar ? String(format: "%+.1f", db) : (db < 0.05 ? "0.0" : String(format: "−%.1f", db))) {
                    ReductionBar(db: db, range: Double(EffectMeterReading.range(type)), bipolar: bipolar)
                }
                .help(bipolar ? "How much it's turning the sound up (+) or down (−), now" : "How much it's turning the sound down, now")
            }
            column("OUT", readout: Self.readout(shown.outPeak), mark: type == "limiter" ? mark : nil, markName: inMarkName) {
                ForEach(0..<max(1, shown.outPeak.count), id: \.self) { c in
                    LevelBar(peak: c < shown.outPeak.count ? shown.outPeak[c] : 0, rms: c < shown.outRms.count ? shown.outRms[c] : 0)
                }
            }
        }
        .opacity(on ? 1 : 0.45)
        .fixedSize()
    }

    func column<Bars: View>(_ title: String, readout: String, mark: Double? = nil, markName: String = "",
                            @ViewBuilder bars: () -> Bars) -> some View {
        VStack(spacing: 3) {
            Text(title.isEmpty ? " " : title)
                .font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
            HStack(spacing: 2) { bars() }
                .padding(.horizontal, 4)
                .frame(height: Self.height)
                .overlay(alignment: .top) {
                    if let mark {
                        GeometryReader { g in
                            RoundedRectangle(cornerRadius: 1).fill(Color.primary)
                                .frame(width: g.size.width, height: 2)
                                .offset(y: (g.size.height * (1 - MeterFeed.fraction(db: mark)) - 1).rounded())
                        }
                        .help(String(format: "%@: %.1f dB", markName, mark))
                    }
                }
            Text(readout.isEmpty ? " " : readout)
                .font(.system(size: 9, design: .monospaced)).monospacedDigit()
                .frame(minWidth: 36)
        }
    }

    /// The dB scale beside the meters.
    struct Scale: View {
        var body: some View {
            GeometryReader { g in
                ForEach([0, -20, -40, -60], id: \.self) { db in
                    Text("\(db)").font(.system(size: 8, design: .monospaced)).foregroundStyle(.tertiary)
                        .frame(width: 24, alignment: .trailing)
                        .position(x: 12, y: g.size.height * (1 - MeterFeed.fraction(db: Double(db))))
                }
            }
            .frame(width: 24)
        }
    }
}

/// A level meter: the peak, lighter, behind the RMS, coloured by level.
struct LevelBar: View {
    var peak: Double
    var rms: Double

    static func color(_ f: Double) -> Color { f > 0.95 ? .red : f > 0.8 ? .yellow : .green }

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.1))
                RoundedRectangle(cornerRadius: 2).fill(Self.color(peak).opacity(0.45))
                    .frame(height: g.size.height * peak)
                RoundedRectangle(cornerRadius: 2).fill(Self.color(rms))
                    .frame(height: g.size.height * min(rms, peak))
            }
        }
        .frame(width: EffectMeterBridge.barWidth)
    }
}

/// Gain reduction, growing down from the top; the leveler's gain, up or down from the
/// middle. Ticks at each quarter of its range.
struct ReductionBar: View {
    var db: Double
    var range: Double
    var bipolar: Bool

    var body: some View {
        GeometryReader { g in
            let fraction = min(1, abs(db) / range) * (bipolar ? 0.5 : 1)
            let length = g.size.height * fraction
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.1))
                RoundedRectangle(cornerRadius: 2).fill(bipolar && db > 0 ? Color.green : Color.orange)
                    .frame(height: length)
                    .offset(y: !bipolar ? 0 : db >= 0 ? g.size.height / 2 - length : g.size.height / 2)
                ForEach([0.25, 0.5, 0.75], id: \.self) { at in
                    Rectangle().fill(Color.primary.opacity(at == 0.5 && bipolar ? 0.5 : 0.2))
                        .frame(height: 1).offset(y: (g.size.height * at).rounded())
                }
            }
        }
        .frame(width: EffectMeterBridge.barWidth)
    }
}

/// Meters beyond the bridge: noise suppression's voice, the leveler's loudness.
struct EffectMeterRows: View {
    var type: String
    var index: Int
    @ObservedObject var feed: MeterFeed

    var body: some View {
        let own = feed.own(index)
        if type == "denoise" {
            row("Voice", own.first ?? 0, 0...100, "%.0f %%")
                .help("How sure noise suppression is that it's hearing a voice, now")
        } else if type == "leveler" {
            row("Loudness", own.count > 1 ? own[1] : -60, -60...0, "%.1f LUFS")
                .help("How loud it's measuring the sound, now")
        }
    }

    func row(_ label: String, _ value: Float, _ range: ClosedRange<Double>, _ format: String) -> some View {
        let v = min(range.upperBound, max(range.lowerBound, Double(value)))
        return HStack(spacing: 8) {
            Text(label).frame(width: 120, alignment: .leading)
            ProgressView(value: v - range.lowerBound, total: range.upperBound - range.lowerBound)
            Text(String(format: format, Double(value))).font(.system(size: 11, design: .monospaced))
                .frame(width: 84, alignment: .trailing)
        }
    }
}
