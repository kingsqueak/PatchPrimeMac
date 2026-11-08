// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// Offline tests of the mixer core. No audio device is touched.
import AudioToolbox
import Foundation
import PPCore
import PPDSP

nonisolated(unsafe) var failures = 0

/// The CPU time this thread has used, in seconds. Comparisons of cost use it rather than
/// the clock on the wall: time the test spends waiting for a CPU (a busy machine, a
/// shared CI runner) isn't the code's cost.
func threadSeconds() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e9 }

func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print("\(ok ? "ok  " : "FAIL") \(name) \(detail)")
    if !ok { failures += 1 }
}

func near(_ a: Float, _ b: Float, _ tolerance: Float = 1e-4) -> Bool { abs(a - b) <= tolerance }

let block = 128

func fill(_ m: OpaquePointer, _ input: Int32, _ left: Float, _ right: Float) {
    let l = pp_mixer_input_left(m, input)!
    let r = pp_mixer_input_right(m, input)!
    for i in 0..<block {
        l[i] = left
        r[i] = right
    }
}

// Runs blocks until every glide has finished.
func settle(_ m: OpaquePointer, _ inputs: [(Int32, Float, Float)]) {
    for _ in 0..<40 {
        for (i, l, r) in inputs { fill(m, i, l, r) }
        pp_mixer_process(m, Int32(block))
    }
}

func output(_ m: OpaquePointer, _ o: Int32) -> (Float, Float) {
    (pp_mixer_output_left(m, o)![block - 1], pp_mixer_output_right(m, o)![block - 1])
}

func makeMixer() -> OpaquePointer {
    let m = pp_mixer_create(48000)!
    return m
}

do { // Input to output, straight.
    let m = makeMixer()
    pp_mixer_set_input_active(m, 0, 1)
    pp_mixer_set_output_active(m, 0, 1)
    pp_mixer_set_output_active(m, 1, 1)
    pp_mixer_set_input_to_output(m, 0, 0, 1)
    settle(m, [(0, 0.5, -0.25)])
    let (l, r) = output(m, 0)
    check("input reaches a routed output", near(l, 0.5) && near(r, -0.25), "\(l) \(r)")
    let (l2, r2) = output(m, 1)
    check("an unrouted output stays silent", l2 == 0 && r2 == 0, "\(l2) \(r2)")
    pp_mixer_destroy(m)
}

do { // Input through a bus to two outputs.
    let m = makeMixer()
    pp_mixer_set_input_active(m, 0, 1)
    pp_mixer_set_bus_active(m, 0, 1)
    pp_mixer_set_output_active(m, 0, 1)
    pp_mixer_set_output_active(m, 1, 1)
    pp_mixer_set_input_to_bus(m, 0, 0, 1)
    pp_mixer_set_bus_to_output(m, 0, 0, 1)
    pp_mixer_set_bus_to_output(m, 0, 1, 0.5)
    settle(m, [(0, 0.5, 0.5)])
    check("bus feeds its first output", near(output(m, 0).0, 0.5))
    check("bus send level is applied", near(output(m, 1).0, 0.25), "\(output(m, 1).0)")
    pp_mixer_destroy(m)
}

do { // Two inputs sum in a bus; fader and mute act after that.
    let m = makeMixer()
    pp_mixer_set_input_active(m, 0, 1)
    pp_mixer_set_input_active(m, 1, 1)
    pp_mixer_set_bus_active(m, 2, 1)
    pp_mixer_set_output_active(m, 3, 1)
    pp_mixer_set_input_to_bus(m, 0, 2, 1)
    pp_mixer_set_input_to_bus(m, 1, 2, 1)
    pp_mixer_set_bus_to_output(m, 2, 3, 1)
    settle(m, [(0, 0.25, 0.25), (1, 0.125, 0.125)])
    check("inputs sum in a bus", near(output(m, 3).0, 0.375), "\(output(m, 3).0)")
    pp_mixer_set_input_gain(m, 0, 0.5)
    settle(m, [(0, 0.25, 0.25), (1, 0.125, 0.125)])
    check("input fader", near(output(m, 3).0, 0.25), "\(output(m, 3).0)")
    pp_mixer_set_input_mute(m, 1, 1)
    settle(m, [(0, 0.25, 0.25), (1, 0.125, 0.125)])
    check("input mute", near(output(m, 3).0, 0.125), "\(output(m, 3).0)")
    pp_mixer_set_bus_gain(m, 2, 0.5)
    settle(m, [(0, 0.25, 0.25), (1, 0.125, 0.125)])
    check("bus fader", near(output(m, 3).0, 0.0625), "\(output(m, 3).0)")
    pp_mixer_set_output_mute(m, 3, 1)
    settle(m, [(0, 0.25, 0.25), (1, 0.125, 0.125)])
    check("output mute is silence", output(m, 3).0 == 0, "\(output(m, 3).0)")
    pp_mixer_destroy(m)
}

