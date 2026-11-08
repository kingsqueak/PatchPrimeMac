// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// The effects editor for one strip, bus or output: Patch Prime's built-in effects in
// order, each with its controls, made from the effect's own list of parameters.

import PPShared
import AppKit
import PPDSP
import SwiftUI

/// Which strip, bus or output an effects window edits. Opening the same one again
/// brings its window forward rather than making a second.
struct EffectsTarget: Codable, Hashable {
    var verb: String   // Stage.verb
    var slot: Int

    var stage: Stage {
        switch verb {
        case "bus": return .bus
        case "out": return .output
        default: return .input
        }
    }
}

struct EffectsButton: View {
    @Environment(\.openWindow) private var openWindow
    var stage: Stage
    var slot: Int
    var label: String
    var count: Int
    var on = true

    var body: some View {
        ToggleButton(title: count > 0 ? (on ? "FX \(count)" : "FX OFF") : "FX", on: count > 0 && on, color: .accentColor, textOn: .white) {
            openWindow(id: "effects", value: EffectsTarget(verb: stage.verb, slot: slot))
        }
        .help("Effects on \(label)")
    }
}

/// An effects editor in a window of its own, which can be moved, resized and left
/// open beside the mixer. Its name follows renames; if the strip goes, it says so.
struct EffectsWindow: View {
    @EnvironmentObject var model: Model
    @Environment(\.dismiss) private var dismiss
    var target: EffectsTarget

    var label: String? {
        let s = model.snapshot.settings
        switch target.stage {
        case .input: return s.strips.first { $0.slot == target.slot }?.label
        case .bus: return s.buses.first { $0.slot == target.slot }?.label
        case .output: return s.outputs.first { $0.slot == target.slot }?.label
        }
    }

    var body: some View {
        Group {
            if let label {
                EffectsEditor(stage: target.stage, slot: target.slot, label: label) { dismiss() }
                    .navigationTitle("Effects on \(label)")
            } else if !model.loaded {
                Text("Reading the mix…").foregroundStyle(.secondary)
                    .frame(minWidth: 400, minHeight: 200)
            } else {
                VStack(spacing: 12) {
                    Text("That strip has been removed.").foregroundStyle(.secondary)
                    Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
                }
                .frame(minWidth: 400, minHeight: 200)
                .navigationTitle("Effects")
            }
        }
    }
}

struct EffectsEditor: View {
    @EnvironmentObject var model: Model
    var stage: Stage
    var slot: Int
    var label: String
    var done: () -> Void
    @State private var saving = false
    @State private var presetName = ""
    @State private var picking = false
    @StateObject private var feed = MeterFeed()

    var chainOn: Bool {
        let s = model.snapshot.settings
        switch stage {
        case .input: return s.strips.first { $0.slot == slot }?.effectsOn ?? true
        case .bus: return s.buses.first { $0.slot == slot }?.effectsOn ?? true
        case .output: return s.outputs.first { $0.slot == slot }?.effectsOn ?? true
        }
    }

    var chain: [EffectSetting] {
        let s = model.snapshot.settings
        switch stage {
        case .input: return s.strips.first { $0.slot == slot }?.effects ?? []
        case .bus: return s.buses.first { $0.slot == slot }?.effects ?? []
        case .output: return s.outputs.first { $0.slot == slot }?.effects ?? []
        }
    }

    /// The chain preset last loaded or saved here.
    var current: String? {
        let s = model.snapshot.settings
        switch stage {
        case .input: return s.strips.first { $0.slot == slot }?.preset
        case .bus: return s.buses.first { $0.slot == slot }?.preset
        case .output: return s.outputs.first { $0.slot == slot }?.preset
        }
    }

    var placement: String {
        switch stage {
        case .input: return "Before the fader: apps recording a bus this strip feeds hear these effects."
        case .bus: return "After the fader."
        case .output: return "After the fader."
        }
    }

