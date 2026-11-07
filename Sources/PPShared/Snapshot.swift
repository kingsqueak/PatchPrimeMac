// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// Everything the GUI shows, sent as one piece.

import Foundation

public struct DeviceRow: Codable, Sendable, Identifiable, Hashable {
    public var id: String { uid }
    public var uid: String
    public var name: String
    public var transport: String
    public var inputs: Int
    public var outputs: Int
    /// Its rate now, and which of PatchPrimeMac's rates it can run at.
    public var rate: Double = 0
    public var rates: [Double] = []
    /// The buffer sizes it allows, and the one the engine is using (0 if not open).
    public var bufferMin = 0
    public var bufferMax = 0
    public var buffer = 0

    public init(uid: String, name: String, transport: String, inputs: Int, outputs: Int) {
        self.uid = uid
        self.name = name
        self.transport = transport
        self.inputs = inputs
        self.outputs = outputs
    }
}

public struct VirtualRow: Codable, Sendable, Identifiable, Hashable {
    public var id: Int { slot }
    public var slot: Int
    public var isOutput: Bool
    public var name: String

    public init(slot: Int, isOutput: Bool, name: String) {
        self.slot = slot
        self.isOutput = isOutput
        self.name = name
    }
}

public struct Snapshot: Codable, Sendable, Equatable {
    public var running = false
    public var note: String?
    public var settings = Settings()
    public var devices: [DeviceRow] = []
    public var virtuals: [VirtualRow] = []
    public var offline: [String] = []
    /// Strips with a working route that are delivering exact zeros, which real inputs
    /// never do: permission refused, or a channel with nothing on it.
    public var silent: [String] = []
    public var defaultOutput = ""
    public var defaultInput = ""
    public var clockText = "Patch Prime"
    public var underruns: UInt64 = 0
    public var overruns: UInt64 = 0
    public var relocks: UInt64 = 0
    /// The engine's rate and block as running, which can differ from the settings
    /// for a moment while it restarts.
    public var engineRate: Double = 0
    public var engineBlock = 0
    /// Preset names: the user's chains, the built-in ones, and single effects by type.
    public var chainPresets: [String] = []
    public var builtInChains: [String] = []
    public var effectPresets: [String: [String]] = [:]

    public init() {}
}
