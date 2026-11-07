// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// The plugins on this Mac, whatever their format. Audio Units for now; VST3, CLAP and
// LV2 fit the same model later. Listing is quick and loads nothing (the system keeps
// the registry); checking that a plugin really works is a scan the user starts, and
// its results are cached by plugin and version.

import AVFoundation
import Foundation

public enum PluginFormat: String, Codable, Sendable, CaseIterable {
    case au = "AU", vst3 = "VST3", clap = "CLAP", lv2 = "LV2"
}

public enum PluginKind: String, Codable, Sendable, CaseIterable {
    case effect, musicEffect, instrument, generator, midi, other

    public var label: String {
        switch self {
        case .effect: return "Effects"
        case .musicEffect: return "Music effects (take MIDI)"
        case .instrument: return "Instruments"
        case .generator: return "Generators"
        case .midi: return "MIDI processors"
        case .other: return "Other"
        }
    }
}

/// One way of running a plugin: Waves ship each as mono "(m)", stereo "(s)" and mono in,
/// stereo out "(m->s)"; most plugins have one.
public struct PluginVariant: Codable, Sendable, Hashable {
    /// What loads it: for an AU, "au:<type>:<subtype>:<maker>" as four-letter codes.
    public var id: String
    /// "m", "s", "m->s", or "" for a plugin with one way.
    public var channels: String
    public var name: String

    public init(id: String, channels: String, name: String) {
        self.id = id
        self.channels = channels
        self.name = name
    }

    /// Channels in and out: "m" 1/1, "s" 2/2, "m->s" 1/2, "5->2" 5/2; none said, stereo.
    public var inputs: Int { counts.0 }
    public var outputs: Int { counts.1 }

    var counts: (Int, Int) {
        func n(_ s: Substring) -> Int { s == "m" ? 1 : s == "s" ? 2 : Int(s) ?? 2 }
        if channels.isEmpty { return (2, 2) }
        let parts = channels.split(separator: "-", maxSplits: 1)
        if parts.count == 2, parts[1].hasPrefix(">") { return (n(parts[0]), n(parts[1].dropFirst())) }
        return (n(Substring(channels)), n(Substring(channels)))
    }

    /// Fits a mono or stereo strip: one or two channels in, one or two out.
    public var fitsStrips: Bool { (1...2).contains(inputs) && (1...2).contains(outputs) }
}

public struct PluginEntry: Codable, Sendable, Hashable, Identifiable {
    /// The plugin as one thing, across its variants: format, maker and name.
    public var id: String { "\(format.rawValue):\(maker):\(name)" }
    public var format: PluginFormat
    public var maker: String
    public var name: String
    public var version: String
    public var kind: PluginKind
    /// Categories from the plugin's own metadata, and the user's own tags.
    public var categories: [String]
    public var variants: [PluginVariant]
    /// Not asked when listing: the system loads the plugin to answer. The scan finds out
    /// (PluginCheck.hasView).
    public var hasCustomView: Bool

    public init(format: PluginFormat, maker: String, name: String, version: String, kind: PluginKind,
        categories: [String], variants: [PluginVariant], hasCustomView: Bool = false) {
        self.format = format
        self.maker = maker
        self.name = name
        self.version = version
        self.kind = kind
        self.categories = categories
        self.variants = variants
        self.hasCustomView = hasCustomView
    }

    /// The variant for a strip with this many channels: the same in and out if there is
    /// one, then mono into stereo, then whatever fits.
    public func variant(channels: Int) -> PluginVariant? {
        let fit = variants.filter(\.fitsStrips)
        return fit.first { $0.inputs == channels && $0.outputs == channels }
            ?? fit.first { $0.inputs == channels }
            ?? fit.first { $0.outputs == channels }
            ?? fit.first
    }

    /// Whether any variant fits a strip (not only surround versions).
    public var fitsStrips: Bool { variants.contains(where: \.fitsStrips) }
}

/// What the user has hidden from the browser and the scan.
public struct PluginFilter: Codable, Sendable, Equatable {
    public var hiddenKinds: Set<PluginKind> = [.instrument, .generator, .midi, .other]
    public var hiddenMakers: Set<String> = []
    public var hiddenCategories: Set<String> = []
    public var hiddenPlugins: Set<String> = [] // PluginEntry.id

    public init() {}

    enum CodingKeys: String, CodingKey { case hiddenKinds, hiddenMakers, hiddenCategories, hiddenPlugins }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PluginFilter()
        hiddenKinds = try c.decodeIfPresent(Set<PluginKind>.self, forKey: .hiddenKinds) ?? d.hiddenKinds
        hiddenMakers = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenMakers) ?? []
        hiddenCategories = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenCategories) ?? []
        hiddenPlugins = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenPlugins) ?? []
    }

    public func shows(_ p: PluginEntry) -> Bool {
        !hiddenKinds.contains(p.kind) && !hiddenMakers.contains(p.maker) && !hiddenPlugins.contains(p.id)
            && (p.categories.isEmpty || !p.categories.allSatisfy { hiddenCategories.contains($0) })
    }
}