do { // A route removed fades instead of stopping dead.
    let m = makeMixer()
    pp_mixer_set_input_active(m, 0, 1)
    pp_mixer_set_output_active(m, 0, 1)
    pp_mixer_set_input_to_output(m, 0, 0, 1)
    settle(m, [(0, 0.5, 0.5)])
    pp_mixer_set_input_to_output(m, 0, 0, 0)
    fill(m, 0, 0.5, 0.5)
    pp_mixer_process(m, Int32(block))
    let out = pp_mixer_output_left(m, 0)!
    var largestStep: Float = 0
    for i in 1..<block { largestStep = max(largestStep, abs(out[i] - out[i - 1])) }
    // Full scale in 10 ms is 480 frames, so 0.5 may move 0.5 / 480 a sample and no more.
    check("removing a route ramps, no click", largestStep <= 0.5 / 480 * 1.01 && out[block - 1] > 0,
        "step \(largestStep), end \(out[block - 1])")
    settle(m, [(0, 0.5, 0.5)])
    check("and ends silent", output(m, 0).0 == 0, "\(output(m, 0).0)")
    pp_mixer_destroy(m)
}

do { // Meters hold a peak until read, then reset.
    let m = makeMixer()
    pp_mixer_set_input_active(m, 0, 1)
    pp_mixer_set_output_active(m, 0, 1)
    pp_mixer_set_input_to_output(m, 0, 0, 1)
    settle(m, [(0, 0.75, 0.5)])
    settle(m, [(0, 0.1, 0.1)])
    let a = pp_mixer_read_input_meter(m, 0)
    check("meter holds the peak", near(a.peakLeft, 0.75) && near(a.peakRight, 0.5), "\(a)")
    settle(m, [(0, 0.1, 0.1)])
    let b = pp_mixer_read_input_meter(m, 0)
    check("meter resets when read", near(b.peakLeft, 0.1), "\(b)")
    pp_mixer_destroy(m)
}

do { // Cost: a busy mixer, measured.
    let m = makeMixer()
    for i in 0..<8 { pp_mixer_set_input_active(m, Int32(i), 1) }
    for b in 0..<4 { pp_mixer_set_bus_active(m, Int32(b), 1) }
    for o in 0..<4 { pp_mixer_set_output_active(m, Int32(o), 1) }
    for i in 0..<8 {
        for b in 0..<4 { pp_mixer_set_input_to_bus(m, Int32(i), Int32(b), 0.5) }
    }
    for b in 0..<4 {
        for o in 0..<4 { pp_mixer_set_bus_to_output(m, Int32(b), Int32(o), 0.5) }
    }
    let blocks = 20000
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<blocks {
        for i in 0..<8 { fill(m, Int32(i), 0.1, 0.1) }
        pp_mixer_process(m, Int32(block))
    }
    let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    let audio = Double(blocks * block) / 48000
    print(String(format: "cost: 8 inputs, 4 buses, 4 outputs, 48 sends, block 128: %.2f%% of a core (includes test's own buffer filling)", 100 * seconds / audio))
    pp_mixer_destroy(m)
}

/// Random numbers from a fixed seed (SplitMix64): the "noise" in these tests is the same
/// on every run and every machine, so a result can't depend on the luck of the draw.
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64 = 0x5EED_1234_ABCD) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// Clock bridge: two simulated clocks with noisy timestamps.
struct BridgeRun {
    var ratio = 0.0
    var underruns: UInt64 = 0
    var overruns: UInt64 = 0
    var resyncs: UInt64 = 0
    var peakAfterGap: Float = 0
    var staleFrames = 0
}

func simulate(ppm: Double, producerBlock: Int, consumerBlock: Int, saved: Double, seconds: Double,
    consumerGap: ClosedRange<Double>? = nil, producerGap: ClosedRange<Double>? = nil,
    producerRate: Double = 48000, consumerRate: Double = 48000, tone: Double = 0,
    capture: UnsafeMutablePointer<[Float]>? = nil, steady: Bool = false) -> BridgeRun {
    let b = pp_bridge_create(producerRate, consumerRate, Int32(producerBlock), Int32(consumerBlock), saved)!
    var generator = SeededRandom()
    let jitter = { (g: inout SeededRandom) -> Double in
        steady ? 0 : Double.random(in: -60e-6...60e-6, using: &g)
    }
    var inLeft = [Float](repeating: 0.25, count: producerBlock)
    var phase = 0.0
    var outLeft = [Float](repeating: 0, count: consumerBlock)
    var outRight = outLeft
    var nextProducer = 0.0
    var nextConsumer = 0.0
    let producerStep = Double(producerBlock) / (producerRate * (1 + ppm * 1e-6))
    let consumerStep = Double(consumerBlock) / consumerRate
    var run = BridgeRun()
    while nextProducer < seconds || nextConsumer < seconds {
        if nextProducer <= nextConsumer {
            if tone > 0 {
                for i in 0..<producerBlock {
                    inLeft[i] = Float(0.5 * sin(phase))
                    phase += 2 * Double.pi * tone / producerRate
                }
            }
            if producerGap?.contains(nextProducer) != true {
                pp_bridge_write(b, inLeft, inLeft, Int32(producerBlock), nextProducer + jitter(&generator))
            }
            nextProducer += producerStep
        } else {
            if consumerGap?.contains(nextConsumer) != true {
                pp_bridge_read(b, &outLeft, &outRight, Int32(consumerBlock), nextConsumer + jitter(&generator))
                if let gap = producerGap, nextConsumer > gap.lowerBound + 0.3, nextConsumer < gap.upperBound {
                    run.staleFrames += outLeft.filter { $0 != 0 }.count
                }
                if nextConsumer > seconds - 0.5 {
                    run.peakAfterGap = max(run.peakAfterGap, outLeft.max() ?? 0)
                    capture?.pointee.append(contentsOf: outLeft)
                }
            }
            nextConsumer += consumerStep
        }
    }
    run.ratio = pp_bridge_ratio_ppm(b)
    run.underruns = pp_bridge_underruns(b)
    run.overruns = pp_bridge_overruns(b)
    run.resyncs = pp_bridge_resyncs(b)
    pp_bridge_destroy(b)
    return run
}

