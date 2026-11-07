// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// Scenes, as in Patch Prime (engine/src/scenes.cpp): a scene is the mix. Every
// strip's, bus's and output's level, mute, sends and effects, and the system default
// output and input. Loading one changes only those: it never adds, removes or
// restarts anything, so it's safe mid-stream. Strips it doesn't mention stay as they
// are, and ones that are gone are skipped.
//
// One file per scene in scenes/ beside the settings, named from the scene's name
// (the name itself is kept inside), so scenes are easy to copy or back up.

import CryptoKit
import Foundation

public struct MixScene: Codable, Equatable, Sendable {
    public struct StripMix: Codable, Equatable, Sendable {
        public var slot: Int
        public var label: String
        public var gain: Float
        public var muted: Bool
        public var busSends: [Send]
        public var outputSends: [Send]
        public var effects: [EffectSetting]
        public var effectsOn: Bool
    }

    public struct BusMix: Codable, Equatable, Sendable {
        public var slot: Int
        public var label: String
        public var gain: Float
        public var muted: Bool
        public var outputSends: [Send]
        public var effects: [EffectSetting]
        public var effectsOn: Bool
    }

    public struct OutputMix: Codable, Equatable, Sendable {
        public var slot: Int
        public var label: String
        public var gain: Float
        public var muted: Bool
        public var effects: [EffectSetting]
        public var effectsOn: Bool
    }

    public var version = 1
    public var name: String
    public var saved: Date
    public var strips: [StripMix]
    public var buses: [BusMix]
    public var outputs: [OutputMix]
    /// The system default output and input, by device UID ("" for no change).
    public var defaultOutput: String
    public var defaultInput: String

    /// The mix as it is now.
    public init(name: String, from s: Settings, defaultOutput: String, defaultInput: String) {
        self.name = name
        saved = Date()
        strips = s.strips.map {
            StripMix(slot: $0.slot, label: $0.label, gain: $0.gain, muted: $0.muted, busSends: $0.busSends,
                outputSends: $0.outputSends, effects: $0.effects, effectsOn: $0.effectsOn)
        }
        buses = s.buses.map {
            BusMix(slot: $0.slot, label: $0.label, gain: $0.gain, muted: $0.muted, outputSends: $0.outputSends,
                effects: $0.effects, effectsOn: $0.effectsOn)
        }
        outputs = s.outputs.map {
            OutputMix(slot: $0.slot, label: $0.label, gain: $0.gain, muted: $0.muted, effects: $0.effects,
                effectsOn: $0.effectsOn)
        }
        self.defaultOutput = defaultOutput
        self.defaultInput = defaultInput
    }

    /// Finds where a scene's strip, bus or output is now: by name, then by slot if the
    /// thing in that slot isn't claimed by name by another.
    static func place(_ label: String, _ slot: Int, in current: [(slot: Int, label: String)],
        claimed: Set<String>) -> Int? {
        let byName = current.filter { $0.label == label }
        if byName.count == 1 { return byName[0].slot }
        if byName.count > 1 { return byName.first { $0.slot == slot }?.slot ?? byName[0].slot }
        if let same = current.first(where: { $0.slot == slot }), !claimed.contains(same.label) { return same.slot }
        return nil
    }

    /// The settings with this scene's mix applied, and how many strips, buses and
    /// outputs it set. Sends to buses or outputs that are gone are dropped, and so are
    /// keys to strips that are gone.
    public func applied(to settings: Settings) -> (Settings, Int) {
        var s = settings
        var count = 0
        // Where each of the scene's buses, outputs and strips is now, for the sends.
        var busAt: [Int: Int] = [:], outputAt: [Int: Int] = [:], stripAt: [Int: Int] = [:]
        let busNames = Set(buses.map(\.label)), outputNames = Set(outputs.map(\.label)), stripNames = Set(strips.map(\.label))
        for b in buses {
            if let at = Self.place(b.label, b.slot, in: s.buses.map { ($0.slot, $0.label) }, claimed: busNames) { busAt[b.slot] = at }
        }
        for o in outputs {
            if let at = Self.place(o.label, o.slot, in: s.outputs.map { ($0.slot, $0.label) }, claimed: outputNames) { outputAt[o.slot] = at }
        }
        for st in strips {
            if let at = Self.place(st.label, st.slot, in: s.strips.map { ($0.slot, $0.label) }, claimed: stripNames) { stripAt[st.slot] = at }
        }
        func sends(_ list: [Send], _ map: [Int: Int]) -> [Send] {
            list.compactMap { send in map[send.to].map { Send(to: $0, gain: send.gain) } }
        }
        func effects(_ list: [EffectSetting]) -> [EffectSetting] {
            list.map { e in
                var e = e
                if let key = e.key { e.key = stripAt[key] }
                return e
            }
        }
        for st in strips {
            guard let at = stripAt[st.slot], let i = s.strips.firstIndex(where: { $0.slot == at }) else { continue }
            s.strips[i].gain = st.gain
            s.strips[i].muted = st.muted
            s.strips[i].busSends = sends(st.busSends, busAt)
            s.strips[i].outputSends = sends(st.outputSends, outputAt)
            s.strips[i].effects = effects(st.effects)
            s.strips[i].effectsOn = st.effectsOn
            count += 1
        }
        for b in buses {
            guard let at = busAt[b.slot], let i = s.buses.firstIndex(where: { $0.slot == at }) else { continue }
            s.buses[i].gain = b.gain
            s.buses[i].muted = b.muted
            s.buses[i].outputSends = sends(b.outputSends, outputAt)
            s.buses[i].effects = effects(b.effects)
            s.buses[i].effectsOn = b.effectsOn
            count += 1
        }
        for o in outputs {
            guard let at = outputAt[o.slot], let i = s.outputs.firstIndex(where: { $0.slot == at }) else { continue }
            s.outputs[i].gain = o.gain
            s.outputs[i].muted = o.muted
            s.outputs[i].effects = effects(o.effects)
            s.outputs[i].effectsOn = o.effectsOn
            count += 1
        }
        return (s, count)
    }
}

public struct SceneStore: Sendable {
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder.appendingPathComponent("scenes")
    }

    /// A stable, safe file name: a readable part and a short hash of the exact name.
    func file(for name: String) -> URL {
        let n = PresetStore.clean(name)
        let slug = String(n.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.prefix(40))
        let hash = Insecure.SHA1.hash(data: Data(n.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent("\(slug)-\(hash).json")
    }

    public func names() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let names = files.filter { $0.pathExtension == "json" }.compactMap { url -> String? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder.scenes.decode(MixScene.self, from: data).name
        }
        return PresetStore.sorted(names)
    }

    public func load(_ name: String) -> MixScene? {
        guard let data = try? Data(contentsOf: file(for: name)) else { return nil }
        return try? JSONDecoder.scenes.decode(MixScene.self, from: data)
    }

    public func save(_ scene: MixScene) throws {
        var s = scene
        s.name = PresetStore.clean(scene.name)
        guard !s.name.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(s).write(to: file(for: s.name), options: .atomic)
    }

    public func remove(_ name: String) -> Bool {
        (try? FileManager.default.removeItem(at: file(for: name))) != nil
    }
}

extension JSONDecoder {
    static var scenes: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
