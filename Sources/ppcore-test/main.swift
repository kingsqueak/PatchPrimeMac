// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// Offline tests of the mixer core. No audio device is touched.
import Foundation
import PPCore

nonisolated(unsafe) var failures = 0

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
    consumerGap: ClosedRange<Double>? = nil, producerGap: ClosedRange<Double>? = nil) -> BridgeRun {
    let rate = 48000.0
    let b = pp_bridge_create(rate, Int32(producerBlock), Int32(consumerBlock), saved)!
    var generator = SystemRandomNumberGenerator()
    let jitter = { (g: inout SystemRandomNumberGenerator) -> Double in
        Double.random(in: -60e-6...60e-6, using: &g)
    }
    let inLeft = [Float](repeating: 0.25, count: producerBlock)
    var outLeft = [Float](repeating: 0, count: consumerBlock)
    var outRight = outLeft
    var nextProducer = 0.0
    var nextConsumer = 0.0
    let producerStep = Double(producerBlock) / (rate * (1 + ppm * 1e-6))
    let consumerStep = Double(consumerBlock) / rate
    var run = BridgeRun()
    while nextProducer < seconds || nextConsumer < seconds {
        if nextProducer <= nextConsumer {
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
                if nextConsumer > seconds - 0.5 { run.peakAfterGap = max(run.peakAfterGap, outLeft.max() ?? 0) }
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
    check("with its rate intact", abs(stall.ratio - 20) < 2, "\(stall.ratio)")
}

print(failures == 0 ? "all passed" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