do {
    let input = simulate(ppm: 37, producerBlock: 512, consumerBlock: 128, saved: 35, seconds: 90)
    check("bridge, device to engine, locks", abs(input.ratio - 37) < 1.5 && input.underruns == 0 && input.overruns == 0, "\(input)")
    let output = simulate(ppm: -18.4, producerBlock: 128, consumerBlock: 512, saved: -16, seconds: 90)
    check("bridge, engine to device, locks", abs(output.ratio + 18.4) < 1.5 && output.underruns == 0 && output.overruns == 0, "\(output)")
    let small = simulate(ppm: 12, producerBlock: 32, consumerBlock: 128, saved: 12, seconds: 60)
    check("bridge, small blocks", small.underruns == 0 && small.overruns == 0, "\(small)")
    let large = simulate(ppm: -85, producerBlock: 1024, consumerBlock: 128, saved: 0, seconds: 300)
    check("bridge, large block, unknown rate", abs(large.ratio + 85) < 3 && large.underruns == 0, "\(large)")
    let sleep = simulate(ppm: 20, producerBlock: 512, consumerBlock: 128, saved: 20, seconds: 40, consumerGap: 10...15)
    check("bridge re-locks after the consumer stops", sleep.resyncs == 1 && sleep.underruns == 0 && sleep.peakAfterGap > 0.2, "\(sleep)")
    let stall = simulate(ppm: 20, producerBlock: 512, consumerBlock: 128, saved: 20, seconds: 40, producerGap: 10...15)
    check("bridge goes silent, not stale, when the device stalls", stall.staleFrames == 0, "\(stall)")
    check("and comes back", stall.peakAfterGap > 0.2, "\(stall.peakAfterGap)")
    // 25 s after a 5 s stall, with random timing jitter, the estimate is still settling:
    // it lands within about 3 ppm (a lost rate would be off by tens).
    check("with its rate intact", abs(stall.ratio - 20) < 4, "\(stall.ratio)")
}

// Quality across rates. A tone at `tone` Hz goes through; fit it out of the last half
// second and report what's left, in dB below the tone. For a tone above the lower
// rate's band, everything that comes out is alias, reported in dB below the input.
func residualDB(_ x: [Float], tone: Double, rate: Double) -> Double {
    var a = [[Double]](repeating: [0, 0, 0], count: 3)
    var y = [0.0, 0.0, 0.0]
    for (n, v) in x.enumerated() {
        let w = 2 * Double.pi * tone * Double(n) / rate
        let basis = [sin(w), cos(w), 1]
        for i in 0..<3 {
            y[i] += basis[i] * Double(v)
            for j in 0..<3 { a[i][j] += basis[i] * basis[j] }
        }
    }
    // Solve the 3x3 by Cramer's rule.
    func det(_ m: [[Double]]) -> Double {
        m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
            + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
    }
    let d = det(a)
    var c = [0.0, 0.0, 0.0]
    for k in 0..<3 {
        var m = a
        for i in 0..<3 { m[i][k] = y[i] }
        c[k] = det(m) / d
    }
    var err = 0.0, sig = 0.0
    for (n, v) in x.enumerated() {
        let w = 2 * Double.pi * tone * Double(n) / rate
        let fit = c[0] * sin(w) + c[1] * cos(w) + c[2]
        err += (Double(v) - fit) * (Double(v) - fit)
        sig += fit * fit
    }
    return 10 * log10(max(err, 1e-30) / max(sig, 1e-30))
}

/// The same, with the tone's frequency searched within ±30 ppm: the rate controller
/// is allowed to sit a fraction of a ppm off while it settles, which is no distortion.
func bestResidualDB(_ x: [Float], tone: Double, rate: Double) -> Double {
    func at(_ ppm: Double) -> Double { residualDB(x, tone: tone * (1 + ppm * 1e-6), rate: rate) }
    var centre = stride(from: -30.0, through: 30, by: 1).min { at($0) < at($1) } ?? 0
    for step in [0.1, 0.01, 0.001] {
        centre = stride(from: centre - 10 * step, through: centre + 10 * step, by: step).min { at($0) < at($1) } ?? centre
    }
    return at(centre)
}

func rmsDB(_ x: [Float], below amplitude: Double) -> Double {
    let rms = sqrt(x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, x.count)))
    return 20 * log10(max(rms, 1e-12) / (amplitude / sqrt(2)))
}