    @ViewBuilder func presetItem(_ name: String) -> some View {
        Button {
            model.send("preset-load", stage.verb, "\(slot)", name)
        } label: {
            if name == current { Label(name, systemImage: "checkmark") } else { Text(name) }
        }
    }

    var body: some View {
        let effects = chain
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Effects on \(label)").font(.headline)
                    Text(placement).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("All effects", isOn: Binding(get: { chainOn },
                    set: { model.send("fx-all", stage.verb, "\(slot)", $0 ? "on" : "off") }))
                    .toggleStyle(.switch)
                    .disabled(effects.isEmpty)
                    .help("Bypass every effect here at once. Each effect keeps its own switch for when they're back on.")
                let mine = model.snapshot.chainPresets
                Menu {
                    Section("Built in") {
                        ForEach(model.snapshot.builtInChains, id: \.self) { name in
                            presetItem(name)
                        }
                    }
                    if !mine.isEmpty {
                        Section("Yours") {
                            ForEach(mine, id: \.self) { name in
                                presetItem(name)
                            }
                        }
                    }
                    Divider()
                    Button("Save Chain as Preset…") {
                        presetName = current ?? ""
                        saving = true
                    }
                    .disabled(effects.isEmpty)
                    if let current, mine.contains(current) {
                        Button("Update \"\(current)\" with This Chain") {
                            model.send("preset-save", stage.verb, "\(slot)", current)
                        }
                        .disabled(effects.isEmpty)
                    }
                    if !model.snapshot.chainPresets.isEmpty {
                        Menu("Delete") {
                            ForEach(model.snapshot.chainPresets, id: \.self) { name in
                                Button(name, role: .destructive) { model.send("preset-delete", name) }
                            }
                        }
                    }
                } label: {
                    Text(current.map { mine.contains($0) || model.snapshot.builtInChains.contains($0) ? $0 : "Presets" } ?? "Presets")
                }
                .fixedSize()
                .help("Load a whole chain onto \(label), replacing what's here, or save this one")
                Menu("Add Effect") {
                    Section("Built in") {
                        ForEach(model.catalog) { info in
                            Button(info.label) { model.send("fx-add", stage.verb, "\(slot)", info.type) }
                        }
                    }
                    Divider()
                    Button("Plugins…") { picking = true }
                }
                .disabled(effects.count >= maxEffects)
                .fixedSize()
                Button("Close", action: done).keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if effects.isEmpty {
                        Text("No effects. Add one above; they run top to bottom.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    }
                    ForEach(Array(effects.enumerated()), id: \.offset) { index, effect in
                        EffectCard(stage: stage, slot: slot, index: index, count: effects.count, effect: effect,
                            info: model.catalog.first { $0.type == effect.type }, feed: feed)
                            .opacity(chainOn ? 1 : 0.5)
                    }
                }
                .padding(14)
            }
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 360, idealHeight: 720)
        .onAppear { feed.start(model, [stage.verb, "\(slot)"]) }
        .background(WindowVisibility { feed.visible = $0 })
        .sheet(isPresented: $picking) {
            PluginBrowser(done: { picking = false }, pickFor: label) { row in
                model.send("fx-add-plugin", stage.verb, "\(slot)", row.entry.id)
            }
            .environmentObject(model)
        }
        .onDisappear { feed.stop() }
        .alert("Save the chain on \(label)", isPresented: $saving) {
            TextField("Preset name", text: $presetName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { model.send("preset-save", stage.verb, "\(slot)", presetName) }
                .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
        } message: {
            Text(model.snapshot.chainPresets.contains(presetName.trimmingCharacters(in: .whitespaces))
                ? "A preset with this name will be replaced." : "Load it onto any strip, bus or output.")
        }
    }
}

struct EffectCard: View {
    @EnvironmentObject var model: Model
    var stage: Stage
    var slot: Int
    var index: Int
    var count: Int
    var effect: EffectSetting
    var info: EffectInfo?
    @ObservedObject var feed: MeterFeed
    @State private var saving = false
    @State private var presetName = ""

