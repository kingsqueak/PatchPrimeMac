// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// Presets, as in Patch Prime (engine/src/presets.cpp), kept in presets.json beside
// the settings:
// - chain presets: a whole effects chain under a name ("RE20 streaming"), to load
//   onto any strip, bus or output;
// - effect presets: one effect's settings under a name, per effect type.
// Names are trimmed; saving under a name that exists replaces it. Ready-made voice
// chains are built in: not in the file, and not deletable.

import Foundation

public struct PresetFile: Codable, Equatable, Sendable {
    public var version = 1
    public var chains: [String: [EffectSetting]] = [:]
    public var effects: [String: [String: EffectSetting]] = [:] // type, then name

    public init() {}

    enum CodingKeys: String, CodingKey { case version, chains, effects }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        chains = try c.decodeIfPresent([String: [EffectSetting]].self, forKey: .chains) ?? [:]
        effects = try c.decodeIfPresent([String: [String: EffectSetting]].self, forKey: .effects) ?? [:]
    }
}

public struct PresetStore: Sendable {
    public let file: URL
    public private(set) var presets = PresetFile()
    public private(set) var lastError: String?

    public init(folder: URL) {
        file = folder.appendingPathComponent("presets.json")
    }

    /// No file is no presets. A file that can't be read is left alone (and reported),
    /// so a save can't overwrite someone's presets with nothing.
    @discardableResult
    public mutating func load() -> Bool {
        lastError = nil
        guard let data = try? Data(contentsOf: file) else {
            presets = PresetFile()
            return true
        }
        do {
            presets = try JSONDecoder().decode(PresetFile.self, from: data)
            return true
        } catch {
            lastError = "presets.json couldn't be read: \(error.localizedDescription)"
            return false
        }
    }

    mutating func save() -> Bool {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(presets).write(to: file, options: .atomic)
            lastError = nil
            return true
        } catch {
            lastError = "presets couldn't be saved: \(error.localizedDescription)"
            return false
        }
    }

    public static func clean(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    static func sorted(_ names: some Sequence<String>) -> [String] {
        names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: Chains

    public var chainNames: [String] { Self.sorted(presets.chains.keys) }

    /// A saved chain, or a built-in one if nothing saved has that name.
    public func chain(_ name: String) -> [EffectSetting]? {
        let n = Self.clean(name)
        return presets.chains[n] ?? BuiltInChains.chain(n)
    }

    public mutating func saveChain(_ name: String, _ effects: [EffectSetting]) -> Bool {
        let n = Self.clean(name)
        guard !n.isEmpty, lastError == nil || load() else { return false }
        presets.chains[n] = effects
        return save()
    }

    public mutating func removeChain(_ name: String) -> Bool {
        presets.chains.removeValue(forKey: Self.clean(name)) != nil && save()
    }

    // MARK: Single effects

    public var effectNames: [String: [String]] { presets.effects.mapValues { Self.sorted($0.keys) } }

    public func effect(_ type: String, _ name: String) -> EffectSetting? {
        presets.effects[type]?[Self.clean(name)]
    }

    public mutating func saveEffect(_ name: String, _ effect: EffectSetting) -> Bool {
        let n = Self.clean(name)
        guard !n.isEmpty, !effect.type.isEmpty, lastError == nil || load() else { return false }
        var stored = effect
        stored.enabled = true // a preset is settings, not whether it's bypassed
        stored.key = nil      // nor which strip a ducker listens to
        presets.effects[effect.type, default: [:]][n] = stored
        return save()
    }

    public mutating func removeEffect(_ type: String, _ name: String) -> Bool {
        guard presets.effects[type]?.removeValue(forKey: Self.clean(name)) != nil else { return false }
        if presets.effects[type]?.isEmpty == true { presets.effects[type] = nil }
        return save()
    }
}

public extension EffectSetting {
    /// Every parameter the effect has, at its starting value unless this one sets it,
    /// so loading a preset over an effect resets what the preset doesn't mention.
    func filled(from catalog: [EffectInfo]) -> EffectSetting {
        guard let info = catalog.first(where: { $0.type == type }) else { return self }
        var out = info.fresh()
        out.enabled = enabled
        out.key = key
        for (name, value) in params {
            if let p = info.param(name) { out.params[name] = p.valid(value) }
        }
        return out
    }
}

/// Ready-made voice chains, as in Patch Prime.
public enum BuiltInChains {
    static let bell = 0.0, lowShelf = 1.0, highShelf = 2.0, lowCut = 3.0

    static func eq(_ bands: [(Int, Double, Double, Double, Double)]) -> EffectSetting {
        var params: [String: Double] = [:]
        for (n, type, freq, gain, q) in bands {
            params["b\(n)On"] = 1
            params["b\(n)Type"] = type
            params["b\(n)Freq"] = freq
            params["b\(n)Gain"] = gain
            params["b\(n)Q"] = q
        }
        return EffectSetting(type: "eq", params: params)
    }

    static func fx(_ type: String, _ params: [String: Double] = [:]) -> EffectSetting {
        EffectSetting(type: type, params: params)
    }

    static let limiter = fx("limiter", ["ceiling": -1, "truePeak": 1])

    public static let all: [(String, [EffectSetting])] = [
        // Spoken word for a podcast: cleaned up, even, and at -16 LUFS.
        ("Podcast voice", [
            eq([(1, lowCut, 80, 0, 0.707), (2, bell, 250, -2, 1.0), (4, bell, 3000, 2, 0.8), (6, highShelf, 12000, 1.5, 0.707)]),
            fx("expander", ["threshold": -50, "ratio": 2, "range": 15]),
            fx("compressor", ["amount": 50]),
            fx("deesser"),
            fx("leveler", ["target": -16]),
            limiter,
        ]),
        // A mic over game or music on a stream: present and steady, room noise out.
        ("Streaming voice", [
            fx("denoise"),
            eq([(1, lowCut, 90, 0, 0.707), (4, bell, 3500, 2.5, 0.8)]),
            fx("compressor", ["amount": 60]),
            fx("deesser"),
            limiter,
        ]),
        // Fans, traffic, a keyboard: noise suppression and a gate first.
        ("Noisy room", [
            fx("denoise"),
            fx("gate", ["threshold": -45, "range": 30]),
            eq([(1, lowCut, 100, 0, 0.707), (2, bell, 400, -2, 1.0)]),
            fx("compressor", ["amount": 40]),
            fx("deesser"),
            limiter,
        ]),
        // Close and big, like a radio presenter: more low end, presence and compression.
        ("Radio voice", [
            eq([(1, lowCut, 70, 0, 0.707), (2, lowShelf, 150, 3, 0.707), (4, bell, 3000, 3, 0.7), (6, highShelf, 10000, 2, 0.707)]),
            fx("expander", ["threshold": -48, "ratio": 2, "range": 15]),
            fx("compressor", ["amount": 75]),
            fx("deesser", ["threshold": -32]),
            fx("leveler", ["target": -16, "speed": 3]),
            limiter,
        ]),
        // Just the basics, lightly: rumble out, a little compression, a ceiling.
        ("Natural voice", [
            eq([(1, lowCut, 80, 0, 0.707)]),
            fx("compressor", ["amount": 25]),
            fx("deesser", ["threshold": -28, "range": 6]),
            limiter,
        ]),
    ]

    public static var names: [String] { all.map(\.0) }
    public static func chain(_ name: String) -> [EffectSetting]? { all.first { $0.0 == name }?.1 }
}