do {
    let pairs: [(Double, Double, Int, Int)] = [
        (48000, 48000, 512, 128), (48000, 96000, 512, 256), (96000, 48000, 256, 128),
        (192000, 48000, 1024, 128), (44100, 48000, 512, 128), (48000, 44100, 128, 512),
        (48000, 192000, 128, 1024),
    ]
    for (p, c, pb, cb) in pairs {
        // The filter alone: steady clocks, no drift.
        var out: [Float] = []
        _ = simulate(ppm: 0, producerBlock: pb, consumerBlock: cb, saved: 0, seconds: 10,
            producerRate: p, consumerRate: c, tone: 1000, capture: &out, steady: true)
        let filter = bestResidualDB(out, tone: 1000, rate: c)
        // Real life: drift and timestamp jitter, so the controller's wander shows too.
        var real: [Float] = []
        let run = simulate(ppm: -18, producerBlock: pb, consumerBlock: cb, saved: -18, seconds: 30,
            producerRate: p, consumerRate: c, tone: 1000, capture: &real)
        let wander = bestResidualDB(real, tone: 1000 * (1 - 18e-6), rate: c)
        check(String(format: "bridge %.1f to %.1f kHz: filter %.0f dB, with jitter %.0f dB, %.1f ppm",
            p / 1000, c / 1000, filter, wander, run.ratio),
            filter < -90 && wander < -70 && run.underruns == 0 && run.overruns == 0
                && abs(run.ratio + 18) < 3, "\(run)")
        // ±60 µs of timestamp jitter over 30 s puts the estimate within about ±2 ppm of
        // the truth; 3 is that with room. How it sounds is checked by the two levels.
    }
    for (p, c) in [(192000.0, 48000.0), (96000.0, 48000.0), (48000.0, 44100.0)] {
        var out: [Float] = []
        let tone = c * 0.5 + 3000 // above the lower rate's band
        _ = simulate(ppm: 0, producerBlock: 512, consumerBlock: 128, saved: 0, seconds: 10,
            producerRate: p, consumerRate: c, tone: tone, capture: &out)
        let alias = rmsDB(out, below: 0.5)
        check(String(format: "bridge %.1f to %.1f kHz: a %.1f kHz tone is gone (%.0f dB)", p / 1000, c / 1000,
            tone / 1000, alias), alias < -60)
    }
}

// Effects in the mixer: Patch Prime's built-ins through the same calls the engine uses.
do {
    let catalogText = pp_fx_catalog_json()!
    let catalog = (try? JSONSerialization.jsonObject(with: Data(String(cString: catalogText).utf8))) as? [[String: Any]] ?? []
    pp_fx_free_string(catalogText)
    let types = catalog.compactMap { $0["type"] as? String }
    check("effects catalog lists the built-ins", types.count >= 12 && types.contains("limiter") && types.contains("eq"), "\(types)")

    let m = pp_mixer_create(48000)!
    pp_mixer_set_input_active(m, 0, 1)
    pp_mixer_set_output_active(m, 0, 1)
    pp_mixer_set_input_to_output(m, 0, 0, 1)
    pp_mixer_set_input_gain(m, 0, 0.5)
    check("a strip's effects are set", pp_mixer_set_effects(m, Int32(PP_KIND_STRIP), 0, "gain\t1\tgainDb=6.0206") == 1)
    func run(_ value: Float, blocks: Int = 400) -> Float {
        var peak: Float = 0
        for _ in 0..<blocks {
            fill(m, 0, value, value)
            pp_mixer_process(m, 128)
            peak = pp_mixer_output_left(m, 0)[127]
        }
        return peak
    }
    let doubled = run(0.25)
    check("strip effects come before the fader: 0.25, +6 dB, fader 0.5", abs(doubled - 0.25) < 0.002, "\(doubled)")
    check("changing a parameter keeps the chain", pp_mixer_set_effects(m, Int32(PP_KIND_STRIP), 0, "gain\t1\tgainDb=0") == 1)
    let unity = run(0.25)
    check("and the new value applies", abs(unity - 0.125) < 0.002, "\(unity)")
    check("bypassing an effect", pp_mixer_set_effects(m, Int32(PP_KIND_STRIP), 0, "gain\t0\tgainDb=12") == 1 && abs(run(0.25) - 0.125) < 0.002)
    check("no effects", pp_mixer_set_effects(m, Int32(PP_KIND_STRIP), 0, "") == 0 && abs(run(0.25) - 0.125) < 0.002)
    check("a bad spec is refused", pp_mixer_set_effects(m, Int32(PP_KIND_STRIP), 0, "gain\t1\tgainDb=loud") == -1)

    // A limiter on the output, after its fader, holds the ceiling the hard clip used to.
    pp_mixer_set_input_gain(m, 0, 1)
    pp_mixer_set_effects(m, Int32(PP_KIND_OUTPUT), 0, "limiter\t1\tceiling=-6")
    var peak: Float = 0
    var phase = 0.0
    for block in 0..<800 {
        let l = pp_mixer_input_left(m, 0)!, r = pp_mixer_input_right(m, 0)!
        for i in 0..<128 {
            let v = Float(sin(phase))
            l[i] = v
            r[i] = v
            phase += 2 * Double.pi * 1000 / 48000
        }
        pp_mixer_process(m, 128)
        if block > 400 {
            for i in 0..<128 { peak = max(peak, abs(pp_mixer_output_left(m, 0)[i])) }
        }
    }
    check(String(format: "an output limiter holds -6 dBFS with a 0 dBFS sine in (%.2f dBFS)", 20 * log10(peak)),
        peak <= 0.5012 && peak > 0.45)
    let meter = pp_mixer_read_output_meter(m, 0)
    check("the output meter reads after the limiter", meter.peakLeft <= 0.5012, "\(meter)")
    pp_mixer_collect(m)

    // Every effect at its defaults: finite output from noise, and what each costs.
    pp_mixer_set_effects(m, Int32(PP_KIND_OUTPUT), 0, "")
    var generator = SeededRandom()
    var report: [String] = []
    var allFinite = true
    for type in types {
        pp_mixer_set_effects(m, Int32(PP_KIND_STRIP), 0, "\(type)\t1\t")
        let blocks = 375 * 4 // 4 s at 48 kHz
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<blocks {
            let l = pp_mixer_input_left(m, 0)!, r = pp_mixer_input_right(m, 0)!
            for i in 0..<128 {
                l[i] = Float.random(in: -0.3...0.3, using: &generator)
                r[i] = l[i]
            }
            pp_mixer_process(m, 128)
            let out = pp_mixer_output_left(m, 0)!
            for i in 0..<128 where !out[i].isFinite { allFinite = false }
        }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        report.append(String(format: "%@ %.2f%%", type, 100 * seconds / 4))
        pp_mixer_collect(m)
    }
    check("every effect gives finite output from noise", allFinite)
    print("cost of each effect at 48 kHz, stereo, 128-frame blocks, % of a core (with the test's noise):\n  " + report.joined(separator: ", "))
    pp_mixer_destroy(m)
}

