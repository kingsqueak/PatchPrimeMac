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

    public init() {}

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
        return found
    }
}
