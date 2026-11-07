// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// Offline tests of settings and device identity. Touches only a temporary folder.
import Foundation
import PPShared

nonisolated(unsafe) var failures = 0

func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print("\(ok ? "ok  " : "FAIL") \(name) \(detail)")
    if !ok { failures += 1 }
}

let oldM2 = DeviceSignature(uid: "com_motu_driver_coreuac_control_interface:m20000063324", name: "M2",
    transport: "USB", serial: "M20000063324")
let newM2 = DeviceSignature(uid: "AppleUSBAudioEngine:MOTU:M2:M20000063324:1,2", name: "M2",
    transport: "USB", serial: "M20000063324")
let speakers = DeviceSignature(uid: "BuiltInSpeakerDevice", name: "Mac Studio Speakers", transport: "Built-in", serial: "")
let dell = DeviceSignature(uid: "aa-bb:hdmi", name: "DELL S2722QC", transport: "HDMI", serial: "")

// CASTER's trouble: the M2 changed driver and 12 sessions needed repointing by hand.
check("device follows a driver change by serial", DeviceSignature.match(oldM2, in: [speakers, newM2]) == newM2)
check("exact UID wins", DeviceSignature.match(speakers, in: [speakers, newM2]) == speakers)
let movedDell = DeviceSignature(uid: "cc-dd:hdmi", name: "DELL S2722QC", transport: "HDMI", serial: "")
check("no serial: matches by name and transport", DeviceSignature.match(dell, in: [speakers, movedDell]) == movedDell)
let dellTwo = DeviceSignature(uid: "ee-ff:hdmi", name: "DELL S2722QC", transport: "HDMI", serial: "")
check("two alike is refused, not guessed", DeviceSignature.match(dell, in: [movedDell, dellTwo]) == nil)
let otherM2 = DeviceSignature(uid: "AppleUSBAudioEngine:MOTU:M2:M2OTHER:1,2", name: "M2", transport: "USB", serial: "M2OTHER")
check("a different unit with a serial isn't taken for ours", DeviceSignature.match(oldM2, in: [otherM2]) == nil)
check("an absent device is offline, not a wrong match", DeviceSignature.match(oldM2, in: [speakers]) == nil)

// CASTER's trouble: a track with no channel, silent and unexplained.
var bad = Settings()
bad.strips = [Strip(slot: 0, label: "RE20", source: .device(newM2, left: -2, right: -2))]
check("a strip with no channel is reported", bad.problems().contains { $0.contains("no channel") }, "\(bad.problems())")
var routes = Settings()
routes.strips = [Strip(slot: 0, label: "Mic", source: .device(newM2, left: 0, right: 0))]
routes.strips[0].busSends = [Send(to: 3, gain: 1)]
check("a send to nowhere is reported", !routes.problems().isEmpty, "\(routes.problems())")
var fine = Settings()
fine.buses = [Bus(slot: 0, label: "Stream")]
fine.outputs = [Output(slot: 0, label: "Virtual", sink: .virtual(slot: 1))]
fine.strips = [Strip(slot: 0, label: "Mic", source: .device(newM2, left: 0, right: 0))]
fine.strips[0].busSends = [Send(to: 0, gain: 1)]
fine.buses[0].outputSends = [Send(to: 0, gain: 1)]
check("a good setup has no problems", fine.problems().isEmpty, "\(fine.problems())")
check("hardware output is off by default", Settings().hardwareOutputEnabled == false)
do {
    let old = #"{"strips":[{"slot":0,"label":"Mic","source":{"virtual":{"slot":1}},"gain":0.5,"muted":false,"busSends":[],"outputSends":[]}],"buses":[{"slot":0,"label":"B","gain":1,"muted":false,"outputSends":[]}],"outputs":[{"slot":0,"label":"O","sink":{"virtual":{"slot":1}},"gain":1,"muted":false}]}"#
    let loaded = try JSONDecoder().decode(Settings.self, from: Data(old.utf8))
    check("strips, buses and outputs from before effects load with none",
        loaded.strips[0].gain == 0.5 && loaded.strips[0].effects.isEmpty && loaded.buses[0].effects.isEmpty
            && loaded.outputs[0].effects.isEmpty)
    var chain = [EffectSetting(type: "eq", params: ["b1Gain": 3, "b1Freq": 120]),
        EffectSetting(type: "compressor", enabled: false, params: ["amount": 60])]
    check("the engine's spec: one line per effect, parameters sorted",
        chain.spec == "eq\t1\tb1Freq=120.0;b1Gain=3.0\ncompressor\t0\tamount=60.0", chain.spec)
    check("all effects off bypasses each, keeping the chain", chain.spec(on: false) == "eq\t0\tb1Freq=120.0;b1Gain=3.0\ncompressor\t0\tamount=60.0")
    check("and on gives each its own switch back", chain.spec(on: true) == chain.spec)
    chain.append(contentsOf: Array(repeating: EffectSetting(type: "gain"), count: 7))
    var full = Settings()
    full.strips = [Strip(slot: 0, label: "Mic", source: .virtual(slot: 0))]
    full.strips[0].effects = chain
    check("more than 8 effects is reported", full.problems().contains { $0.contains("effects") }, "\(full.problems())")
} catch {
    check("strips from before effects load", false, "\(error)")
}
check("rate and buffer default to 48 kHz and 128", Settings().sampleRate == 48000 && Settings().bufferFrames == 128)
var odd = Settings()
odd.sampleRate = 22050
odd.bufferFrames = 100
odd.deviceBuffers["x"] = 2048
check("a rate or buffer size not on the list is reported", odd.problems().count == 3, "\(odd.problems())")
var perDevice = Settings()
perDevice.deviceBuffers["m2"] = 256
check("a device's own buffer wins", perDevice.buffer(for: "m2") == 256 && perDevice.buffer(for: "other") == 128)
do {
    let old = #"{"version":1,"strips":[],"buses":[],"outputs":[],"hardwareOutputEnabled":true,"hardwareLimit":0.5,"savedRates":{"m2":-18}}"#
    let loaded = try JSONDecoder().decode(Settings.self, from: Data(old.utf8))
    check("an older settings file loads, with defaults for the new settings",
        loaded.hardwareOutputEnabled && loaded.savedRates["m2"] == -18 && loaded.sampleRate == 48000
            && loaded.bufferFrames == 128 && loaded.keepOwnRate.isEmpty)
} catch {
    check("an older settings file loads", false, "\(error)")
}

