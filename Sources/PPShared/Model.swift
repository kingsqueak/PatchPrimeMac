// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// What a mixer setup is, kept as plain data. Readable JSON on purpose: a person can
// inspect or repair it, and a setting can't hide in a binary blob.

import Foundation

/// Identifies a device across reboots, USB ports and driver changes.
public struct DeviceSignature: Codable, Equatable, Sendable {
    public var uid: String
    public var name: String
    public var transport: String
    /// From the device, or found inside its UID. Empty if it has none.
    public var serial: String

    public init(uid: String, name: String, transport: String, serial: String) {
        self.uid = uid
        self.name = name
        self.transport = transport
        self.serial = serial
    }

    /// Exact UID first. Then the serial, which survived the M2's driver change while
    /// its UID did not. Then name and transport, only if exactly one device fits, for
    /// things with no serial such as built-in speakers, HDMI monitors and Bluetooth.
    public static func match(_ wanted: DeviceSignature, in devices: [DeviceSignature]) -> DeviceSignature? {
        if let exact = devices.first(where: { $0.uid == wanted.uid }) {
            return exact
        }
        if !wanted.serial.isEmpty {
            let sameSerial = devices.filter { $0.serial == wanted.serial }
            if sameSerial.count == 1 {
                return sameSerial[0]
            }
            if !sameSerial.isEmpty {
                return nil
            }
        }
        // Two different known serials mean two different units, however alike.
        let alike = devices.filter {
            $0.name == wanted.name && $0.transport == wanted.transport
                && ($0.serial.isEmpty || wanted.serial.isEmpty)
        }
        return alike.count == 1 ? alike[0] : nil
    }
}

/// Where a strip's audio comes from, or where an output's goes.
public enum Endpoint: Codable, Equatable, Sendable {
    /// Channels are counted from zero. Mono uses the same one twice.
    case device(DeviceSignature, left: Int, right: Int)
    /// A named virtual device, by driver slot.
    case virtual(slot: Int)
}

public struct Send: Codable, Equatable, Sendable {
    public var to: Int
    public var gain: Float

    public init(to: Int, gain: Float) {
        self.to = to
        self.gain = gain
    }
}

/// One built-in effect in a chain: Patch Prime's names and parameters.
public struct EffectSetting: Codable, Equatable, Sendable {
    public var type: String
    public var enabled = true
    public var params: [String: Double] = [:]
    /// For a ducker: the input strip it listens to (by slot), or none.
    public var key: Int?
    /// For a plugin (type "au:..."): its name to show, the version of it in use ("m", "s",
    /// "m->s", or "" for one with no versions), and its own state (a binary property list,
    /// base64), restored when it loads.
    public var plugin: String?
    public var channels: String?
    public var state: String?

    public init(type: String, enabled: Bool = true, params: [String: Double] = [:], key: Int? = nil) {
        self.type = type
        self.enabled = enabled
        self.params = params
        self.key = key
    }

    public var isPlugin: Bool { type.hasPrefix("au:") || type.hasPrefix("vst3:") || type.hasPrefix("clap:") }

    /// The line the engine reads (see pp_fx_set): type, on, name=value pairs.
    var specLine: String {
        let pairs = params.keys.sorted().map { "\($0)=\(params[$0]!)" }.joined(separator: ";")
        return "\(type)\t\(enabled ? 1 : 0)\t\(pairs)"
    }
}

public extension Array where Element == EffectSetting {
    var spec: String { map(\.specLine).joined(separator: "\n") }

    /// The strip the chain's ducker listens to: the first ducker's, as the engine has
    /// one key per chain.
    var key: Int? { first { $0.type == "ducker" && $0.key != nil }?.key }

    /// The spec with the chain's own switch applied: off bypasses every effect (with
    /// the usual crossfade) and keeps the chain, so switching back is seamless.
    func spec(on: Bool) -> String {
        on ? spec : map { var e = $0; e.enabled = false; return e.specLine }.joined(separator: "\n")
    }
}

/// Effects one strip, bus or output may have, as on Linux.
public let maxEffects = 8

public struct Strip: Codable, Equatable, Sendable {
    public var slot: Int
    public var label: String
    public var source: Endpoint
    public var gain: Float = 1
    public var muted = false
    public var busSends: [Send] = []
    public var outputSends: [Send] = []
    /// Before the fader, so apps recording a bus get the processed sound.
    public var effects: [EffectSetting] = []
    /// Every effect on or bypassed at once, keeping each one's own switch.
    public var effectsOn = true

    public init(slot: Int, label: String, source: Endpoint) {
        self.slot = slot
        self.label = label
        self.source = source
    }

    enum CodingKeys: String, CodingKey { case slot, label, source, gain, muted, busSends, outputSends, effects, effectsOn }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slot = try c.decode(Int.self, forKey: .slot)
        label = try c.decode(String.self, forKey: .label)
        source = try c.decode(Endpoint.self, forKey: .source)
        gain = try c.decodeIfPresent(Float.self, forKey: .gain) ?? 1
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        busSends = try c.decodeIfPresent([Send].self, forKey: .busSends) ?? []
        outputSends = try c.decodeIfPresent([Send].self, forKey: .outputSends) ?? []
        effects = try c.decodeIfPresent([EffectSetting].self, forKey: .effects) ?? []
        effectsOn = try c.decodeIfPresent(Bool.self, forKey: .effectsOn) ?? true
    }
}

