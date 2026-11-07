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

let oldM2 = DeviceSignature(uid: "com_motu_driver_coreuac_control_interface:m2test000001", name: "M2",
    transport: "USB", serial: "M2TEST000001")
let newM2 = DeviceSignature(uid: "AppleUSBAudioEngine:MOTU:M2:M2TEST000001:1,2", name: "M2",
    transport: "USB", serial: "M2TEST000001")
let speakers = DeviceSignature(uid: "BuiltInSpeakerDevice", name: "Mac Studio Speakers", transport: "Built-in", serial: "")
let dell = DeviceSignature(uid: "aa-bb:hdmi", name: "DELL S2722QC", transport: "HDMI", serial: "")

// A device that changes driver (and UID) must not need every setup repointing by hand.
check("device follows a driver change by serial", DeviceSignature.match(oldM2, in: [speakers, newM2]) == newM2)
check("exact UID wins", DeviceSignature.match(speakers, in: [speakers, newM2]) == speakers)
let movedDell = DeviceSignature(uid: "cc-dd:hdmi", name: "DELL S2722QC", transport: "HDMI", serial: "")
check("no serial: matches by name and transport", DeviceSignature.match(dell, in: [speakers, movedDell]) == movedDell)
let dellTwo = DeviceSignature(uid: "ee-ff:hdmi", name: "DELL S2722QC", transport: "HDMI", serial: "")
check("two alike is refused, not guessed", DeviceSignature.match(dell, in: [movedDell, dellTwo]) == nil)
let otherM2 = DeviceSignature(uid: "AppleUSBAudioEngine:MOTU:M2:M2OTHER:1,2", name: "M2", transport: "USB", serial: "M2OTHER")
check("a different unit with a serial isn't taken for ours", DeviceSignature.match(oldM2, in: [otherM2]) == nil)
check("an absent device is offline, not a wrong match", DeviceSignature.match(oldM2, in: [speakers]) == nil)

