// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// Keeping the engine alive through what macOS does to audio: sleep and wake, a start
// that fails, and its own main thread getting stuck.
// - Before the Mac sleeps, the audio core is stopped cleanly; a few seconds after it
//   wakes, it's started fresh with every device bound again. (Left running, it woke
//   with its old audio thread still registered, and macOS refused to start it again:
//   "there already is a thread".)
// - If the core can't start, it's tried again every few seconds, not left stopped.
// - A watchdog on another thread checks that the main thread still answers. If it has
//   been stuck for 20 s, the engine logs that and exits; the next request from the app
//   (or launchd) starts a fresh one.
// What happens is written to the system log: `log show --predicate
// 'subsystem == "com.kingsqueak.patchprimemac.engine"'`.

import AppKit
import Foundation
import os

let engineLog = Logger(subsystem: "com.kingsqueak.patchprimemac.engine", category: "engine")

/// The main thread's last sign of life, on the uptime clock (which stops while the Mac
/// sleeps, so a night's sleep doesn't look like a hang).
final class MainThreadWatch: @unchecked Sendable {
    static let shared = MainThreadWatch()
    static let limit: UInt64 = 20_000_000_000 // 20 s, in nanoseconds
    private let lock = NSLock()
    private var lastBeat = DispatchTime.now().uptimeNanoseconds
    private var timer: DispatchSourceTimer?

    func beat() { lock.withLock { lastBeat = DispatchTime.now().uptimeNanoseconds } }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [self] in
            // The beat first, then the time: a beat landing in between can't make it look
            // like the future (and the difference wrap round to an age of centuries).
            let last = lock.withLock { lastBeat }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now > last, now - last > Self.limit else { return }
            let stuck = now - last
            engineLog.fault("The engine's main thread hasn't answered for \(stuck / 1_000_000_000, privacy: .public) s; exiting so a fresh engine starts.")
            exit(70)
        }
        t.resume()
        timer = t
    }
}

extension Engine {
    /// Called once at start: sleep and wake, and the watchdog.
    func watchHealth() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.goingToSleep()
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.wokeUp()
        }
        MainThreadWatch.shared.start()
    }

    /// Before sleep: stop the audio core cleanly, so nothing of it is left registered.
    func goingToSleep() {
        engineLog.notice("Going to sleep: stopping the audio core.")
        asleep = true
        wakeWork?.cancel()
        if core != nil { stopCore() }
    }

    /// After wake: let macOS bring its devices back, then start fresh.
    func wokeUp() {
        engineLog.notice("Woke: starting the audio core again in 3 s.")
        wakeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.asleep = false
            self.lastStartAttempt = Date()
            self.refreshDevices() // starts the core, if the hidden device is back
            if self.core == nil {
                self.startCore(reason: "after wake")
            } else {
                engineLog.notice("Audio core started (after wake).")
                self.apply()
            }
        }
        wakeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    /// Every quarter second, from the clock timer: a heartbeat for the watchdog, and
    /// another try at starting the core if it isn't running.
    func checkHealth() {
        MainThreadWatch.shared.beat()
        guard core == nil, !asleep, Date().timeIntervalSince(lastStartAttempt) > 3 else { return }
        startCore(reason: "it wasn't running")
    }

    /// Starts the core (if it can) and binds everything to it.
    func startCore(reason: String) {
        lastStartAttempt = Date()
        startCoreIfPossible()
        if core != nil {
            engineLog.notice("Audio core started (\(reason, privacy: .public)).")
            apply()
        }
    }
}