public struct Bus: Codable, Equatable, Sendable {
    public var slot: Int
    public var label: String
    public var gain: Float = 1
    public var muted = false
    public var outputSends: [Send] = []
    /// After the fader.
    public var effects: [EffectSetting] = []
    /// Every effect on or bypassed at once, keeping each one's own switch.
    public var effectsOn = true

    public init(slot: Int, label: String) {
        self.slot = slot
        self.label = label
    }

    enum CodingKeys: String, CodingKey { case slot, label, gain, muted, outputSends, effects, effectsOn }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slot = try c.decode(Int.self, forKey: .slot)
        label = try c.decode(String.self, forKey: .label)
        gain = try c.decodeIfPresent(Float.self, forKey: .gain) ?? 1
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        outputSends = try c.decodeIfPresent([Send].self, forKey: .outputSends) ?? []
        effects = try c.decodeIfPresent([EffectSetting].self, forKey: .effects) ?? []
        effectsOn = try c.decodeIfPresent(Bool.self, forKey: .effectsOn) ?? true
    }
}

public struct Output: Codable, Equatable, Sendable {
    public var slot: Int
    public var label: String
    public var sink: Endpoint
    public var gain: Float = 1
    public var muted = false
    /// After the fader (a limiter, say).
    public var effects: [EffectSetting] = []
    /// Every effect on or bypassed at once, keeping each one's own switch.
    public var effectsOn = true

    public init(slot: Int, label: String, sink: Endpoint) {
        self.slot = slot
        self.label = label
        self.sink = sink
    }

    enum CodingKeys: String, CodingKey { case slot, label, sink, gain, muted, effects, effectsOn }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slot = try c.decode(Int.self, forKey: .slot)
        label = try c.decode(String.self, forKey: .label)
        sink = try c.decode(Endpoint.self, forKey: .sink)
        gain = try c.decodeIfPresent(Float.self, forKey: .gain) ?? 1
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        effects = try c.decodeIfPresent([EffectSetting].self, forKey: .effects) ?? []
        effectsOn = try c.decodeIfPresent(Bool.self, forKey: .effectsOn) ?? true
    }
}

public struct Settings: Codable, Equatable, Sendable {
    public var version = 1
    public var strips: [Strip] = []
    public var buses: [Bus] = []
    public var outputs: [Output] = []
    /// Off until someone turns it on. A new install can't reach an amplifier.
    public var hardwareOutputEnabled = false
    /// The highest level allowed at any hardware output, linear.
    public var hardwareLimit: Float = 0.5
    /// Last known rate for each device, by UID, so a device locks within seconds.
    public var savedRates: [String: Double] = [:]
    /// The device whose clock to follow. None means the Patch Prime clock.
    public var clockDevice: DeviceSignature?
    /// The engine's rate, which the virtual devices share, and its block size.
    /// Hardware follows both unless one of the two settings below says otherwise.
    public var sampleRate: Double = 48000
    public var bufferFrames = 128
    /// A device's own buffer size, by UID, instead of bufferFrames.
    public var deviceBuffers: [String: Int] = [:]
    /// Devices left at their own rate and resampled, by UID. A device that can't do
    /// the engine's rate is resampled anyway.
    public var keepOwnRate: Set<String> = []
    /// The scene last loaded or saved, to show which is in use.
    public var lastScene: String?
    /// Cue (solo in the headphones): the output it plays to (none: cue is off), its
    /// level, and before the fader (PFL) or after it (AFL). What's cued isn't saved.
    public var cueOutput: Int?
    public var cueLevelDb: Double = 0
    public var cuePreFader = true
    /// What the plugin browser and the scan leave out.
    public var pluginFilter = PluginFilter()

    public static let rates: [Double] = [44100, 48000, 96000, 192000]
    public static let buffers = [32, 64, 128, 256, 512, 1024]

    public init() {}

    enum CodingKeys: String, CodingKey {
        case version, strips, buses, outputs, hardwareOutputEnabled, hardwareLimit, savedRates,
            clockDevice, sampleRate, bufferFrames, deviceBuffers, keepOwnRate, lastScene,
            cueOutput, cueLevelDb, cuePreFader, pluginFilter
    }

