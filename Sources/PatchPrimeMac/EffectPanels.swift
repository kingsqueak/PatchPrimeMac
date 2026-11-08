// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// Panels for the built-in effects: knobs grouped by what they do (detection, timing,
// output...), with a small picture of what the effect is doing beside them: the
// in/out curve of a dynamics effect with the live level on it, the envelope of a gate
// or ducker, a reverb's tail, the leveler's loudness scale. The parametric EQ keeps its
// own curve, and plugins and unknown effects keep the plain list of sliders.

import PPDSP
import PPShared
import SwiftUI

// MARK: Scale

/// A parameter's travel: linear, or log for frequencies and times.
struct ParamScale {
    var info: EffectParamInfo

    var isLog: Bool { info.kind == "log" && info.min > 0 }

    func position(_ v: Double) -> Double {
        let v = min(info.max, max(info.min, v))
        return isLog ? log(v / info.min) / log(info.max / info.min) : (v - info.min) / (info.max - info.min)
    }

    func value(at position: Double) -> Double {
        let p = min(1, max(0, position))
        return isLog ? info.min * pow(info.max / info.min, p) : info.min + p * (info.max - info.min)
    }

    func text(_ v: Double) -> String {
        let number: String
        switch abs(v) {
        case 1000...: number = info.unit == "Hz" ? String(format: "%.2fk", v / 1000) : String(format: "%.0f", v)
        case 100...: number = String(format: "%.0f", v)
        case 10...: number = String(format: "%.1f", v)
        default: number = String(format: "%.2f", v)
        }
        return info.unit.isEmpty ? number : "\(number) \(info.unit)"
    }
}

// MARK: Knob

/// A rotary control: drag up or down (Option for fine steps), scroll (see WheelReader),
/// double-click to reset. A range either side of zero (gain, makeup) fills from the
/// middle.
struct Knob: View {
    var info: EffectParamInfo
    var value: Double
    var label: String?
    var tint: Color = .accentColor
    var size: CGFloat = 42
    var change: (Double) -> Void
    @State private var held: Double?    // what's shown while it's being moved
    @State private var lastY: CGFloat?
    @State private var settle: Task<Void, Never>?

    static let sweep = 0.75 // of a turn

    var body: some View {
        let scale = ParamScale(info: info)
        let shown = held ?? value
        let p = scale.position(shown)
        let centred = info.min < 0 && info.max > 0
        let zero = centred ? scale.position(0) : 0
        VStack(spacing: 3) {
            Text(label ?? info.label).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            ZStack {
                Circle().trim(from: 0, to: Self.sweep)
                    .stroke(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Circle().trim(from: min(zero, p) * Self.sweep, to: max(zero, p) * Self.sweep)
                    .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Circle().fill(Color.primary.opacity(0.08)).padding(7)
                Capsule().fill(Color.primary.opacity(0.85))
                    .frame(width: 2, height: size * 0.22)
                    .offset(y: -size * 0.2)
                    .rotationEffect(.degrees(-135 + 270 * p))
            }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { g in
                    let y = g.location.y
                    let dy = (lastY ?? g.startLocation.y) - y
                    lastY = y
                    let fine = NSEvent.modifierFlags.contains(.option) || NSEvent.modifierFlags.contains(.command)
                    move(to: scale.position(held ?? value) + Double(dy) / 160 * (fine ? 0.1 : 1), scale)
                }
                .onEnded { _ in
                    lastY = nil
                    held = nil
                })
            .onTapGesture(count: 2) {
                held = nil
                change(info.initial)
            }
            .onWheel { steps in
                move(to: scale.position(held ?? value) + steps * 0.005, scale)
                settle?.cancel()
                settle = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    if !Task.isCancelled { held = nil }
                }
            }
            Text(scale.text(shown)).font(.system(size: 10, design: .monospaced)).monospacedDigit().lineLimit(1)
                .fixedSize()
        }
        .frame(minWidth: size + 14)
        .help("\(info.label): drag up or down, or scroll; Option for fine steps. Double-click for \(scale.text(info.initial)).")
    }

    func move(to position: Double, _ scale: ParamScale) {
        let v = info.valid(scale.value(at: position))
        held = v
        change(v)
    }
}

