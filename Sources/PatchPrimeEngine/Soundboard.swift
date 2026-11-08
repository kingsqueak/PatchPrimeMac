// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// The soundboard: pads that play sound files into one strip (a mix bus, say). Pressing
// a pad plays it from the start; pressing it again while it plays stops it. Pads can
// overlap: each playing one is a Player of its own, in a feed slot of its own (1 to
// 16; the recordings player has slot 0). The first time, the built-in sounds (in the
// engine's bundle) are copied to ~/Music/PatchPrimeMac/Soundboard and put on pads.

import Foundation
import PPCore
import PPShared

/// The built-in sounds, in the order they go on the board, by section.
enum BuiltInSounds {
    static let pads: [(group: String, names: [String])] = [
        ("Crowd", ["Applause", "Applause (Small)", "Cheer", "Hurray", "Ooh Ahh", "Laughter"]),
        ("Comedy", ["Ba-Dum-Tss", "Sad Trombone", "Drum Roll"]),
        ("Horns and Sirens", ["Air Horn", "Train Horn", "Siren Wail", "Siren Yelp", "Toy Siren"]),
        ("Drums", ["Kick", "Snare", "Clap", "Hi-Hat", "Crash"]),
    ]

    static var bundled: URL? { Bundle.main.resourceURL?.appendingPathComponent("Sounds", isDirectory: true) }
    static var folder: URL { RecordingFiles.folder.appendingPathComponent("Soundboard", isDirectory: true) }
}

extension Engine {
    func newPadID() -> String { String(UUID().uuidString.prefix(8)).lowercased() }

    /// Puts the built-in sounds missing from the board on it (copying them to the
    /// soundboard folder first). The first time, that's all of them.
    @discardableResult
    func addBuiltInPads(_ next: inout Settings) -> Int {
        guard let bundled = BuiltInSounds.bundled else { return 0 }
        let fm = FileManager.default
        try? fm.createDirectory(at: BuiltInSounds.folder, withIntermediateDirectories: true)
        var added = 0
        for (group, names) in BuiltInSounds.pads {
            for name in names {
                let source = bundled.appendingPathComponent(name + ".wav")
                let dest = BuiltInSounds.folder.appendingPathComponent(name + ".wav")
                guard fm.fileExists(atPath: source.path) else { continue }
                if !fm.fileExists(atPath: dest.path) { try? fm.copyItem(at: source, to: dest) }
                guard !next.pads.contains(where: { $0.path == dest.path }) else { continue }
                next.pads.append(SoundPad(id: newPadID(), label: name, path: dest.path, group: group))
                added += 1
            }
        }
        return added
    }

    /// The first start with no pads: the built-in ones.
    func seedPads() {
        guard !settings.padsSeeded else { return }
        var next = settings
        addBuiltInPads(&next)
        next.padsSeeded = true
        _ = commit(next, "soundboard ready")
    }

    /// Where the pads play: the chosen strip, bus or output, or the first bus (or output).
    func padsTarget() -> String? {
        if !settings.padsInto.isEmpty, label(of: settings.padsInto) != nil { return settings.padsInto }
        if let bus = settings.buses.first { return "b\(bus.slot)" }
        return settings.outputs.first.map { "o\($0.slot)" }
    }

    static func gain(_ db: Double) -> Float { Float(pow(10, min(12, max(-60, db)) / 20)) }

    /// Plays the pad, or stops it if it's playing.
    func triggerPad(_ id: String) -> Reply {
        guard let pad = settings.pads.first(where: { $0.id == id || $0.label.caseInsensitiveCompare(id) == .orderedSame }) else {
            return Reply(ok: false, text: "no pad \"\(id)\"")
        }
        if padPlayers[pad.id] != nil {
            stopPad(pad.id)
            return Reply(ok: true, text: "stopped \(pad.label)")
        }
        guard let core, let mixer = pp_engine_mixer(core), engineRate > 0 else {
            return Reply(ok: false, text: "the engine isn't running")
        }
        guard let target = padsTarget(), let (kind, slot) = chainAddress(target) else {
            return Reply(ok: false, text: "there's nothing to play into: add a mix bus or an output")
        }
        let used = Set(padPlayers.values.map(\.slot))
        guard let feedSlot = (1..<Int(PP_MAX_FEEDS)).first(where: { !used.contains($0) }) else {
            return Reply(ok: false, text: "\(maxPadsPlaying) pads are playing already")
        }
        let (opened, problem) = Player.open(URL(fileURLWithPath: pad.path), rate: engineRate)
        guard let opened else { return Reply(ok: false, text: problem ?? "couldn't play \(pad.label)") }
        pp_feed_set_gain(opened.feed, Self.gain(pad.gainDb))
        opened.start(looping: pad.loop)
        padPlayers[pad.id] = (opened, feedSlot)
        pp_mixer_set_feed(mixer, Int32(feedSlot), opened.feed, kind, Int32(slot))
        return Reply(ok: true, text: "playing \(pad.label)")
    }