// The EQ curve the editor draws, from the engine's own filters.
do {
    let freqs: [Double] = [100, 1000, 10000]
    var out = [Double](repeating: 0, count: 3)
    pp_fx_eq_curve("", 0, 48000, freqs, &out, 3)
    check("a new EQ is flat", out.allSatisfy { abs($0) < 0.01 }, "\(out)")
    pp_fx_eq_curve("b3Gain=6;b3Freq=1000;b3Q=1", 0, 48000, freqs, &out, 3)
    check("a +6 dB bell at 1 kHz reads +6 there and little far away",
        abs(out[1] - 6) < 0.05 && abs(out[0]) < 0.5 && abs(out[2]) < 0.5, "\(out)")
    pp_fx_eq_curve("b3Gain=6;b3On=0", 0, 48000, freqs, &out, 3)
    check("a band that's off isn't in the total", abs(out[1]) < 0.01, "\(out)")
    pp_fx_eq_curve("b3Gain=6;b3On=0", 3, 48000, freqs, &out, 3)
    check("but drawn alone it is", abs(out[1] - 6) < 0.05, "\(out)")
    pp_fx_eq_curve("b1Type=3;b1Freq=200", 0, 48000, freqs, &out, 3)
    check("a low cut at 200 Hz takes 100 Hz down", out[0] < -6 && abs(out[2]) < 0.1, "\(out)")
    // And the engine agrees with the drawing: a 1 kHz tone through the same EQ.
    let m = pp_mixer_create(48000)!
    pp_mixer_set_input_active(m, 0, 1)
    pp_mixer_set_output_active(m, 0, 1)
    pp_mixer_set_input_to_output(m, 0, 0, 1)
    pp_mixer_set_effects(m, Int32(PP_KIND_STRIP), 0, "eq\t1\tb3Gain=6;b3Freq=1000;b3Q=1")
    var phase = 0.0, peak: Float = 0
    for block in 0..<400 {
        let l = pp_mixer_input_left(m, 0)!, r = pp_mixer_input_right(m, 0)!
        for i in 0..<128 {
            l[i] = Float(0.1 * sin(phase)); r[i] = l[i]
            phase += 2 * Double.pi * 1000 / 48000
        }
        pp_mixer_process(m, 128)
        if block > 200 { for i in 0..<128 { peak = max(peak, pp_mixer_output_left(m, 0)[i]) } }
    }
    check(String(format: "the engine plays the curve: +%.2f dB at 1 kHz", 20 * log10(peak / 0.1)), abs(20 * log10(peak / 0.1) - 6) < 0.1)
    pp_mixer_destroy(m)
}