/// A group of controls under a small heading.
struct PanelSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 10) { content }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
    }
}

/// A graph's frame: dark, rounded, a fixed size.
struct GraphBox<Content: View>: View {
    var width: CGFloat = 150
    var height: CGFloat = 112
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(width: width, height: height)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.25)))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1)))
    }
}

// MARK: Panels

/// A built-in effect's panel, or nil to keep the plain list.
struct EffectPanel: View {
    var effect: EffectSetting
    var info: EffectInfo
    var index: Int
    @ObservedObject var feed: MeterFeed
    var send: (EffectParamInfo, Double) -> Void

    static let types: Set<String> = ["gate", "expander", "compressor", "ducker", "deesser", "limiter", "leveler",
                                     "reverb", "delay", "gain", "denoise", "multiband"]

    static func tint(_ type: String) -> Color {
        switch type {
        case "gate", "expander": return .teal
        case "compressor", "multiband", "deesser": return .orange
        case "ducker": return .pink
        case "limiter": return .red
        case "leveler": return .green
        case "reverb", "delay": return .purple
        default: return .accentColor
        }
    }

    var tint: Color { Self.tint(effect.type) }

    func p(_ name: String) -> EffectParamInfo? { info.params.first { $0.name == name } }
    func v(_ name: String) -> Double { effect.params[name] ?? p(name)?.initial ?? 0 }

    @ViewBuilder func knob(_ name: String, _ label: String? = nil) -> some View {
        if let info = p(name) {
            Knob(info: info, value: v(name), label: label, tint: tint) { send(info, $0) }
        }
    }

    @ViewBuilder func toggle(_ name: String, _ label: String) -> some View {
        if let info = p(name) {
            Toggle(label, isOn: Binding(get: { v(name) >= 0.5 }, set: { send(info, $0 ? 1 : 0) }))
                .toggleStyle(.switch).controlSize(.mini)
        }
    }