    // By hand, so a settings file from an older version loads with defaults for what
    // it doesn't have, instead of being set aside as unreadable.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? d.version
        strips = try c.decodeIfPresent([Strip].self, forKey: .strips) ?? d.strips
        buses = try c.decodeIfPresent([Bus].self, forKey: .buses) ?? d.buses
        outputs = try c.decodeIfPresent([Output].self, forKey: .outputs) ?? d.outputs
        hardwareOutputEnabled = try c.decodeIfPresent(Bool.self, forKey: .hardwareOutputEnabled) ?? d.hardwareOutputEnabled
        hardwareLimit = try c.decodeIfPresent(Float.self, forKey: .hardwareLimit) ?? d.hardwareLimit
        savedRates = try c.decodeIfPresent([String: Double].self, forKey: .savedRates) ?? d.savedRates
        clockDevice = try c.decodeIfPresent(DeviceSignature.self, forKey: .clockDevice)
        sampleRate = try c.decodeIfPresent(Double.self, forKey: .sampleRate) ?? d.sampleRate
        bufferFrames = try c.decodeIfPresent(Int.self, forKey: .bufferFrames) ?? d.bufferFrames
        deviceBuffers = try c.decodeIfPresent([String: Int].self, forKey: .deviceBuffers) ?? d.deviceBuffers
        keepOwnRate = try c.decodeIfPresent(Set<String>.self, forKey: .keepOwnRate) ?? d.keepOwnRate
        lastScene = try c.decodeIfPresent(String.self, forKey: .lastScene)
        cueOutput = try c.decodeIfPresent(Int.self, forKey: .cueOutput)
        cueLevelDb = try c.decodeIfPresent(Double.self, forKey: .cueLevelDb) ?? d.cueLevelDb
        cuePreFader = try c.decodeIfPresent(Bool.self, forKey: .cuePreFader) ?? d.cuePreFader
        pluginFilter = try c.decodeIfPresent(PluginFilter.self, forKey: .pluginFilter) ?? d.pluginFilter
    }

    /// The buffer size to ask of a device.
    public func buffer(for uid: String) -> Int { deviceBuffers[uid] ?? bufferFrames }

    /// A setup that would misbehave is refused, with the reason, rather than stored.
    /// (A strip that silently lost its channel would just go quiet with no word why.)
    public func problems() -> [String] {
        var found: [String] = []
        func endpoint(_ e: Endpoint, _ what: String) {
            switch e {
            case let .device(_, left, right):
                if left < 0 || right < 0 {
                    found.append("\(what) has no channel chosen")
                }
            case let .virtual(slot):
                if slot < 0 || slot >= 16 {
                    found.append("\(what) uses virtual slot \(slot), which doesn't exist")
                }
            }
        }
        for s in strips {
            endpoint(s.source, "strip \"\(s.label)\"")
            for send in s.busSends where !buses.contains(where: { $0.slot == send.to }) {
                found.append("strip \"\(s.label)\" sends to a bus that doesn't exist")
            }
            for send in s.outputSends where !outputs.contains(where: { $0.slot == send.to }) {
                found.append("strip \"\(s.label)\" sends to an output that doesn't exist")
            }
        }
        for b in buses {
            for send in b.outputSends where !outputs.contains(where: { $0.slot == send.to }) {
                found.append("bus \"\(b.label)\" sends to an output that doesn't exist")
            }
        }
        for o in outputs {
            endpoint(o.sink, "output \"\(o.label)\"")
        }
        for (what, effects) in strips.map({ ("strip \"\($0.label)\"", $0.effects) })
            + buses.map({ ("bus \"\($0.label)\"", $0.effects) }) + outputs.map({ ("output \"\($0.label)\"", $0.effects) })
        where effects.count > maxEffects {
            found.append("\(what) has \(effects.count) effects; the most is \(maxEffects)")
        }
        // Keys: a strip that exists, not the strip itself, and no circles between strips.
        let stripSlots = Set(strips.map(\.slot))
        for (what, effects, own) in strips.map({ ("strip \"\($0.label)\"", $0.effects, Optional($0.slot)) })
            + buses.map({ ("bus \"\($0.label)\"", $0.effects, Int?.none) })
            + outputs.map({ ("output \"\($0.label)\"", $0.effects, Int?.none) }) {
            for e in effects {
                guard let key = e.key else { continue }
                if !stripSlots.contains(key) {
                    found.append("\(what) has a ducker listening to a strip that doesn't exist")
                } else if key == own {
                    found.append("\(what) has a ducker listening to itself")
                }
            }
        }
        for strip in strips {
            var seen: Set<Int> = [strip.slot]
            var at = strip.effects.key
            while let next = at, stripSlots.contains(next) {
                if seen.contains(next) {
                    found.append("strip \"\(strip.label)\" ducks under a strip that ducks under it: a loop")
                    break
                }
                seen.insert(next)
                at = strips.first { $0.slot == next }?.effects.key
            }
        }
        if let cue = cueOutput, !outputs.contains(where: { $0.slot == cue }) {
            found.append("cue plays to an output that doesn't exist")
        }
        if !Settings.rates.contains(sampleRate) {
            found.append("sample rate \(sampleRate) isn't one of 44100, 48000, 96000 or 192000")
        }
        if !Settings.buffers.contains(bufferFrames) {
            found.append("buffer size \(bufferFrames) isn't one of 32, 64, 128, 256, 512 or 1024")
        }
        for (uid, frames) in deviceBuffers where !Settings.buffers.contains(frames) {
            found.append("buffer size \(frames) for \(uid) isn't one of 32, 64, 128, 256, 512 or 1024")
        }
        return found
    }
}