// The ducker: music on one strip, turned down while another strip (its key) is loud.
do {
    let m = pp_mixer_create(48000)!
    for i in 0..<4 { pp_mixer_set_input_active(m, Int32(i), 1) }
    pp_mixer_set_output_active(m, 0, 1)
    pp_mixer_set_input_to_output(m, 0, 0, 1) // only the music reaches the output
    pp_mixer_set_effects(m, Int32(PP_KIND_STRIP), 0, "ducker\t1\tthreshold=-35;depth=12;attack=5;hold=50;release=100")
    check("a strip can't duck under itself", pp_mixer_set_key(m, Int32(PP_KIND_STRIP), 0, 0) == -1)
    // The key is strip 3, which comes later in the list: it must still run first.
    check("a key from a later strip is taken", pp_mixer_set_key(m, Int32(PP_KIND_STRIP), 0, 3) == 0)
    func level(voice: Float) -> Float {
        var peak: Float = 0
        for block in 0..<375 { // 1 s
            fill(m, 0, 0.25, 0.25)
            fill(m, 1, 0, 0)
            fill(m, 2, 0, 0)
            let l = pp_mixer_input_left(m, 3)!, r = pp_mixer_input_right(m, 3)!
            for i in 0..<128 { l[i] = voice * Float(sin(Double(block * 128 + i) * 0.2)); r[i] = l[i] }
            pp_mixer_process(m, 128)
            if block > 300 { peak = max(peak, pp_mixer_output_left(m, 0)[127]) }
        }
        return peak
    }
    let quiet = level(voice: 0)
    check("with the key quiet, the music is untouched", abs(quiet - 0.25) < 0.002, "\(quiet)")
    let ducked = level(voice: 0.3)
    check(String(format: "with the key loud, the music drops by the depth (%.1f dB)", 20 * log10(ducked / 0.25)),
        abs(20 * log10(ducked / 0.25) + 12) < 0.5)
    let back = level(voice: 0)
    check("and comes back when the key stops", abs(back - 0.25) < 0.002, "\(back)")
    // Loops: 0 is keyed by 3; 3 keyed by 1 is fine, then 1 keyed by 0 would close a circle.
    check("a chain of keys is fine", pp_mixer_set_key(m, Int32(PP_KIND_STRIP), 3, 1) == 0)
    check("a loop of keys is refused", pp_mixer_set_key(m, Int32(PP_KIND_STRIP), 1, 0) == -2)
    check("and the music still ducks under strip 3", abs(20 * log10(level(voice: 0.3) / 0.25) + 12) < 0.5)
    // A bus or output can be keyed by any strip.
    check("an output can duck under a strip", pp_mixer_set_key(m, Int32(PP_KIND_OUTPUT), 0, 3) == 0)
    pp_mixer_destroy(m)
}

// A mono strip runs its effects once: the same sound as running both sides, for less.
do {
    let chain = ["denoise\t1\t", "eq\t1\tb1Type=3;b1Freq=90;b4Gain=2.5;b4Freq=3500", "compressor\t1\tamount=60",
        "deesser\t1\t", "limiter\t1\tceiling=-1;truePeak=1"].joined(separator: "\n")
    func run(mono: Bool) -> (out: [Float], seconds: Double) {
        let m = pp_mixer_create(48000)!
        pp_mixer_set_input_active(m, 0, 1)
        pp_mixer_set_output_active(m, 0, 1)
        pp_mixer_set_input_to_output(m, 0, 0, 1)
        pp_mixer_set_input_mono(m, 0, mono ? 1 : 0)
        pp_mixer_set_effects(m, Int32(PP_KIND_STRIP), 0, chain)
        var seed: UInt64 = 1 // the same noise for both runs
        func noise() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return (Double(seed >> 11) / Double(1 << 53) - 0.5) * 0.006
        }
        var out: [Float] = []
        var phase = 0.0
        let start = threadSeconds()
        for block in 0..<1500 { // 4 s
            let l = pp_mixer_input_left(m, 0)!, r = pp_mixer_input_right(m, 0)!
            for i in 0..<128 {
                // A voice-ish tone that comes and goes, over a little noise; the same on both sides.
                let on = (block / 100) % 2 == 0 ? 0.3 : 0.0
                l[i] = Float(on * sin(phase) + noise())
                r[i] = l[i]
                phase += 2 * Double.pi * 220 / 48000
            }
            pp_mixer_process(m, 128)
            if block >= 1400 {
                out.append(contentsOf: UnsafeBufferPointer(start: pp_mixer_output_left(m, 0), count: 128))
                for i in 0..<128 where pp_mixer_output_left(m, 0)[i] != pp_mixer_output_right(m, 0)[i] { out.append(.nan) }
            }
        }
        let seconds = threadSeconds() - start
        pp_mixer_destroy(m)
        return (out, seconds)
    }
    // Best of three each, taken in turn, so a neighbour's burst can't decide it.
    var stereo = run(mono: false), mono = run(mono: true)
    for _ in 0..<2 {
        let s = run(mono: false), m = run(mono: true)
        if s.seconds < stereo.seconds { stereo = s }
        if m.seconds < mono.seconds { mono = m }
    }
    check("mono: left and right come out the same", !mono.out.contains { $0.isNaN })
    let worst = zip(stereo.out, mono.out).map { abs($0 - $1) }.max() ?? 1
    check(String(format: "mono sounds the same as stereo (largest difference %.2g)", worst), worst < 1e-5 && stereo.out.count == mono.out.count)
    check(String(format: "mono costs less: %.2f%% of a core against %.2f%% (with the test's own work)", 100 * mono.seconds / 4, 100 * stereo.seconds / 4),
        mono.seconds < stereo.seconds * 0.8)
}

