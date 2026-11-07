// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// Meter levels in shared memory. The engine writes them; the GUI reads them on its
// own timer. No messages, no JSON, and nothing is left on disk: the name goes when
// the engine stops, and the memory itself goes with the last process using it.

import Darwin
import Foundation
import PPCore

public enum MeterLayout {
    public static let strips = 32
    public static let buses = 16
    public static let outputs = 32
    public static var count: Int { strips + buses + outputs }
    public static func strip(_ slot: Int) -> Int { slot }
    public static func bus(_ slot: Int) -> Int { strips + slot }
    public static func output(_ slot: Int) -> Int { strips + buses + slot }
    static var name: String { "/ppmac.meters.\(getuid())" }
    static var bytes: Int { count * MemoryLayout<Float>.size }
}

/// Peaks as plain floats. A reader may see a value a moment old, which a meter
/// doesn't mind, and a float is written whole on this hardware.
public final class SharedMeters: @unchecked Sendable {
    public let values: UnsafeMutablePointer<Float>

    public init?(create: Bool) {
        let flags = create ? (O_CREAT | O_RDWR) : O_RDONLY
        let fd = MeterLayout.name.withCString { pp_shm_open($0, flags, 0o600) }
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        if create {
            _ = ftruncate(fd, off_t(MeterLayout.bytes)) // fails harmlessly if already sized
        }
        let protection = create ? (PROT_READ | PROT_WRITE) : PROT_READ
        guard let map = mmap(nil, MeterLayout.bytes, protection, MAP_SHARED, fd, 0), map != MAP_FAILED else {
            return nil
        }
        values = map.assumingMemoryBound(to: Float.self)
    }

    public static func removeName() {
        _ = MeterLayout.name.withCString { shm_unlink($0) }
    }
}