/// What a scan found out about one plugin variant.
public struct PluginCheck: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case ok, failed, timedOut, crashed }
    public var status: Status
    public var message: String = ""
    public var version: String
    public var inputs: Int = 0
    public var outputs: Int = 0
    public var latencySeconds: Double = 0
    public var tailSeconds: Double = 0
    public var parameters: Int = 0
    public var hasView = false
    public var seconds: Double = 0 // how long the check took
    public var checked: Date = Date()

    public init(status: Status, version: String, message: String = "") {
        self.status = status
        self.version = version
        self.message = message
    }
}

/// Scan results by variant id. A result for an older version doesn't count.
public struct PluginCache: Codable, Sendable, Equatable {
    public var checks: [String: PluginCheck] = [:]

    public init() {}

    public func check(_ variant: PluginVariant, version: String) -> PluginCheck? {
        guard let c = checks[variant.id], c.version == version else { return nil }
        return c
    }

    /// The plugin's state overall: failed if any variant failed, ok if all are ok, nil
    /// if any hasn't been checked (at this version).
    public func status(_ p: PluginEntry) -> PluginCheck.Status? {
        let found = p.variants.filter(\.fitsStrips).map { check($0, version: p.version)?.status }
        if found.contains(where: { $0 != nil && $0 != .ok }) { return found.compactMap { $0 }.first { $0 != .ok } }
        return found.contains(nil) ? nil : .ok
    }

    public static func load(from url: URL) -> PluginCache {
        guard let data = try? Data(contentsOf: url) else { return PluginCache() }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? d.decode(PluginCache.self, from: data)) ?? PluginCache()
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        try e.encode(self).write(to: url, options: .atomic)
    }

    public static var defaultURL: URL { Store.defaultFolder.appendingPathComponent("plugin-cache.json") }
}

// MARK: Audio Units

public enum AudioUnitCatalog {
    static func fourCC(_ v: OSType) -> String {
        let bytes = [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
        return String(bytes: bytes, encoding: .macOSRoman) ?? String(format: "%08x", v)
    }

    static func code(_ s: Substring) -> OSType? {
        let bytes = Array(s.data(using: .macOSRoman) ?? Data())
        guard bytes.count == 4 else { return nil }
        return bytes.reduce(0) { $0 << 8 | OSType($1) }
    }

    public static func id(_ d: AudioComponentDescription) -> String {
        "au:\(fourCC(d.componentType)):\(fourCC(d.componentSubType)):\(fourCC(d.componentManufacturer))"
    }

    public static func description(_ id: String) -> AudioComponentDescription? {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "au", let t = code(parts[1]), let s = code(parts[2]), let m = code(parts[3])
        else { return nil }
        return AudioComponentDescription(componentType: t, componentSubType: s, componentManufacturer: m,
            componentFlags: 0, componentFlagsMask: 0)
    }

    static func kind(_ type: OSType) -> PluginKind {
        switch type {
        case kAudioUnitType_Effect: return .effect
        case kAudioUnitType_MusicEffect: return .musicEffect
        case kAudioUnitType_MusicDevice: return .instrument
        case kAudioUnitType_Generator: return .generator
        case kAudioUnitType_MIDIProcessor: return .midi
        default: return .other
        }
    }

    /// "C1 comp (m)" is "C1 comp", mono; "NX (5->2)" is "NX", 5 in and 2 out. Waves'
    /// way of naming; anything else has one variant.
    public static func split(_ name: String) -> (base: String, channels: String) {
        guard name.hasSuffix(")"), let open = name.range(of: " (", options: .backwards) else { return (name, "") }
        let inside = String(name[open.upperBound..<name.index(before: name.endIndex)])
        let word = "^(m|s|[0-9]+)(->(m|s|[0-9]+))?$"
        guard inside.range(of: word, options: .regularExpression) != nil else { return (name, "") }
        return (String(name[..<open.lowerBound]), inside)
    }

    /// Every Audio Unit of these kinds, from the system's registry: nothing is loaded.
    public static func list(kinds: Set<PluginKind> = Set(PluginKind.allCases)) -> [PluginEntry] {
        let components = AVAudioUnitComponentManager.shared().components(passingTest: { c, _ in
            kinds.contains(kind(c.audioComponentDescription.componentType))
        })
        var grouped: [String: PluginEntry] = [:]
        var order: [String] = []
        for c in components {
            let (base, channels) = split(c.name)
            let k = kind(c.audioComponentDescription.componentType)
            let key = "\(c.manufacturerName):\(base):\(k.rawValue)"
            let variant = PluginVariant(id: id(c.audioComponentDescription), channels: channels, name: c.name)
            if var entry = grouped[key] {
                entry.variants.append(variant)
                entry.categories = Array(Set(entry.categories).union(c.allTagNames.filter { $0 != "Effects" && $0 != "Effect" })).sorted()
                grouped[key] = entry
            } else {
                order.append(key)
                grouped[key] = PluginEntry(format: .au, maker: c.manufacturerName, name: base,
                    version: c.versionString, kind: k,
                    categories: c.allTagNames.filter { $0 != "Effects" && $0 != "Effect" }.sorted(),
                    variants: [variant])
            }
        }
        return order.compactMap { grouped[$0] }.sorted {
            ($0.maker.lowercased(), $0.name.lowercased()) < ($1.maker.lowercased(), $1.name.lowercased())
        }
    }
}