// Presets.
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pppresets-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    var presets = PresetStore(folder: dir)
    check("no preset file is no presets", presets.load() && presets.chainNames.isEmpty)
    let chain = [EffectSetting(type: "gate", enabled: false, params: ["threshold": -40]), EffectSetting(type: "compressor", params: ["amount": 70])]
    check("a chain saves under a trimmed name", presets.saveChain("  RE20 streaming ", chain) && presets.chainNames == ["RE20 streaming"])
    _ = presets.saveChain("apple", chain)
    check("names sort without regard to case", presets.chainNames == ["apple", "RE20 streaming"], "\(presets.chainNames)")
    var again = PresetStore(folder: dir)
    again.load()
    check("chains survive a reload", again.chain("RE20 streaming") == chain)
    check("built-in voice chains are there", again.chain("Podcast voice")?.count == 6 && BuiltInChains.names.count == 5)
    check("a saved chain with a built-in's name wins", again.saveChain("Natural voice", chain) && again.chain("Natural voice") == chain)
    check("a chain can be deleted", again.removeChain("apple") && again.chain("apple") == nil)
    check("an effect preset is stored on, whatever it was", again.saveEffect("Tight", chain[0]) && again.effect("gate", "Tight")?.enabled == true)
    check("effect presets are listed by type", again.effectNames == ["gate": ["Tight"]])
    check("and can be deleted", again.removeEffect("gate", "Tight") && again.effectNames.isEmpty)
    try "{ not json".write(to: dir.appendingPathComponent("presets.json"), atomically: true, encoding: .utf8)
    var broken = PresetStore(folder: dir)
    check("an unreadable file is reported", !broken.load() && broken.lastError != nil)
    check("and not overwritten by a save", !broken.saveChain("x", chain)
        && (try? String(contentsOf: dir.appendingPathComponent("presets.json"), encoding: .utf8)) == "{ not json")
    let info = EffectInfo(type: "gate", label: "Gate", key: false, params: [
        EffectParamInfo(name: "threshold", label: "Threshold", unit: "dB", min: -80, max: 0, initial: -50, kind: "linear", options: []),
        EffectParamInfo(name: "range", label: "Range", unit: "dB", min: 0, max: 80, initial: 40, kind: "linear", options: [])])
    let filled = EffectSetting(type: "gate", params: ["threshold": -200, "bogus": 1]).filled(from: [info])
    check("loading fills what a preset leaves out, clamps, and drops unknown names",
        filled.params == ["threshold": -80, "range": 40], "\(filled.params)")
} catch {
    check("presets", false, "\(error)")
}

// Store.
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ppshared-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: folder) }
var store = Store(folder: folder)
store.keep = 3
check("no file gives empty settings", store.load().settings == Settings() && store.load().note == nil)
do {
    try store.save(fine)
    check("settings round trip", store.load().settings == fine)
    var v = fine
    for n in 1...6 {
        v.strips[0].label = "v\(n)"
        try store.save(v)
    }
    let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    check("keeps a limited history", files == ["settings.1.json", "settings.2.json", "settings.3.json", "settings.json"], "\(files)")
    let backup1 = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: folder.appendingPathComponent("settings.1.json")))
    check("the newest backup is the previous save", backup1.strips[0].label == "v5", backup1.strips[0].label)
    let text = try String(contentsOf: folder.appendingPathComponent("settings.json"), encoding: .utf8)
    check("settings are readable text", text.contains("\"label\" : \"v6\""))
    try Data("{ broken".utf8).write(to: folder.appendingPathComponent("settings.json"))
    let recovered = store.load()
    check("a broken file loads the newest good backup", recovered.settings.strips[0].label == "v5", recovered.note ?? "")
    let all = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    check("the broken file is kept, not overwritten", all.contains { $0.hasPrefix("settings.unreadable-") })
    try store.save(recovered.settings)
    check("saving works again after recovery", store.load().note == nil)
} catch {
    check("store", false, "\(error)")
}

print(failures == 0 ? "all passed" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