    func stopPad(_ id: String) {
        guard let (player, feedSlot) = padPlayers.removeValue(forKey: id) else { return }
        if let core, let mixer = pp_engine_mixer(core) { pp_mixer_set_feed(mixer, Int32(feedSlot), nil, 0, 0) }
        player.stop() // its thread frees the feed when it's done
    }

    func stopAllPads() {
        for id in Array(padPlayers.keys) { stopPad(id) }
    }

    /// Pads that played to the end are done; the others follow the board's strip.
    func tidyPads() {
        for (id, entry) in padPlayers where entry.player.finished { stopPad(id) }
        guard !padPlayers.isEmpty, let core, let mixer = pp_engine_mixer(core) else { return }
        guard let target = padsTarget(), let (kind, slot) = chainAddress(target) else { stopAllPads(); return }
        for (_, entry) in padPlayers { pp_mixer_set_feed(mixer, Int32(entry.slot), entry.player.feed, kind, Int32(slot)) }
    }

    /// The soundboard's commands; nil when it isn't one.
    func handlePads(_ verb: String, _ a: [String], _ next: inout Settings) -> Reply? {
        switch verb {
        case "pad" where !a.isEmpty:
            return triggerPad(a.joined(separator: " "))
        case "pad-stop-all":
            stopAllPads()
            return Reply(ok: true, text: "stopped")
        case "pad-add" where !a.isEmpty:
            let path = a.joined(separator: " ")
            let url = URL(fileURLWithPath: path)
            guard Player.canPlay(url) else {
                return Reply(ok: false, text: "\(url.lastPathComponent) isn't a sound file macOS can play")
            }
            next.pads.append(SoundPad(id: newPadID(), label: url.deletingPathExtension().lastPathComponent, path: path))
            return commit(next, "added")
        case "pad-builtin":
            let added = addBuiltInPads(&next)
            return commit(next, added == 0 ? "they're all there" : "added \(added)")
        case "pad-remove" where a.count == 1:
            stopPad(a[0])
            next.pads.removeAll { $0.id == a[0] }
            return commit(next, "removed")
        case "pad-set" where a.count >= 3:
            // pad-set <id> label <text> | gain <dB> | loop on|off
            guard let i = next.pads.firstIndex(where: { $0.id == a[0] }) else { return Reply(ok: false, text: "no pad \(a[0])") }
            switch a[1] {
            case "label": next.pads[i].label = a[2...].joined(separator: " ")
            case "gain":
                guard let db = Double(a[2]) else { return Reply(ok: false, text: "pad-set <id> gain <dB>") }
                next.pads[i].gainDb = min(12, max(-60, db))
                if let entry = padPlayers[a[0]] { pp_feed_set_gain(entry.player.feed, Self.gain(next.pads[i].gainDb)) }
            case "loop":
                next.pads[i].loop = a[2] == "on"
                padPlayers[a[0]]?.player.setLooping(next.pads[i].loop)
            default: return Reply(ok: false, text: "pad-set <id> label|gain|loop <value>")
            }
            return commit(next, "done")
        case "pad-move" where a.count == 2:
            guard let i = next.pads.firstIndex(where: { $0.id == a[0] }), let steps = Int(a[1]) else { break }
            let to = min(max(i + steps, 0), next.pads.count - 1)
            next.pads.insert(next.pads.remove(at: i), at: to)
            return commit(next, "done")
        case "pads-into" where a.count == 2:
            let prefix = ["strip": "s", "bus": "b", "out": "o"][a[0]] ?? ""
            guard !prefix.isEmpty, let slot = Int(a[1]), label(of: prefix + "\(slot)") != nil else {
                return Reply(ok: false, text: "pads-into strip|bus|out <n>")
            }
            next.padsInto = prefix + "\(slot)"
            let reply = commit(next, "done")
            tidyPads()
            return reply
        case "pads":
            let lines = settings.pads.map { "\($0.id)  \($0.label)\($0.loop ? " (loops)" : "")\($0.gainDb != 0 ? String(format: " %+.1f dB", $0.gainDb) : "")" }
            return Reply(ok: true, text: lines.isEmpty ? "no pads" : lines.joined(separator: "\n"))
        default:
            return nil
        }
        return nil
    }
}
