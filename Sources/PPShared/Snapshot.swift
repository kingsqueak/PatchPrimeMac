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
    public var stripPeaks: [Int: Float] = [:]
    public var busPeaks: [Int: Float] = [:]
    public var outputPeaks: [Int: Float] = [:]
    public var underruns: UInt64 = 0
    public var overruns: UInt64 = 0
    public var relocks: UInt64 = 0

    public init() {}
}
