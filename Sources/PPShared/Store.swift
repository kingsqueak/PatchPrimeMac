// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// Saves settings so a crash or a bad save can't lose them. CASTER's autosave once
// wrote a broken session over a good one. Here a save goes to a temporary file and
// is renamed into place, the last few versions are kept, and a file that can't be
// read is set aside rather than overwritten, with the newest good backup loaded.

import Foundation

public struct Store: Sendable {
    public let folder: URL
    public var keep = 5

    public init(folder: URL) {
        self.folder = folder
    }

    public static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PatchPrimeMac")
    }

    var file: URL { folder.appendingPathComponent("settings.json") }
    func backup(_ n: Int) -> URL { folder.appendingPathComponent("settings.\(n).json") }

    public func save(_ settings: Settings) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        if let current = try? Data(contentsOf: file), current == data {
            return
        }
        let manager = FileManager.default
        if manager.fileExists(atPath: file.path), (try? read(file)) != nil {
            try? manager.removeItem(at: backup(keep))
            if keep > 1 {
                for n in stride(from: keep - 1, through: 1, by: -1)
                where manager.fileExists(atPath: backup(n).path) {
                    try manager.moveItem(at: backup(n), to: backup(n + 1))
                }
            }
            try manager.copyItem(at: file, to: backup(1))
        }
        try data.write(to: file, options: .atomic)
    }

    func read(_ url: URL) throws -> Settings {
        try JSONDecoder().decode(Settings.self, from: Data(contentsOf: url))
    }

    /// The settings, and a note if something had to be recovered.
    public func load() -> (settings: Settings, note: String?) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: file.path) else {
            return (Settings(), nil)
        }
        if let good = try? read(file) {
            return (good, nil)
        }
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = folder.appendingPathComponent("settings.unreadable-\(stamp).json")
        try? manager.moveItem(at: file, to: aside)
        for n in 1...keep {
            if let good = try? read(backup(n)) {
                return (good, "settings.json couldn't be read, so it was kept as \(aside.lastPathComponent) and backup \(n) was loaded")
            }
        }
        return (Settings(), "settings.json couldn't be read and no backup worked. It was kept as \(aside.lastPathComponent)")
    }
}