    /// The live input level in dB (peak), for the dot on a curve; nil when silent.
    var inputDb: Double? {
        let f = feed.shown(index).inPeak.max() ?? 0
        return f > 0 ? (f - 1) * -MeterFeed.floorDb : nil
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) {
                graph
                VStack(alignment: .leading, spacing: 8) { controls }
            }
            VStack(alignment: .leading, spacing: 8) {
                graph
                controls
            }
        }
    }

    @ViewBuilder var graph: some View {
        switch effect.type {
        case "gate":
            GraphBox { TransferCurve(kind: .gate(threshold: v("threshold"), range: v("range")), inputDb: inputDb, tint: tint) }
        case "expander":
            GraphBox { TransferCurve(kind: .expander(threshold: v("threshold"), ratio: v("ratio"), range: v("range")),
                                     inputDb: inputDb, tint: tint) }
        case "compressor":
            let c = compressorValues
            GraphBox { TransferCurve(kind: .compressor(threshold: c.threshold, ratio: c.ratio, makeup: c.makeup),
                                     inputDb: inputDb, tint: tint) }
        case "limiter":
            GraphBox { TransferCurve(kind: .limiter(ceiling: v("ceiling")), inputDb: inputDb, tint: tint) }
        case "ducker":
            GraphBox { EnvelopeShape(attack: v("attack"), hold: v("hold"), release: v("release"), depth: v("depth"),
                                     dips: true, tint: tint) }
        case "deesser":
            GraphBox { DeEsserBand(frequency: v("frequency"), range: v("range"), reduction: Double(feed.own(index).first ?? 0), tint: tint) }
        case "leveler":
            GraphBox(width: 150, height: 112) {
                LoudnessScale(target: v("target"), freeze: v("freeze"), maxBoost: v("maxBoost"), maxCut: v("maxCut"),
                              loudness: feed.own(index).count > 1 ? Double(feed.own(index)[1]) : nil, tint: tint)
            }
        case "reverb":
            GraphBox { ReverbTail(size: v("size"), decay: v("decay"), predelay: v("predelay"), damping: v("damping"),
                                  mix: v("mix"), tint: tint) }
        case "multiband":
            GraphBox(width: 200) {
                CrossoverBands(crossovers: [v("x1"), v("x2"), v("x3")], reductions: feed.own(index).prefix(4).map(Double.init),
                               on: (1...4).map { v("b\($0)On") >= 0.5 })
            }
        default:
            EmptyView()
        }
    }

    /// The compressor's settings in use: its own, or those its one knob sets.
    var compressorValues: (threshold: Double, ratio: Double, makeup: Double) {
        if v("advanced") >= 0.5 { return (v("threshold"), v("ratio"), v("makeup")) }
        var k = [Double](repeating: 0, count: 5)
        pp_fx_compressor_knob(v("amount"), &k)
        return (k[0], k[1], k[4])
    }

    @ViewBuilder var controls: some View {
        switch effect.type {
        case "gate":
            HStack(alignment: .top, spacing: 8) {
                PanelSection(title: "Detection") { knob("threshold"); knob("range") }
                PanelSection(title: "Timing") { knob("attack"); knob("hold"); knob("release") }
            }
        case "expander":
            HStack(alignment: .top, spacing: 8) {
                PanelSection(title: "Detection") { knob("threshold"); knob("ratio"); knob("range") }
                PanelSection(title: "Timing") { knob("attack"); knob("release") }
            }
        case "compressor":
            let advanced = v("advanced") >= 0.5
            Picker("", selection: Binding(get: { advanced }, set: { on in if let a = p("advanced") { send(a, on ? 1 : 0) } })) {
                Text("One knob").tag(false)
                Text("Full controls").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            if advanced {
                HStack(alignment: .top, spacing: 8) {
                    PanelSection(title: "Detection") { knob("threshold"); knob("ratio") }
                    PanelSection(title: "Timing") { knob("attack"); knob("release") }
                    PanelSection(title: "Output") { knob("makeup") }
                }
            } else {
                PanelSection(title: "Amount") {
                    if let a = p("amount") {
                        Knob(info: a, value: v("amount"), label: "", tint: tint, size: 64) { send(a, $0) }
                    }
                    Text("0 % does nothing, 40 % is a light touch for speech, 100 % is heavy, radio-style.")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: 170, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case "ducker":
            HStack(alignment: .top, spacing: 8) {
                PanelSection(title: "Dip") { knob("threshold"); knob("depth") }
                PanelSection(title: "Timing") { knob("attack"); knob("hold"); knob("release") }
            }
        case "deesser":
            HStack(alignment: .top, spacing: 8) {
                PanelSection(title: "Detection") { knob("frequency"); knob("threshold") }
                PanelSection(title: "Reduction") { knob("range") }
            }
            toggle("listen", "Listen to what it watches")
        case "limiter":
            HStack(alignment: .top, spacing: 8) {
                PanelSection(title: "Limit") { knob("ceiling"); knob("release") }
            }
            toggle("truePeak", "True peak (catches peaks between samples)")
        case "leveler":
            HStack(alignment: .top, spacing: 8) {
                PanelSection(title: "Loudness") { knob("target"); knob("freeze", "Freeze below") }
                PanelSection(title: "Limits") { knob("maxBoost"); knob("maxCut") }
                PanelSection(title: "Speed") { knob("speed") }
            }
        case "reverb":
            HStack(alignment: .top, spacing: 8) {
                PanelSection(title: "Space") { knob("size"); knob("decay"); knob("predelay") }
                PanelSection(title: "Tone") { knob("damping"); knob("width") }
                PanelSection(title: "Blend") { knob("mix") }
            }
        case "delay":
            PanelSection(title: "Delay") {
                knob("time")
                Text("Holds this back so it lines up with another output (a slower device, say).")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: 200, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case "gain":
            PanelSection(title: "Gain") { knob("gainDb") }
        case "denoise":
            PanelSection(title: "Suppression") {
                knob("amount")
                Text("Blends the cleaned voice with the original; 100 % is fully cleaned.")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: 200, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case "multiband":
            PanelSection(title: "Crossovers") { knob("x1", "Low / Low-mid"); knob("x2", "Low-mid / High-mid"); knob("x3", "High-mid / High") }
        default:
            EmptyView()
        }
    }
}

// MARK: Graphs

/// Level in against level out, -80 to 0 dB, with the live input on the curve.
struct TransferCurve: View {
    enum Kind {
        case gate(threshold: Double, range: Double)
        case expander(threshold: Double, ratio: Double, range: Double)
        case compressor(threshold: Double, ratio: Double, makeup: Double)
        case limiter(ceiling: Double)
    }

    var kind: Kind
    var inputDb: Double?
    var tint: Color
    static let floor = -80.0

    func out(_ x: Double) -> Double {
        switch kind {
        case let .gate(t, range):
            return x < t ? x - range : x
        case let .expander(t, ratio, range):
            return x < t ? max(x - range, t - (t - x) * ratio) : x
        case let .compressor(t, ratio, makeup):
            return (x < t ? x : t + (x - t) / max(1, ratio)) + makeup
        case let .limiter(c):
            return min(x, c)
        }
    }

    var marker: Double {
        switch kind {
        case let .gate(t, _), let .expander(t, _, _), let .compressor(t, _, _): return t
        case let .limiter(c): return c
        }
    }

    var body: some View {
        Canvas { ctx, size in
            func pt(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: (x - Self.floor) / -Self.floor * size.width,
                        y: (1 - (min(0, max(Self.floor, y)) - Self.floor) / -Self.floor) * size.height)
            }
            // Grid every 20 dB, and the 1:1 line.
            for db in stride(from: -60.0, through: -20.0, by: 20) {
                var g = Path()
                g.move(to: pt(db, Self.floor)); g.addLine(to: pt(db, 0))
                g.move(to: pt(Self.floor, db)); g.addLine(to: pt(0, db))
                ctx.stroke(g, with: .color(.white.opacity(0.06)), lineWidth: 1)
            }
            var unity = Path()
            unity.move(to: pt(Self.floor, Self.floor)); unity.addLine(to: pt(0, 0))
            ctx.stroke(unity, with: .color(.white.opacity(0.18)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            // The threshold (or ceiling).
            var t = Path()
            t.move(to: pt(marker, Self.floor)); t.addLine(to: pt(marker, 0))
            ctx.stroke(t, with: .color(tint.opacity(0.35)), lineWidth: 1)
            // The curve.
            var curve = Path()
            for i in 0...160 {
                let x = Self.floor + Double(i) / 160 * -Self.floor
                i == 0 ? curve.move(to: pt(x, out(x))) : curve.addLine(to: pt(x, out(x)))
            }
            ctx.stroke(curve, with: .color(tint), lineWidth: 2)
            // The live level on it.
            if let x = inputDb, x > Self.floor {
                let c = pt(x, out(x))
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)), with: .color(.white))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Text("IN →").font(.system(size: 8, weight: .semibold)).foregroundStyle(.white.opacity(0.4)).padding(4)
        }
        .overlay(alignment: .topLeading) {
            Text("OUT").font(.system(size: 8, weight: .semibold)).foregroundStyle(.white.opacity(0.4)).padding(4)
        }
        .help("Level in (across) against level out (up), −80 to 0 dB. The dot is the sound going in now.")
    }
}

/// How the gain moves over time: attack, hold, release. Times are drawn on a square
/// root scale so short and long ones both show.
struct EnvelopeShape: View {
    var attack: Double   // ms
    var hold: Double     // ms
    var release: Double  // ms
    var depth: Double    // dB
    var dips = false     // the ducker turns down, then back up
    var tint: Color

    var body: some View {
        Canvas { ctx, size in
            let parts = [attack, hold, release].map { sqrt(max(0, $0)) }
            let lead = 0.12, tail = 0.12
            let total = max(0.001, parts.reduce(0, +))
            let usable = size.width * (1 - lead - tail)
            let x0 = size.width * lead
            let x1 = x0 + usable * parts[0] / total
            let x2 = x1 + usable * parts[1] / total
            let x3 = x2 + usable * parts[2] / total
            let top = size.height * 0.2
            let low = size.height * (0.2 + 0.65 * min(1, max(0.15, depth / 40)))
            let (rest, active) = dips ? (top, low) : (low, top)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: rest))
            path.addLine(to: CGPoint(x: x0, y: rest))
            path.addLine(to: CGPoint(x: x1, y: active))
            path.addLine(to: CGPoint(x: x2, y: active))
            path.addQuadCurve(to: CGPoint(x: x3, y: rest), control: CGPoint(x: x2 + (x3 - x2) * 0.2, y: rest))
            path.addLine(to: CGPoint(x: size.width, y: rest))
            var fill = path
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .color(tint.opacity(0.15)))
            ctx.stroke(path, with: .color(tint), lineWidth: 2)
            for (x, name) in [(x0, "A"), (x1, "H"), (x2, "R")] {
                var l = Path()
                l.move(to: CGPoint(x: x, y: 0)); l.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(l, with: .color(.white.opacity(0.08)), lineWidth: 1)
                ctx.draw(Text(name).font(.system(size: 8, weight: .semibold)).foregroundColor(.white.opacity(0.45)),
                         at: CGPoint(x: x + 6, y: size.height - 8))
            }
        }
        .help(dips ? "The dip: it turns down by Depth over Attack, stays down for Hold after the key drops, and comes back over Release."
                   : "Attack, hold and release.")
    }
}