    func words(_ verb: String, _ rest: String...) -> [String] {
        [verb, stage.verb, "\(slot)"] + rest
    }

    /// Parameters shown loose, and those grouped by band (b1On, b1Freq...).
    var layout: (plain: [EffectParamInfo], bands: [(String, [EffectParamInfo])]) {
        guard let info else { return ([], []) }
        var plain: [EffectParamInfo] = []
        var bands: [String: [EffectParamInfo]] = [:]
        for p in info.params {
            if let band = bandNumber(p.name) {
                bands[band, default: []].append(p)
            } else {
                plain.append(p)
            }
        }
        // The compressor's knob, or its own controls: not both.
        if effect.type == "compressor" {
            let advanced = (effect.params["advanced"] ?? 0) >= 0.5
            plain = plain.filter { $0.name == "advanced" || ($0.name == "amount") != advanced }
        }
        return (plain, bands.keys.sorted { Int($0)! < Int($1)! }.map { ($0, bands[$0]!) })
    }

    var body: some View {
        let parts = layout
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(get: { effect.enabled },
                    set: { model.send(words("fx-on", "\(index)", $0 ? "on" : "off")) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
                if effect.isPlugin {
                    Text("AU").font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 4).background(Color.blue.opacity(0.3), in: RoundedRectangle(cornerRadius: 3))
                }
                Text(effect.plugin.map { "\($0)\(effect.channels.map { $0.isEmpty ? "" : " (\($0))" } ?? "")" } ?? info?.label ?? effect.type)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(effect.enabled ? .primary : .secondary)
                if !effect.enabled { Text("bypassed").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Menu {
                    let names = model.snapshot.effectPresets[effect.type] ?? []
                    ForEach(names, id: \.self) { name in
                        Button(name) { model.send(words("fx-preset-load", "\(index)", name)) }
                    }
                    if !names.isEmpty { Divider() }
                    Button("Save \(info?.label ?? effect.type) Preset…") {
                        presetName = ""
                        saving = true
                    }
                    if !names.isEmpty {
                        Menu("Delete") {
                            ForEach(names, id: \.self) { name in
                                Button(name, role: .destructive) { model.send("fx-preset-delete", effect.type, name) }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "list.bullet")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Presets for this effect alone")
                Button { model.send(words("fx-move", "\(index)", "\(index - 1)")) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0).help("Earlier in the chain")
                Button { model.send(words("fx-move", "\(index)", "\(index + 1)")) } label: { Image(systemName: "chevron.down") }
                    .disabled(index == count - 1).help("Later in the chain")
                Button(role: .destructive) { model.send(words("fx-remove", "\(index)")) } label: { Image(systemName: "trash") }
                    .help("Remove")
            }
            .buttonStyle(.borderless)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    if info == nil && !effect.isPlugin {
                        Text("This effect isn't known to this version, so it's skipped.").font(.caption).foregroundStyle(.orange)
                    }
                    if effect.isPlugin {
                        HStack {
                            Button("Open Window") { model.send(words("fx-window", "\(index)", "open")) }
                            Text("The plugin's own controls. Changes are saved with this chain, its presets and scenes.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if effect.type == "ducker" {
                        let strips = model.snapshot.settings.strips.filter { !(stage == .input && $0.slot == slot) }
                        HStack(spacing: 8) {
                            Text("Listens to").frame(width: 120, alignment: .leading)
                            Picker("", selection: Binding(get: { effect.key ?? -1 },
                                set: { model.send(words("fx-key", "\(index)", $0 < 0 ? "none" : "\($0)")) })) {
                                Text("Nothing").tag(-1)
                                ForEach(strips, id: \.slot) { Text($0.label).tag($0.slot) }
                            }
                            .labelsHidden().fixedSize()
                            Spacer()
                        }
                        if effect.key == nil {
                            Text("Choose the strip that should turn this one down while it's above the threshold: a mic over music, say.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if effect.type == "denoise", model.snapshot.engineRate > 0, model.snapshot.engineRate != 48000 {
                        Text("Noise suppression works at 48 kHz only. At \(AudioSection.khz(model.snapshot.engineRate)) it passes the sound through unchanged.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if effect.type == "eq" {
                        EqCurve(stage: stage, slot: slot, index: index, effect: effect, rate: model.snapshot.engineRate)
                    }
                    if let info, EffectPanel.types.contains(effect.type) {
                        EffectPanel(effect: effect, info: info, index: index, feed: feed) { send($0, $1) }
                    } else {
                        ForEach(parts.plain) { p in
                            ParamControl(info: p, value: effect.params[p.name] ?? p.initial, key: key(p)) { send(p, $0) }
                        }
                    }
                    EffectMeterRows(type: effect.type, index: index, feed: feed)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                EffectMeterBridge(type: effect.type, index: index, on: effect.enabled, params: effect.params,
                    info: info, feed: feed)
            }
            if !parts.bands.isEmpty {
                BandMatrix(bands: parts.bands, effect: effect, keyPrefix: "fx-\(stage.verb)\(slot)-\(index)-") { p, v in send(p, v) }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    /// "b3Freq" is band 3; anything else isn't a band's.
    func bandNumber(_ name: String) -> String? {
        guard name.first == "b" else { return nil }
        let digits = name.dropFirst().prefix { $0.isNumber }
        guard !digits.isEmpty, let next = name.dropFirst(1 + digits.count).first, next.isUppercase else { return nil }
        return String(digits)
    }

    func key(_ p: EffectParamInfo) -> String { "fx-\(stage.verb)\(slot)-\(index)-\(p.name)" }

    func send(_ p: EffectParamInfo, _ value: Double) {
        let words = words("fx-set", "\(index)", p.name, String(value))
        if p.kind == "choice" || p.kind == "toggle" {
            model.send(words)
        } else {
            model.sendLevel(key(p), words)
        }
    }
}

/// One parameter: a slider (log for frequencies and times), a menu, or a switch.
struct ParamControl: View {
    var info: EffectParamInfo
    var value: Double
    var key: String
    var label: String?
    var change: (Double) -> Void
    @State private var dragging: Double?

    var isLog: Bool { info.kind == "log" && info.min > 0 }

    func position(_ v: Double) -> Double {
        let v = min(info.max, max(info.min, v))
        return isLog ? log(v / info.min) / log(info.max / info.min) : (v - info.min) / (info.max - info.min)
    }

    func value(at position: Double) -> Double {
        isLog ? info.min * pow(info.max / info.min, position) : info.min + position * (info.max - info.min)
    }

    func text(_ v: Double) -> String {
        let number: String
        switch abs(v) {
        case 1000...: number = info.unit == "Hz" ? String(format: "%.2f k", v / 1000) : String(format: "%.0f", v)
        case 100...: number = String(format: "%.0f", v)
        case 10...: number = String(format: "%.1f", v)
        default: number = String(format: "%.2f", v)
        }
        return info.unit.isEmpty ? number : "\(number) \(info.unit)"
    }

    var body: some View {
        let name = label ?? info.label
        switch info.kind {
        case "toggle":
            HStack(spacing: 8) {
                Text(name).frame(width: 120, alignment: .leading).lineLimit(1)
                Toggle("", isOn: Binding(get: { value >= 0.5 }, set: { change($0 ? 1 : 0) }))
                    .toggleStyle(.checkbox).labelsHidden()
                Spacer()
            }
        case "choice":
            HStack(spacing: 8) {
                Text(name).frame(width: 120, alignment: .leading).lineLimit(1)
                Picker("", selection: Binding(get: { Int(value.rounded()) }, set: { change(Double($0)) })) {
                    ForEach(Array(info.options.enumerated()), id: \.offset) { i, option in Text(option).tag(i) }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
        default:
            let shown = dragging ?? value
            HStack(spacing: 8) {
                Text(name).frame(width: 120, alignment: .leading).lineLimit(1)
                NativeSlider(position: position(shown),
                    change: { p in
                        let v = info.valid(value(at: p))
                        dragging = v
                        change(v)
                    },
                    end: { dragging = nil },
                    reset: {
                        dragging = nil
                        change(info.initial)
                    })
                Text(text(shown)).font(.system(size: 11, design: .monospaced)).frame(width: 84, alignment: .trailing)
            }
            .help("Double-click to reset to \(text(info.initial)). Scroll to adjust; Option, Command or the thumb wheel for fine steps.")
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// AppKit's slider, for what SwiftUI's lacks here: double-click to reset, and the
/// scroll wheel or trackpad to adjust (Option for fine steps).
struct NativeSlider: NSViewRepresentable {
    var position: Double // 0...1
    var change: (Double) -> Void
    var end: () -> Void
    var reset: () -> Void

    final class Control: NSSlider {
        var onChange: (Double) -> Void = { _ in }
        var onEnd: () -> Void = {}
        var onReset: () -> Void = {}
        var tracking = false
        private var scrollEnd: DispatchWorkItem?
        private var reader = WheelReader()

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                onReset()
                return
            }
            tracking = true
            super.mouseDown(with: event) // tracks the drag until the button comes up
            tracking = false
            onEnd()
        }

        override func scrollWheel(with event: NSEvent) {
            let step = reader.steps(event) * 0.005 // half a percent of the travel a notch
            guard step != 0 else { return }
            let next = min(1, max(0, doubleValue + Double(step)))
            guard next != doubleValue else { return }
            doubleValue = next
            tracking = true
            onChange(next)
            scrollEnd?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.tracking = false
                self?.onEnd()
            }
            scrollEnd = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }

        @objc func moved(_ sender: NSSlider) { onChange(sender.doubleValue) }
    }

    func makeNSView(context: Context) -> Control {
        let slider = Control(value: position, minValue: 0, maxValue: 1, target: nil, action: nil)
        slider.target = slider
        slider.action = #selector(Control.moved(_:))
        slider.isContinuous = true
        slider.controlSize = .small
        return slider
    }

    func updateNSView(_ slider: Control, context: Context) {
        slider.onChange = change
        slider.onEnd = end
        slider.onReset = reset
        if !slider.tracking, abs(slider.doubleValue - position) > 1e-9 {
            slider.doubleValue = position
        }
    }
}

// MARK: EQ curve

/// The EQ's response, drawn from the same filters the engine runs, with a handle for
/// each band: drag it for frequency and gain, scroll on it for Q (Option or
/// Command, or sideways, for fine steps), double-click it to flatten it.
struct EqCurve: View {
    @EnvironmentObject var model: Model
    var stage: Stage
    var slot: Int
    var index: Int
    var effect: EffectSetting
    var rate: Double
    @State private var dragging: (band: Int, freq: Double, gain: Double)?
    @State private var dragStart: CGPoint?

    static let minF = 20.0, maxF = 20000.0, range = 18.0
    static let freqs: [Double] = (0..<240).map { minF * pow(maxF / minF, Double($0) / 239) }

    var params: [String: Double] {
        var p = effect.params
        if let d = dragging {
            p["b\(d.band)Freq"] = d.freq
            p["b\(d.band)Gain"] = d.gain
        }
        return p
    }

    func value(_ p: [String: Double], _ band: Int, _ field: String, _ fallback: Double) -> Double {
        p["b\(band)\(field)"] ?? fallback
    }

    func curve(_ p: [String: Double], band: Int = 0) -> [Double] {
        let text = p.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
        var out = [Double](repeating: 0, count: Self.freqs.count)
        pp_fx_eq_curve(text, Int32(band), rate > 0 ? rate : 48000, Self.freqs, &out, Int32(out.count))
        return out
    }

    static func x(_ f: Double, _ w: CGFloat) -> CGFloat { CGFloat(log(f / minF) / log(maxF / minF)) * w }
    static func f(_ x: CGFloat, _ w: CGFloat) -> Double { minF * pow(maxF / minF, Double(min(max(x / w, 0), 1))) }
    static func y(_ db: Double, _ h: CGFloat) -> CGFloat { h / 2 - CGFloat(max(-range, min(range, db)) / range) * h / 2 }
    static func db(_ y: CGFloat, _ h: CGFloat) -> Double { Double((h / 2 - y) / (h / 2)) * range }

    var body: some View {
        let p = params
        let total = curve(p)
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    // Grid: octaves-ish frequencies and every 6 dB.
                    for f in [50.0, 100, 200, 500, 1000, 2000, 5000, 10000] {
                        let gx = Self.x(f, size.width)
                        ctx.stroke(Path { $0.move(to: CGPoint(x: gx, y: 0)); $0.addLine(to: CGPoint(x: gx, y: size.height)) },
                            with: .color(.primary.opacity(0.08)))
                        ctx.draw(Text(f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))").font(.system(size: 9)).foregroundStyle(.secondary),
                            at: CGPoint(x: gx + 2, y: size.height - 7), anchor: .leading)
                    }
                    for d in stride(from: -12.0, through: 12, by: 6) {
                        let gy = Self.y(d, size.height)
                        ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: gy)); $0.addLine(to: CGPoint(x: size.width, y: gy)) },
                            with: .color(.primary.opacity(d == 0 ? 0.25 : 0.08)))
                        ctx.draw(Text(d == 0 ? "0" : String(format: "%+.0f", d)).font(.system(size: 9)).foregroundStyle(.secondary),
                            at: CGPoint(x: 3, y: gy - 6), anchor: .leading)
                    }
                    // Each band that's on, faintly; then the whole.
                    for band in 1...6 where value(p, band, "On", 1) >= 0.5 {
                        let line = curve(p, band: band)
                        var path = Path()
                        for (i, db) in line.enumerated() {
                            let pt = CGPoint(x: Self.x(Self.freqs[i], size.width), y: Self.y(db, size.height))
                            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                        }
                        ctx.stroke(path, with: .color(Self.color(band).opacity(0.35)), lineWidth: 1)
                    }
                    var path = Path()
                    for (i, db) in total.enumerated() {
                        let pt = CGPoint(x: Self.x(Self.freqs[i], size.width), y: Self.y(db, size.height))
                        if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                    }
                    ctx.stroke(path, with: .color(.white), lineWidth: 2)
                }
                ForEach(1...6, id: \.self) { band in
                    let on = value(p, band, "On", 1) >= 0.5
                    let type = Int(value(p, band, "Type", band == 1 ? 1 : band == 6 ? 2 : 0))
                    let freq = value(p, band, "Freq", [80, 250, 1000, 3000, 6000, 12000][band - 1])
                    let gain = type >= 3 ? 0 : value(p, band, "Gain", 0) // cuts have no gain
                    let at = CGPoint(x: Self.x(freq, w), y: Self.y(gain, h))
                    BandHandle(band: band, color: Self.color(band), on: on,
                        scroll: { step in
                            let q = value(p, band, "Q", type == 0 ? 1 : 0.707)
                            let next = min(10, max(0.1, q * pow(2, step)))
                            model.sendLevel("eqq\(slot)-\(index)-\(band)",
                                ["fx-set", stage.verb, "\(slot)", "\(index)", "b\(band)Q", String(next)])
                        },
                        reset: {
                            model.send(["fx-set", stage.verb, "\(slot)", "\(index)", "b\(band)Gain", "0"])
                        },
                        drag: { moved in
                            let start = dragStart ?? at
                            if dragStart == nil { dragStart = at }
                            let nf = Self.f(start.x + moved.width, w)
                            let ng = type >= 3 ? 0 : max(-24, min(24, Self.db(start.y + moved.height, h)))
                            dragging = (band, nf, ng)
                            model.sendLevel("eqf\(slot)-\(index)-\(band)",
                                ["fx-set", stage.verb, "\(slot)", "\(index)", "b\(band)Freq", String(nf)])
                            if type < 3 {
                                model.sendLevel("eqg\(slot)-\(index)-\(band)",
                                    ["fx-set", stage.verb, "\(slot)", "\(index)", "b\(band)Gain", String(ng)])
                            }
                        },
                        end: {
                            dragStart = nil
                            // Hold the dragged spot until the engine's settings catch up.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { if dragStart == nil { dragging = nil } }
                        })
                        .position(at)
                }
            }
        }
        .frame(height: 200)
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .help("Drag a band for frequency and gain. Scroll on it for Q. Double-click it to flatten it.")
    }

    static func color(_ band: Int) -> Color {
        [Color.red, .orange, .yellow, .green, .cyan, .purple][(band - 1) % 6]
    }
}

/// A band's handle on the curve. AppKit underneath, for the scroll wheel and double-click.
struct BandHandle: View {
    var band: Int
    var color: Color
    var on: Bool
    var scroll: (Double) -> Void
    var reset: () -> Void
    var drag: (CGSize) -> Void
    var end: () -> Void

    var body: some View {
        ZStack {
            Circle().fill(on ? color : Color.gray.opacity(0.5)).frame(width: 18, height: 18)
            Text("\(band)").font(.system(size: 10, weight: .bold)).foregroundStyle(.black)
            ScrollCatcher(scroll: scroll, reset: reset, drag: drag, end: end).frame(width: 24, height: 24)
        }
    }
}

/// A band handle's mouse: drag (how far it's moved, in points, y down), scroll,
/// double-click.
struct ScrollCatcher: NSViewRepresentable {
    var scroll: (Double) -> Void
    var reset: () -> Void
    var drag: (CGSize) -> Void
    var end: () -> Void

    final class Catcher: NSView {
        var onScroll: (Double) -> Void = { _ in }
        var onReset: () -> Void = {}
        var onDrag: (CGSize) -> Void = { _ in }
        var onEnd: () -> Void = {}
        private var from: NSPoint?
        private var reader = WheelReader()

        override func mouseDragged(with event: NSEvent) {
            guard let from else { return }
            let now = event.locationInWindow
            onDrag(CGSize(width: now.x - from.x, height: from.y - now.y)) // window y is up
        }

        override func mouseUp(with event: NSEvent) {
            if from != nil { onEnd() }
            from = nil
        }

        override func scrollWheel(with event: NSEvent) {
            // In octaves of Q: a notch is a twentieth of one.
            let step = reader.steps(event) / 20
            guard step != 0 else { return }
            onScroll(step)
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                from = nil
                onReset()
            } else {
                from = event.locationInWindow
            }
        }
    }

    func makeNSView(context: Context) -> Catcher { Catcher() }

    func updateNSView(_ view: Catcher, context: Context) {
        view.onScroll = scroll
        view.onReset = reset
        view.onDrag = drag
        view.onEnd = end
    }
}

// MARK: Band matrix

/// Bands side by side: a column per band (coloured as on the EQ curve), a row per
/// setting, each number a spinner you can type into or step.
struct BandMatrix: View {
    var bands: [(String, [EffectParamInfo])]
    var effect: EffectSetting
    var keyPrefix: String
    var change: (EffectParamInfo, Double) -> Void

    /// "Band 3 frequency" is "Frequency"; rows are the fields, in the order band 1 has them.
    var rows: [String] {
        bands.first?.1.map { Self.field($0.name) } ?? []
    }

    static func field(_ name: String) -> String {
        String(name.drop { $0 == "b" }.drop { $0.isNumber })
    }

    static func rowLabel(_ p: EffectParamInfo, band: String) -> String {
        let cut = p.label.replacingOccurrences(of: "Band \(band) ", with: "")
        let name = cut.prefix(1).uppercased() + cut.dropFirst()
        return p.unit.isEmpty || p.kind == "toggle" || p.kind == "choice" ? name : "\(name) (\(p.unit))"
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 5) {
            GridRow {
                Text("")
                ForEach(bands, id: \.0) { band, _ in
                    Text("Band \(band)").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(effect.type == "eq" ? EqCurve.color(Int(band) ?? 1) : .secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(rows, id: \.self) { field in
                GridRow {
                    Text(bands.first.flatMap { b in b.1.first { Self.field($0.name) == field }.map { Self.rowLabel($0, band: b.0) } } ?? field)
                        .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
                    ForEach(bands, id: \.0) { _, params in
                        if let p = params.first(where: { Self.field($0.name) == field }) {
                            MatrixCell(info: p, value: effect.params[p.name] ?? p.initial) { change(p, $0) }
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("")
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// One setting in the matrix: a checkbox, a menu, or a spinner.
struct MatrixCell: View {
    var info: EffectParamInfo
    var value: Double
    var change: (Double) -> Void

    var body: some View {
        switch info.kind {
        case "toggle":
            Toggle("", isOn: Binding(get: { value >= 0.5 }, set: { change($0 ? 1 : 0) }))
                .toggleStyle(.checkbox).labelsHidden()
        case "choice":
            Picker("", selection: Binding(get: { Int(value.rounded()) }, set: { change(Double($0)) })) {
                ForEach(Array(info.options.enumerated()), id: \.offset) { i, option in Text(option).tag(i) }
            }
            .labelsHidden().controlSize(.small).frame(maxWidth: 96)
        default:
            Spinner(info: info, value: value, change: change)
        }
    }
}

/// A number you can type (frequencies take "3.5k"), with arrows to step it: a
/// semitone for frequencies, half a dB for levels, about 6 % for the rest.
struct Spinner: View {
    var info: EffectParamInfo
    var value: Double
    var change: (Double) -> Void
    @State private var text = ""
    @FocusState private var editing: Bool

    func stepped(_ direction: Double) -> Double {
        let next: Double
        if info.unit == "dB" {
            // A whole step lands on the half-dB grid; a fine one (a tenth) doesn't.
            next = abs(direction) >= 1 ? (value / 0.5).rounded() * 0.5 + 0.5 * direction : value + 0.5 * direction
        } else if info.kind == "log" && info.min > 0 {
            next = value * pow(info.unit == "Hz" ? pow(2, 1.0 / 12) : 1.06, direction)
        } else {
            next = value + (info.max - info.min) / 100 * direction
        }
        return info.valid(next)
    }

    static func show(_ v: Double, unit: String) -> String {
        switch abs(v) {
        case 1000...: return unit == "Hz" ? String(format: "%.2fk", v / 1000) : String(format: "%.0f", v)
        case 100...: return String(format: "%.0f", v)
        case 10...: return String(format: "%.1f", v)
        default: return String(format: "%.2f", v)
        }
    }

    func parse(_ s: String) -> Double? {
        var t = s.trimmingCharacters(in: .whitespaces).lowercased()
        for unit in ["hz", "db", "ms", "%", ":1"] where t.hasSuffix(unit) { t = String(t.dropLast(unit.count)).trimmingCharacters(in: .whitespaces) }
        var scale = 1.0
        if t.hasSuffix("k") {
            scale = 1000
            t.removeLast()
        }
        return Double(t).map { $0 * scale }
    }

    var body: some View {
        HStack(spacing: 2) {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .frame(width: 58)
                .focused($editing)
                .onSubmit {
                    if let v = parse(text) { change(info.valid(v)) }
                    editing = false
                }
            Stepper("", onIncrement: { change(stepped(1)) }, onDecrement: { change(stepped(-1)) })
                .labelsHidden().controlSize(.small)
        }
        .onWheel(whole: true) { steps in change(stepped(steps)) }
        .help("\(info.label): \(Self.show(value, unit: info.unit)) \(info.unit). Type a value and press Return, or use the arrows.")
        .onAppear { text = Self.show(value, unit: info.unit) }
        .onChange(of: value) { _, v in if !editing { text = Self.show(v, unit: info.unit) } }
        .onChange(of: editing) { _, now in if !now { text = Self.show(value, unit: info.unit) } }
    }
}
