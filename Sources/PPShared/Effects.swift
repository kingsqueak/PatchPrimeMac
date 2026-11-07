// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// The built-in effects as the GUI and the helper see them: what each is called and
// what it takes. The list itself comes from the effects code (pp_fx_catalog_json).

import Foundation

public struct EffectParamInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var label: String
    public var unit: String
    public var min: Double
    public var max: Double
    public var initial: Double
    /// "linear", "log" (a frequency, say), "choice" (an index into options) or "toggle".
    public var kind: String
    public var options: [String]

    public init(name: String, label: String, unit: String, min: Double, max: Double, initial: Double,
        kind: String, options: [String]) {
        self.name = name
        self.label = label
        self.unit = unit
        self.min = min
        self.max = max
        self.initial = initial
        self.kind = kind
        self.options = options
    }

    /// A value made valid: clamped, and whole for a choice or toggle.
    public func valid(_ value: Double) -> Double {
        let clamped = Swift.min(max, Swift.max(min, value.isFinite ? value : initial))
        return kind == "choice" || kind == "toggle" ? clamped.rounded() : clamped
    }
}

public struct EffectInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: String { type }
    public var type: String
    public var label: String
    /// Listens to another strip (a ducker). Not wired up yet on the Mac.
    public var key: Bool
    public var params: [EffectParamInfo]

    public init(type: String, label: String, key: Bool, params: [EffectParamInfo]) {
        self.type = type
        self.label = label
        self.key = key
        self.params = params
    }

    public func param(_ name: String) -> EffectParamInfo? { params.first { $0.name == name } }

    /// A new effect of this type, with every parameter at its starting value.
    public func fresh() -> EffectSetting {
        EffectSetting(type: type, params: Dictionary(uniqueKeysWithValues: params.map { ($0.name, $0.initial) }))
    }
}

public enum EffectCatalog {
    public static func decode(_ json: String) -> [EffectInfo] {
        (try? JSONDecoder().decode([EffectInfo].self, from: Data(json.utf8))) ?? []
    }
}