/// The de-esser's band: what it watches (above Frequency) on 2–12 kHz, with how much
/// it's taking out now.
struct DeEsserBand: View {
    var frequency: Double
    var range: Double
    var reduction: Double
    var tint: Color

    var body: some View {
        Canvas { ctx, size in
            func x(_ f: Double) -> CGFloat { log(f / 1000) / log(16) * size.width } // 1 to 16 kHz
            let fx = x(frequency)
            let depth = size.height * 0.15 + size.height * 0.6 * min(1, reduction / max(1, range))
            ctx.fill(Path(CGRect(x: fx, y: 0, width: size.width - fx, height: size.height)), with: .color(tint.opacity(0.12)))
            var line = Path()
            line.move(to: CGPoint(x: 0, y: size.height * 0.15))
            line.addLine(to: CGPoint(x: fx - 8, y: size.height * 0.15))
            line.addQuadCurve(to: CGPoint(x: fx + 10, y: depth), control: CGPoint(x: fx, y: size.height * 0.15))
            line.addLine(to: CGPoint(x: size.width, y: depth))
            ctx.stroke(line, with: .color(tint), lineWidth: 2)
            for (f, name) in [(2000.0, "2k"), (4000, "4k"), (8000, "8k")] {
                ctx.draw(Text(name).font(.system(size: 8)).foregroundColor(.white.opacity(0.4)),
                         at: CGPoint(x: x(f), y: size.height - 7))
            }
        }
        .help("It watches the sound above Frequency, and turns just that part down while it's over Threshold.")
    }
}

