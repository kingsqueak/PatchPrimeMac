// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// The effects editor for one strip, bus or output: Patch Prime's built-in effects in
// order, each with its controls, made from the effect's own list of parameters.

import PPShared
import AppKit
import SwiftUI

struct EffectsButton: View {
    @EnvironmentObject var model: Model
    var stage: Stage
    var slot: Int
    var label: String
    var count: Int
    var on = true
    @State private var open = false

    var body: some View {
        ToggleButton(title: count > 0 ? (on ? "FX \(count)" : "FX OFF") : "FX", on: count > 0 && on, color: .purple) { open = true }
            .help("Effects on \(label)")
            .sheet(isPresented: $open) {
                EffectsEditor(stage: stage, slot: slot, label: label) { open = false }
                    .environmentObject(model)
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

    var placement: String {
        switch stage {
        case .input: return "Before the fader: apps recording a bus this strip feeds hear these effects."
        case .bus: return "After the fader."
        case .output: return "After the fader."
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
                Menu("Presets") {
                    Section("Built in") {
                        ForEach(model.snapshot.builtInChains, id: \.self) { name in
                            Button(name) { model.send("preset-load", stage.verb, "\(slot)", name) }
                        }
                    }
                    if !model.snapshot.chainPresets.isEmpty {
                        Section("Yours") {
                            ForEach(model.snapshot.chainPresets, id: \.self) { name in
                                Button(name) { model.send("preset-load", stage.verb, "\(slot)", name) }
                            }
                        }
                    }
                    Divider()
                    Button("Save Chain as Preset…") {
                        presetName = ""
                        saving = true
                    }
                    .disabled(effects.isEmpty)
                    if !model.snapshot.chainPresets.isEmpty {
                        Menu("Delete") {
                            ForEach(model.snapshot.chainPresets, id: \.self) { name in
                                Button(name, role: .destructive) { model.send("preset-delete", name) }
                            }
                        }
                    }
                }
                .fixedSize()
                .help("Load a whole chain onto \(label), replacing what's here, or save this one")
                Menu("Add Effect") {
                    ForEach(model.catalog.filter { !$0.key }) { info in
                        Button(info.label) { model.send("fx-add", stage.verb, "\(slot)", info.type) }
                    }
                }
                .disabled(effects.count >= maxEffects)
                .fixedSize()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
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
                            info: model.catalog.first { $0.type == effect.type })
                            .opacity(chainOn ? 1 : 0.5)
                    }
                }
                .padding(14)
            }
        }
        .frame(minWidth: 720, idealWidth: 720, minHeight: 520, idealHeight: 720)
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
                Text(info?.label ?? effect.type).font(.system(size: 13, weight: .semibold))
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
            if info == nil {
                Text("This effect isn't known to this version, so it's skipped.").font(.caption).foregroundStyle(.orange)
            }
            ForEach(parts.plain) { p in
                ParamControl(info: p, value: effect.params[p.name] ?? p.initial, key: key(p)) { send(p, $0) }
            }
            ForEach(parts.bands, id: \.0) { band, params in
                VStack(alignment: .leading, spacing: 4) {
                    Text("Band \(band)").font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(params) { p in
                        ParamControl(info: p, value: effect.params[p.name] ?? p.initial, key: key(p),
                            label: p.label.replacingOccurrences(of: "Band \(band) ", with: "").capitalizedFirst) { send(p, $0) }
                    }
                }
                .padding(8)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
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
            .help("Double-click to reset to \(text(info.initial)). Scroll to adjust. Fine steps: hold Option or Command, or scroll sideways (thumb wheel, or Shift with the wheel).")
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
            let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            let raw = horizontal ? -event.scrollingDeltaX : event.scrollingDeltaY
            guard raw != 0 else { return }
            // A trackpad sends fine deltas in points; a wheel sends a line per notch.
            var step = event.hasPreciseScrollingDeltas ? raw / 800 : raw / 200
            // Fine steps: Option or Command held, read from the keyboard itself, since
            // mouse utilities (Logi Options+) can drop modifiers from scroll events; or
            // a sideways scroll (a thumb wheel, or Shift with the main wheel).
            let keys = NSEvent.modifierFlags.union(event.modifierFlags)
            if keys.contains(.option) || keys.contains(.command) || horizontal { step /= 10 }
            if event.isDirectionInvertedFromDevice { step = -step }
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
