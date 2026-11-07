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

public struct Strip: Codable, Equatable, Sendable {
    public var slot: Int
    public var label: String
    public var source: Endpoint
    public var gain: Float = 1
    public var muted = false
    public var busSends: [Send] = []
    public var outputSends: [Send] = []

    public init(slot: Int, label: String, source: Endpoint) {
        self.slot = slot
        self.label = label
        self.source = source
    }
}

public struct Bus: Codable, Equatable, Sendable {
    public var slot: Int
    public var label: String
    public var gain: Float = 1
    public var muted = false
    public var outputSends: [Send] = []

    public init(slot: Int, label: String) {
        self.slot = slot
        self.label = label
    }
}

public struct Output: Codable, Equatable, Sendable {
    public var slot: Int
    public var label: String
    public var sink: Endpoint
    public var gain: Float = 1
    public var muted = false

    public init(slot: Int, label: String, sink: Endpoint) {
        self.slot = slot
        self.label = label
        self.sink = sink
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

    public static let rates: [Double] = [44100, 48000, 96000, 192000]
    public static let buffers = [32, 64, 128, 256, 512, 1024]

    public init() {}

    enum CodingKeys: String, CodingKey {
        case version, strips, buses, outputs, hardwareOutputEnabled, hardwareLimit, savedRates,
            clockDevice, sampleRate, bufferFrames, deviceBuffers, keepOwnRate
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
    }

    /// The buffer size to ask of a device.
    public func buffer(for uid: String) -> Int { deviceBuffers[uid] ?? bufferFrames }

    /// A setup that would misbehave is refused, with the reason, rather than stored.
    /// CASTER's M2 tracks lost their channels and went silent with no word why.
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