/// The leveler on a loudness scale (−70 to 0 LUFS): its target, how far it may push
/// either way, where it freezes, and the loudness now.
struct LoudnessScale: View {
    var target: Double
    var freeze: Double
    var maxBoost: Double
    var maxCut: Double
    var loudness: Double?
    var tint: Color

    var body: some View {
        Canvas { ctx, size in
            func y(_ l: Double) -> CGFloat { (1 - (min(0, max(-70, l)) + 70) / 70) * size.height }
            let cx = size.width * 0.5
            // The window it works in: from target − boost to target + cut.
            let band = CGRect(x: cx - 22, y: y(target + maxCut), width: 44, height: y(target - maxBoost) - y(target + maxCut))
            ctx.fill(Path(roundedRect: band, cornerRadius: 4), with: .color(tint.opacity(0.15)))
            var tl = Path()
            tl.move(to: CGPoint(x: cx - 30, y: y(target))); tl.addLine(to: CGPoint(x: cx + 30, y: y(target)))
            ctx.stroke(tl, with: .color(tint), lineWidth: 2)
            var fl = Path()
            fl.move(to: CGPoint(x: cx - 30, y: y(freeze))); fl.addLine(to: CGPoint(x: cx + 30, y: y(freeze)))
            ctx.stroke(fl, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            ctx.draw(Text("target").font(.system(size: 8)).foregroundColor(tint), at: CGPoint(x: cx + 48, y: y(target)))
            ctx.draw(Text("freeze").font(.system(size: 8)).foregroundColor(.white.opacity(0.45)), at: CGPoint(x: cx + 48, y: y(freeze)))
            for l in [-60.0, -40, -20] {
                ctx.draw(Text("\(Int(l))").font(.system(size: 8)).foregroundColor(.white.opacity(0.35)), at: CGPoint(x: 14, y: y(l)))
            }
            if let loudness, loudness > -70 {
                let p = CGPoint(x: cx, y: y(loudness))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(.white))
            }
        }
        .help("Loudness in LUFS. It brings the sound towards the target, by no more than the boost and cut (the shaded window), and holds still while the sound is quieter than Freeze below (pauses, say). The dot is the loudness now.")
    }
}

