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
