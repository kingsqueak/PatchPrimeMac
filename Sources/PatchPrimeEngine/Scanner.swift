// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// The plugin scan: only when the user starts it. Each plugin variant is checked by a
// patchprime-scan process of its own, several at once, each with a time limit; one
// that hangs is killed and marked, one that crashes is marked, and either is skipped
// from then on until its version changes. Results go into the cache as they come, so
// a scan that's stopped (or the helper restarted) carries on where it was.

import Foundation
import PPShared

final class PluginScanner {
    struct Job {
        var variant: PluginVariant
        var version: String
        var plugin: String // the entry's name, to show
    }

    private(set) var cache = PluginCache.load(from: PluginCache.defaultURL)
    private var queue: [Job] = []
    private var running: [Int32: (job: Job, process: Process, started: Date)] = [:]
    private(set) var total = 0
    private(set) var done = 0
    private var dirty = false
    private var stopped: Set<Int32> = [] // checks the user stopped: not a result
    private var overdue: Set<Int32> = [] // checks killed for taking too long
    // Background priority, so macOS keeps checks on the efficiency cores and they always
    // give way to audio; and not too many at once. Running all-out, 8 at a time disturbed
    // live audio (underruns) on a 12-core Mac.
    let parallel = 4
    let timeLimit: TimeInterval = 30
    var changed: () -> Void = {}

    var scanning: Bool { !queue.isEmpty || !running.isEmpty }
    var current: [String] { running.values.map(\.job.plugin).sorted() }

    static var tool: URL {
        // Inside the helper's bundle, beside it; in a development build, beside it too.
        Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("patchprime-scan")
    }

    /// `everything`: check again what's been checked; otherwise only what hasn't (at its
    /// version). What the filter hides isn't checked.
    func start(_ plugins: [PluginEntry], filter: PluginFilter, everything: Bool) {
        let jobs = plugins.filter { filter.shows($0) }.flatMap { p in
            p.variants.filter { $0.fitsStrips && (everything || cache.check($0, version: p.version) == nil) }
                .map { Job(variant: $0, version: p.version, plugin: "\(p.maker) \(p.name)") }
        }
        let busy = Set(running.values.map(\.job.variant.id))
        queue = jobs.filter { !busy.contains($0.variant.id) }
        total = queue.count + running.count
        done = 0
        pump()
        changed()
    }

    func stop() {
        queue = []
        for (pid, r) in running {
            stopped.insert(pid)
            r.process.terminate()
        }
        changed()
    }

    private func pump() {
        while running.count < parallel, !queue.isEmpty {
            let job = queue.removeFirst()
            let process = Process()
            process.executableURL = Self.tool
            process.arguments = [job.variant.id, job.version, "\(job.variant.inputs)", "\(job.variant.outputs)"]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            process.qualityOfService = .background
            process.terminationHandler = { [weak self] p in
                let data = out.fileHandleForReading.readDataToEndOfFile()
                DispatchQueue.main.async { self?.finished(p, data) }
            }
            do {
                try process.run()
                running[process.processIdentifier] = (job, process, Date())
            } catch {
                record(job, PluginCheck(status: .failed, version: job.version, message: "the scan tool wouldn't start"))
            }
        }
        if !running.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.watch() }
        }
        if !scanning { flush() }
    }

    /// Kills checks that have gone past their time.
    private func watch() {
        let now = Date()
        for (pid, r) in running where now.timeIntervalSince(r.started) > timeLimit && !overdue.contains(pid) {
            overdue.insert(pid)
            r.process.terminate()
        }
        if !running.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.watch() }
        }
    }

    private func finished(_ p: Process, _ data: Data) {
        guard let r = running.removeValue(forKey: p.processIdentifier) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let line = String(data: data, encoding: .utf8)?.split(separator: "\n").last.map(String.init) ?? ""
        if let check = try? decoder.decode(PluginCheck.self, from: Data(line.utf8)) {
            record(r.job, check)
        } else if stopped.remove(p.processIdentifier) == nil {
            let took = Date().timeIntervalSince(r.started)
            let late = overdue.remove(p.processIdentifier) != nil
            var check = PluginCheck(status: late ? .timedOut : .crashed, version: r.job.version,
                message: late ? "took longer than \(Int(timeLimit)) s" : "crashed while being checked")
            check.seconds = took
            record(r.job, check)
        }
        pump()
        changed()
    }

    private func record(_ job: Job, _ check: PluginCheck) {
        cache.checks[job.variant.id] = check
        done += 1
        dirty = true
        if done % 10 == 0 { flush() } // often enough that a stop loses little
    }

    func flush() {
        guard dirty else { return }
        try? cache.save(to: PluginCache.defaultURL)
        dirty = false
    }
}