// A strip with no channel must be reported, not left silent and unexplained.
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
do {
    var keyed = Settings()
    keyed.strips = [Strip(slot: 0, label: "Music", source: .virtual(slot: 0)), Strip(slot: 1, label: "Mic", source: .virtual(slot: 1))]
    keyed.strips[0].effects = [EffectSetting(type: "ducker", key: 1)]
    check("a ducker listening to another strip is fine", keyed.problems().isEmpty, "\(keyed.problems())")
    check("the chain's key is its ducker's", keyed.strips[0].effects.key == 1)
    var looped = keyed
    looped.strips[1].effects = [EffectSetting(type: "ducker", key: 0)]
    check("strips ducking under each other is a loop", looped.problems().contains { $0.contains("loop") }, "\(looped.problems())")
    var itself = keyed
    itself.strips[0].effects[0].key = 0
    check("a strip ducking under itself is reported", itself.problems().contains { $0.contains("itself") })
    var gone = keyed
    gone.strips[0].effects[0].key = 7
    check("a key that doesn't exist is reported", gone.problems().contains { $0.contains("doesn't exist") })
    let old = #"{"type":"ducker","enabled":true,"params":{}}"#
    check("an effect saved before keys loads with none", (try? JSONDecoder().decode(EffectSetting.self, from: Data(old.utf8)))?.key == nil)
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
    check("built-in voice chains are there", again.chain("Podcast voice")?.count == 6 && BuiltInChains.names.count == 5
        && again.chain("Streaming voice")?.first?.type == "denoise")
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

// Scenes.
do {
    var base = Settings()
    base.buses = [Bus(slot: 0, label: "Stream")]
    base.outputs = [Output(slot: 0, label: "Stream Mic", sink: .virtual(slot: 1)), Output(slot: 1, label: "Speakers", sink: .virtual(slot: 2))]
    base.strips = [Strip(slot: 0, label: "Mic", source: .virtual(slot: 0)), Strip(slot: 1, label: "Music", source: .virtual(slot: 3))]
    base.strips[0].busSends = [Send(to: 0, gain: 1)]
    base.strips[1].outputSends = [Send(to: 1, gain: 0.5)]
    base.strips[1].effects = [EffectSetting(type: "ducker", key: 0)]
    var radio = base
    radio.strips[0].gain = 0.25
    radio.strips[1].muted = true
    radio.strips[0].effects = [EffectSetting(type: "gate")]
    let scene = MixScene(name: "Radio", from: radio, defaultOutput: "", defaultInput: "")
    let (back, count) = scene.applied(to: base)
    check("a scene brings back levels, mutes and effects", count == 5 && back.strips[0].gain == 0.25
        && back.strips[1].muted && back.strips[0].effects.first?.type == "gate")
    check("and changes nothing else", back.strips.map(\.source) == base.strips.map(\.source) && back.outputs.map(\.sink) == base.outputs.map(\.sink))
    // The strips moved: Music is in slot 0 now, Mic in slot 5, and a new strip took slot 1.
    var moved = Settings()
    moved.buses = [Bus(slot: 3, label: "Stream")]
    moved.outputs = [Output(slot: 0, label: "Speakers", sink: .virtual(slot: 2))]
    moved.strips = [Strip(slot: 0, label: "Music", source: .virtual(slot: 3)), Strip(slot: 1, label: "Guest", source: .virtual(slot: 4)),
        Strip(slot: 5, label: "Mic", source: .virtual(slot: 0))]
    let (landed, n) = MixScene(name: "Base", from: base, defaultOutput: "", defaultInput: "").applied(to: moved)
    check("strips are found by name wherever they are now", n == 4 && landed.strips[2].busSends == [Send(to: 3, gain: 1)]
        && landed.strips[0].outputSends == [Send(to: 0, gain: 0.5)], "\(landed.strips.map(\.busSends)) \(landed.strips.map(\.outputSends))")
    check("a ducker's key follows its strip", landed.strips[0].effects.first?.key == 5)
    check("a strip the scene doesn't know is left alone", landed.strips[1] == moved.strips[1])
    check("and the result is a valid setup", landed.problems().isEmpty, "\(landed.problems())")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ppscenes-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SceneStore(folder: dir)
    try store.save(scene)
    try store.save(MixScene(name: "  apple / pie ", from: base, defaultOutput: "x", defaultInput: ""))
    check("scenes save and list by name", store.names() == ["apple / pie", "Radio"], "\(store.names())")
    check("and load back the same", store.load("Radio")?.strips == scene.strips && store.load("apple / pie")?.defaultOutput == "x")
    check("and can be deleted", store.remove("Radio") && store.names() == ["apple / pie"])
} catch {
    check("scenes", false, "\(error)")
}

// Plugins.
do {
    check("Waves names split into plugin and channels", AudioUnitCatalog.split("C1 comp (m)") == ("C1 comp", "m")
        && AudioUnitCatalog.split("IR-L (m->s)") == ("IR-L", "m->s") && AudioUnitCatalog.split("AUNBandEQ") == ("AUNBandEQ", "")
        && AudioUnitCatalog.split("NX (5->2)") == ("NX", "5->2") && AudioUnitCatalog.split("Mix (Live)") == ("Mix (Live)", ""))
    let surround = PluginVariant(id: "x", channels: "5->2", name: "NX (5->2)"), monoToStereo = PluginVariant(id: "y", channels: "m->s", name: "A (m->s)")
    check("channel counts are read from the name", surround.inputs == 5 && surround.outputs == 2 && monoToStereo.inputs == 1 && monoToStereo.outputs == 2)
    check("a surround version doesn't fit a strip", !surround.fitsStrips && monoToStereo.fitsStrips)
    let start = Date()
    let all = AudioUnitCatalog.list()
    let took = Date().timeIntervalSince(start)
    check(String(format: "every installed AU is listed without loading any (%d in %.2f s)", all.count, took), !all.isEmpty && took < 0.5)
    if let eq = all.first(where: { $0.maker == "Apple" && $0.name == "AUNBandEQ" }) {
        check("an AU's id gives back its description", AudioUnitCatalog.description(eq.variants[0].id).map { AudioUnitCatalog.id($0) } == eq.variants[0].id)
        check("Apple's metadata gives categories", eq.categories.contains("Equalizer"), "\(eq.categories)")
    }
    if let c1 = all.first(where: { $0.maker == "Waves" && $0.name == "C1 comp" }) {
        check("a Waves plugin is one entry with its variants", Set(c1.variants.map(\.channels)) == ["m", "s"], "\(c1.variants)")
        check("a mono strip gets the mono variant, a stereo one the stereo", c1.variant(channels: 1)?.channels == "m" && c1.variant(channels: 2)?.channels == "s")
    }
    var filter = PluginFilter()
    let synth = PluginEntry(format: .au, maker: "X", name: "Synth", version: "1", kind: .instrument, categories: [], variants: [], hasCustomView: false)
    let fx = PluginEntry(format: .au, maker: "X", name: "Comp", version: "1", kind: .effect, categories: ["Dynamics Processor"], variants: [], hasCustomView: false)
    check("instruments are hidden by default, effects shown", !filter.shows(synth) && filter.shows(fx))
    filter.hiddenMakers = ["X"]
    check("a hidden maker hides its plugins", !filter.shows(fx))
    filter = PluginFilter(); filter.hiddenCategories = ["Dynamics Processor"]
    check("so does a hidden category", !filter.shows(fx))
    var cache = PluginCache()
    let v = PluginVariant(id: "au:aufx:abcd:Xxxx", channels: "", name: "Comp")
    let entry = PluginEntry(format: .au, maker: "X", name: "Comp", version: "2", kind: .effect, categories: [], variants: [v], hasCustomView: false)
    check("an unchecked plugin has no status", cache.status(entry) == nil)
    cache.checks[v.id] = PluginCheck(status: .ok, version: "1")
    check("a check of an older version doesn't count", cache.status(entry) == nil)
    cache.checks[v.id] = PluginCheck(status: .crashed, version: "2")
    check("one at this version does", cache.status(entry) == .crashed)
    let old = #"{"strips":[]}"#
    check("settings from before plugins load with the default filter",
        (try? JSONDecoder().decode(Settings.self, from: Data(old.utf8)))?.pluginFilter == PluginFilter())
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