// A muted strip's effects stop once the fade is done, and start clean on unmute.
do {
    let m = pp_mixer_create(48000)!
    pp_mixer_set_input_active(m, 0, 1)
    pp_mixer_set_output_active(m, 0, 1)
    pp_mixer_set_input_to_output(m, 0, 0, 1)
    func time(_ blocks: Int, _ value: Float) -> Double {
        let start = threadSeconds()
        for _ in 0..<blocks { fill(m, 0, value, value); pp_mixer_process(m, 128) }
        return threadSeconds() - start
    }
    pp_mixer_set_effects(m, Int32(PP_KIND_STRIP), 0, "denoise\t1\t\nmultiband\t1\t\neq\t1\t\ncompressor\t1\t")
    // Best of three each (see threadSeconds).
    var awake = time(1500, 0.1)
    for _ in 0..<2 { awake = min(awake, time(1500, 0.1)) }
    pp_mixer_set_input_mute(m, 0, 1)
    _ = time(20, 0.1) // the fade
    var muted = time(1500, 0.1)
    for _ in 0..<2 { muted = min(muted, time(1500, 0.1)) }
    check(String(format: "a muted strip's effects stop: %.2f%% of a core muted, %.2f%% playing", 100 * muted / 4, 100 * awake / 4),
        muted < awake * 0.25)
    // Unmute: the chain starts clean. A 50 ms delay held a tone when it was muted; none of
    // it may come out after.
    pp_mixer_set_input_mute(m, 0, 0)
    pp_mixer_set_effects(m, Int32(PP_KIND_STRIP), 0, "delay\t1\ttime=50")
    _ = time(100, 0.2)
    pp_mixer_set_input_mute(m, 0, 1)
    _ = time(10, 0.2) // fading out, still sounding
    _ = time(40, 0)   // asleep, holding the tone
    pp_mixer_set_input_mute(m, 0, 0)
    var leaked: Float = 0
    for _ in 0..<40 {
        fill(m, 0, 0, 0)
        pp_mixer_process(m, 128)
        for i in 0..<128 { leaked = max(leaked, abs(pp_mixer_output_left(m, 0)[i])) }
    }
    check("nothing from before the mute comes out after it", leaked == 0, "\(leaked)")
    // A reverb's tail would freeze and come back: a chain with one keeps running.
    pp_mixer_set_effects(m, Int32(PP_KIND_STRIP), 0, "reverb\t1\t")
    check("a chain with a reverb doesn't stop", pp_fx_can_sleep(pp_mixer_effects(m, Int32(PP_KIND_STRIP), 0)) == 0)
    pp_mixer_set_effects(m, Int32(PP_KIND_STRIP), 0, "eq\t1\t")
    check("one without may", pp_fx_can_sleep(pp_mixer_effects(m, Int32(PP_KIND_STRIP), 0)) == 1)
    pp_mixer_destroy(m)
}

// Cue: what's cued plays to the cue output instead of its own mix.
do {
    let m = pp_mixer_create(48000)!
    for i in 0..<2 { pp_mixer_set_input_active(m, Int32(i), 1) }
    pp_mixer_set_bus_active(m, 0, 1)
    pp_mixer_set_output_active(m, 0, 1) // the stream
    pp_mixer_set_output_active(m, 1, 1) // headphones, the cue output
    pp_mixer_set_input_to_output(m, 0, 0, 1)   // mic to the stream
    pp_mixer_set_input_to_output(m, 1, 1, 1)   // music to the headphones
    pp_mixer_set_input_to_bus(m, 1, 0, 1)
    pp_mixer_set_input_gain(m, 0, 0.5)
    pp_mixer_set_effects(m, Int32(PP_KIND_STRIP), 0, "gain\t1\tgainDb=6.0206")
    pp_mixer_set_cue_output(m, 1)
    func run(_ blocks: Int = 40) -> (stream: Float, phones: Float) {
        for _ in 0..<blocks {
            fill(m, 0, 0.1, 0.1) // mic
            fill(m, 1, 0.3, 0.3) // music
            pp_mixer_process(m, 128)
        }
        return (pp_mixer_output_left(m, 0)[127], pp_mixer_output_left(m, 1)[127])
    }
    var r = run()
    check("nothing cued: the headphones play their own mix", abs(r.phones - 0.3) < 1e-4, "\(r)")
    pp_mixer_set_cued(m, Int32(PP_KIND_STRIP), 0, 1)
    r = run()
    check("PFL: the mic after its effects, before its fader (0.1, +6 dB)", abs(r.phones - 0.2) < 1e-4, "\(r)")
    check("and the stream is untouched", abs(r.stream - 0.1) < 1e-4, "\(r)")
    pp_mixer_set_cue_pre_fader(m, 0)
    r = run()
    check("AFL: after its fader (0.5)", abs(r.phones - 0.1) < 1e-4, "\(r)")
    pp_mixer_set_cue_pre_fader(m, 1)
    pp_mixer_set_input_mute(m, 0, 1)
    r = run()
    check("PFL hears a muted mic, effects and all", abs(r.phones - 0.2) < 1e-4 && abs(r.stream) < 1e-6, "\(r)")
    pp_mixer_set_input_mute(m, 0, 0)
    pp_mixer_set_cue_level(m, 0.5)
    r = run()
    check("the cue level", abs(r.phones - 0.1) < 1e-4, "\(r)")
    pp_mixer_set_cue_level(m, 1)
    pp_mixer_set_cued(m, Int32(PP_KIND_BUS), 0, 1)
    r = run()
    check("two things cued add up (mic 0.2, the music's bus 0.3)", abs(r.phones - 0.5) < 1e-4, "\(r)")
    pp_mixer_set_cued(m, Int32(PP_KIND_STRIP), 0, 0)
    pp_mixer_set_cued(m, Int32(PP_KIND_BUS), 0, 0)
    // Switching back crossfades: no step bigger than a 10 ms glide allows.
    var worst: Float = 0, last = pp_mixer_output_left(m, 1)[127]
    for _ in 0..<10 {
        fill(m, 0, 0.1, 0.1); fill(m, 1, 0.3, 0.3)
        pp_mixer_process(m, 128)
        for i in 0..<128 {
            worst = max(worst, abs(pp_mixer_output_left(m, 1)[i] - last))
            last = pp_mixer_output_left(m, 1)[i]
        }
    }
    check("uncueing crossfades back, no click", worst < 0.01, "\(worst)")
    check("and the headphones have their own mix again", abs(last - 0.3) < 1e-4, "\(last)")
    pp_mixer_destroy(m)
}

