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

print(failures == 0 ? "all passed" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