/// A reverb's tail: the pre-delay gap, then reflections dying away over the decay;
/// more damping, a duller (darker) tail; the mix, how much of it you hear.
struct ReverbTail: View {
    var size: Double
    var decay: Double     // s
    var predelay: Double  // ms
    var damping: Double   // %
    var mix: Double       // %
    var tint: Color

    var body: some View {
        Canvas { ctx, box in
            let span = max(1.0, decay * 1.2 + predelay / 1000)
            let start = predelay / 1000 / span * box.width
            let height = box.height * (0.25 + 0.65 * mix / 100)
            let count = 30 + Int(size / 100 * 50)
            for i in 0..<count {
                let t = Double(i) / Double(count)
                let x = start + CGFloat(t) * (box.width - start)
                let seconds = Double(x / box.width) * span - predelay / 1000
                let level = max(0, 1 - max(0, seconds) / max(0.05, decay)) // in dB: −60 dB at the decay time
                let wobble = 0.55 + 0.45 * abs(sin(Double(i) * 12.9898))
                let h = height * CGFloat(level * wobble)
                let fade = 1 - damping / 100 * t * 0.8
                ctx.fill(Path(CGRect(x: x, y: box.height - h, width: 2, height: h)), with: .color(tint.opacity(0.35 + 0.6 * fade)))
            }
            var dry = Path()
            dry.addRect(CGRect(x: 4, y: box.height - box.height * 0.9, width: 3, height: box.height * 0.9))
            ctx.fill(dry, with: .color(.white.opacity(0.7)))
            ctx.draw(Text(String(format: "%.1f s", decay)).font(.system(size: 8)).foregroundColor(.white.opacity(0.5)),
                     at: CGPoint(x: box.width - 20, y: 9))
        }
        .help("The sound (white), the pre-delay gap, then the tail dying away over the decay time. Damping dulls the end of it; Mix sets how much you hear.")
    }
}

/// The multiband compressor's four bands across the spectrum (30 Hz to 16 kHz), split
/// at the crossovers, each shaded by how much it's turning down now.
struct CrossoverBands: View {
    var crossovers: [Double]
    var reductions: [Double]
    var on: [Bool]
    static let colors: [Color] = [.red, .orange, .yellow, .cyan]

    var body: some View {
        Canvas { ctx, size in
            func x(_ f: Double) -> CGFloat { log(f / 20) / log(20000.0 / 20) * size.width }
            let edges = [20.0] + crossovers.sorted() + [20000]
            for b in 0..<4 {
                let x0 = x(edges[b]), x1 = x(edges[b + 1])
                let r = b < reductions.count ? reductions[b] : 0
                let drop = size.height * 0.15 + size.height * 0.6 * CGFloat(min(1, r / 24))
                let color = Self.colors[b].opacity(b < on.count && !on[b] ? 0.15 : 0.8)
                ctx.fill(Path(CGRect(x: x0, y: drop, width: x1 - x0, height: size.height - drop)), with: .color(color.opacity(0.25)))
                var top = Path()
                top.move(to: CGPoint(x: x0, y: drop)); top.addLine(to: CGPoint(x: x1, y: drop))
                ctx.stroke(top, with: .color(color), lineWidth: 2)
                ctx.draw(Text("\(b + 1)").font(.system(size: 9, weight: .bold)).foregroundColor(color),
                         at: CGPoint(x: (x0 + x1) / 2, y: 9))
            }
            for f in crossovers {
                var l = Path()
                l.move(to: CGPoint(x: x(f), y: 0)); l.addLine(to: CGPoint(x: x(f), y: size.height))
                ctx.stroke(l, with: .color(.white.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
            for (f, name) in [(100.0, "100"), (1000, "1k"), (10000, "10k")] {
                ctx.draw(Text(name).font(.system(size: 8)).foregroundColor(.white.opacity(0.4)), at: CGPoint(x: x(f), y: size.height - 7))
            }
        }
        .help("The four bands, split at the crossovers. Each one drops as it's turned down.")
    }
}