// An Audio Unit in a chain: Apple's EQ, loaded out of process, in the external slot.
do {
    var desc = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: 0x6E626571 /* nbeq */,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    let component = AudioComponentFindNext(nil, &desc)!
    var unit: AudioUnit?
    let done = DispatchSemaphore(value: 0)
    AudioComponentInstantiate(component, .loadOutOfProcess) { u, _ in unit = u; done.signal() }
    while done.wait(timeout: .now()) == .timedOut { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    let au = unit!
    var f = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagsNativeEndian,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    let size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f, size)
    AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &f, size)
    var maxFrames: UInt32 = 4096
    AudioUnitSetProperty(au, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, 4)
    check("the EQ loads out of process and starts", AudioUnitInitialize(au) == noErr)
    let wrapped = pp_au_create(au, 2, 2, 4096, 0, 48000)!
    let m = pp_mixer_create(48000)!
    pp_mixer_set_input_active(m, 0, 1)
    pp_mixer_set_output_active(m, 0, 1)
    pp_mixer_set_input_to_output(m, 0, 0, 1)
    check("a chain takes a plugin's slot", pp_mixer_set_effects(m, Int32(PP_KIND_STRIP), 0, "au:aufx:nbeq:appl\t1\t\ngain\t1\tgainDb=6.0206") == 2)
    let fx = pp_mixer_effects(m, Int32(PP_KIND_STRIP), 0)!
    check("the slot is external, the gain isn't", pp_fx_is_external(fx, 0) == 1 && pp_fx_is_external(fx, 1) == 0)
    func run() -> Float {
        var phase = 0.0, peak: Float = 0
        for block in 0..<200 {
            let l = pp_mixer_input_left(m, 0)!, r = pp_mixer_input_right(m, 0)!
            for i in 0..<128 { l[i] = Float(0.1 * sin(phase)); r[i] = l[i]; phase += 2 * Double.pi * 1000 / 48000 }
            pp_mixer_process(m, 128)
            if block > 100 { for i in 0..<128 { peak = max(peak, pp_mixer_output_left(m, 0)[i]) } }
        }
        return peak
    }
    let dry = run()
    check(String(format: "before it's attached the slot is dry (%.3f: the tone, +6 dB)", dry), abs(dry - 0.2) < 0.002)
    check("attaching", pp_fx_attach(fx, 0, pp_au_external(wrapped)) == 0 && pp_fx_attach(fx, 1, pp_au_external(wrapped)) == -1)
    let start = DispatchTime.now().uptimeNanoseconds
    let wet = run()
    let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    check(String(format: "the flat EQ passes the tone through (%.3f), %.3f ms a block with the handoff, %llu blocks late",
        wet, 1000 * seconds / 200, pp_au_late(wrapped)), abs(wet - 0.2) < 0.002 && pp_fx_external_dead(fx, 0) == 0)
    // A rebuilt chain (a new effect added in front) has a fresh, empty slot.
    pp_mixer_set_effects(m, Int32(PP_KIND_STRIP), 0, "gain\t1\tgainDb=0\nau:aufx:nbeq:appl\t1\t\ngain\t1\tgainDb=6.0206")
    let fresh = pp_mixer_effects(m, Int32(PP_KIND_STRIP), 0)!
    check("a rebuilt chain's slot starts empty", pp_fx_is_external(fresh, 1) == 1 && pp_fx_attach(fresh, 1, pp_au_external(wrapped)) == 0)
    _ = run()
    pp_mixer_collect(m)
    pp_mixer_destroy(m)
    pp_au_destroy(wrapped)
    AudioUnitUninitialize(au)
    AudioComponentInstanceDispose(au)
}

print(failures == 0 ? "all passed" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
