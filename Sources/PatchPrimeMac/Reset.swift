// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// Reset: getting the sound back when the engine has stopped or stuck (after the Mac
// slept, say) without restarting the Mac.
// 1. The engine is restarted by launchd (`launchctl kickstart -k`): no password, and
//    everything comes back from the saved settings.
// 2. If the audio still isn't running after that, macOS's audio system (coreaudiod) can
//    be restarted too. That needs an administrator's password, which macOS asks for
//    itself, and stops all sound on the Mac for a moment.

import AppKit
import SwiftUI

@MainActor
final class ResetController: ObservableObject {
    static let shared = ResetController()
    @Published private(set) var busy = false

    /// Restarts the engine; offers to restart macOS's audio if that isn't enough.
    func reset(_ model: Model) {
        guard !busy else { return }
        busy = true
        Task {
            await Self.restartEngine()
            if await Self.cameBack(model) {
                busy = false
                return
            }
            busy = false
            let alert = NSAlert()
            alert.messageText = "The audio still isn't running"
            alert.informativeText = "The engine was restarted, but the sound hasn't come back. Restarting macOS's audio system usually fixes that (it's what restarting the Mac does).\n\nAll sound on the Mac stops for a moment, so turn loud speakers or amplifiers down first. macOS asks for an administrator's password."
            alert.addButton(withTitle: "Restart macOS Audio")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            busy = true
            guard Self.restartCoreAudio() else { busy = false; return } // cancelled, or refused
            try? await Task.sleep(for: .seconds(3))
            await Self.restartEngine()
            let back = await Self.cameBack(model)
            busy = false
            if !back {
                let failed = NSAlert()
                failed.messageText = "The audio still isn't running"
                failed.informativeText = "Restart the Mac to start everything afresh. If this keeps happening, please report it in the project's Issues on GitHub."
                failed.runModal()
            }
        }
    }

    /// launchd stops the engine and starts it again (or starts it, if it isn't running).
    nonisolated static func restartEngine() async {
        await Task.detached {
            let target = "gui/\(getuid())/\(EngineAgent.label)"
            if EngineAgent.run("/bin/launchctl", ["kickstart", "-k", target]) != 0 {
                EngineAgent.ensure() // not loaded at all: load it
                EngineAgent.run("/bin/launchctl", ["kickstart", target])
            }
        }.value
    }

    /// Whether the engine answers with its audio core running, within 12 s.
    static func cameBack(_ model: Model) async -> Bool {
        for _ in 0..<24 {
            try? await Task.sleep(for: .milliseconds(500))
            if model.reachable && model.snapshot.running { return true }
        }
        return false
    }

    /// Restarts coreaudiod (and Apple's AirPlay helper, which can lose track of it), with
    /// macOS asking for an administrator's password. False if cancelled or refused.
    static func restartCoreAudio() -> Bool {
        let script = "do shell script \"/usr/bin/killall coreaudiod; /bin/sleep 2; /usr/bin/killall -9 AirPlayXPCHelper; exit 0\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        return error == nil
    }
}

/// The top bar's button when the audio has stopped: in place of Hardware Output.
struct ResetButton: View {
    @EnvironmentObject var model: Model
    @ObservedObject var reset = ResetController.shared

    var body: some View {
        Button {
            reset.reset(model)
        } label: {
            if reset.busy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Resetting…")
                }
            } else {
                Label("Reset Audio", systemImage: "arrow.clockwise")
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .disabled(reset.busy)
        .help("The engine has stopped or isn't answering (after the Mac slept, say). This restarts it, with your settings; if that isn't enough, it offers to restart macOS's audio too.")
    }
}

/// The mini window's: a small red button in its header.
struct MiniResetButton: View {
    @EnvironmentObject var model: Model
    @ObservedObject var reset = ResetController.shared

    var body: some View {
        Button { reset.reset(model) } label: {
            if reset.busy {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "arrow.clockwise").font(.caption.bold())
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .controlSize(.small)
        .disabled(reset.busy)
        .help("The audio has stopped: restart the engine (and, if needed, macOS's audio)")
    }
}
