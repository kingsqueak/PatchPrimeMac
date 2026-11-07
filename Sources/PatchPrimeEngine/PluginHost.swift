// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// The plugins in the chains. Each is loaded out of process (Apple's AUHostingService),
// set to its chain's rate and channels, given its saved state, and attached to its slot;
// the engine's thread renders it from then on. A plugin whose process goes away is
// reloaded with its state. The engine never shares a process with a plugin.

import AppKit
import AudioToolbox
import AVFoundation
import CoreAudioKit
import Foundation
import PPCore
import PPDSP
import PPShared

final class PluginHost {
    struct Instance {
        var av: AVAudioUnit // one instance: rendered through its C handle, its window from its AUAudioUnit
        var unit: AudioUnit
        var au: OpaquePointer // PPAU
        var kind: Int32
        var slot: Int
        var index: Int
        var chainChannels: Int
    }

    /// By "<chain>#<index>#<type>#<channels>", so a change of any reloads.
    private var instances: [String: Instance] = [:]
    private var loading: Set<String> = []
    private(set) var problems: [String: String] = [:] // key → why it isn't running
    var rate = 48000.0
    /// The mixer to attach to now (nil while the engine is stopped). Read when a load
    /// finishes, never kept: the engine may have restarted in between.
    var mixerNow: () -> OpaquePointer? = { nil }
    private var generation = 0
    var restore: (String) -> String? = { _ in nil } // key → saved state (base64)

    static func key(_ chain: String, _ index: Int, _ e: EffectSetting, _ channels: Int) -> String {
        "\(chain)#\(index)#\(e.type)#\(channels)"
    }

    /// Makes the loaded plugins match what the chains hold. `wanted`: key → where it goes.
    func sync(_ mixer: OpaquePointer, wanted: [String: (kind: Int32, slot: Int, index: Int, effect: EffectSetting, channels: Int)]) {
        for (key, w) in wanted {
            if let i = instances[key] {
                attach(mixer, i) // a rebuilt chain has a new, empty slot
                // A scene or preset gave it another state: the running plugin takes it.
                if let wantedState = w.effect.state, wantedState != knownState[key] {
                    setState(i.unit, wantedState)
                    knownState[key] = wantedState
                    lastState[key] = wantedState
                }
            } else if !loading.contains(key) {
                load(key, w.effect, kind: w.kind, slot: w.slot, index: w.index, chainChannels: w.channels)
            }
        }
        for (key, i) in instances where wanted[key] == nil {
            instances[key] = nil
            knownState[key] = nil
            release(i)
        }
        problems = problems.filter { wanted[$0.key] != nil }
    }

    func attach(_ mixer: OpaquePointer, _ i: Instance) {
        guard let fx = pp_mixer_effects(mixer, i.kind, Int32(i.slot)), pp_fx_is_external(fx, Int32(i.index)) == 1 else { return }
        pp_fx_attach(fx, Int32(i.index), pp_au_external(i.au))
    }

    /// Plugins whose process went away: release them, so the next sync loads them again.
    func reapDead(_ mixer: OpaquePointer) -> Bool {
        var any = false
        for (key, i) in instances {
            guard let fx = pp_mixer_effects(mixer, i.kind, Int32(i.slot)), pp_fx_external_dead(fx, Int32(i.index)) == 1 else { continue }
            pp_fx_attach(fx, Int32(i.index), nil)
            var first = 0.0, slowest = 0.0
            var calls: UInt64 = 0
            pp_au_timing(i.au, &first, &slowest, &calls)
            lastDead.append(String(format: "%@ (dead): first %.3f ms, slowest %.3f ms, %llu calls, %llu blocks dry", key, first, slowest, calls, pp_au_late(i.au)))
            instances[key] = nil
            release(i)
            problems[key] = "its process stopped; loading it again"
            any = true
        }
        return any
    }

    /// Everything goes (the engine is stopping or restarting: no audio thread uses them).
    func releaseAll(now: Bool) {
        for (_, i) in instances { release(i, now: now) }
        instances = [:]
        loading = []
        generation += 1 // loads still on their way belong to the old engine
    }

    /// The current state of a loaded plugin, base64, for saving.
    func state(_ key: String) -> String? {
        guard let i = instances[key] else { return nil }
        var plist: Unmanaged<CFPropertyList>?
        var size = UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size)
        guard AudioUnitGetProperty(i.unit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &plist, &size) == noErr,
              let value = plist?.takeRetainedValue(),
              let data = try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        else { return nil }
        return data.base64EncodedString()
    }

    var loadedKeys: [String] { Array(instances.keys) }

    // The plugins by AudioUnit, for the invalidation notice, which can come on any thread.
    private let lock = NSLock()
    private var byUnit: [UnsafeMutableRawPointer: OpaquePointer] = [:]
    /// The hosting process the system last named for a plugin of ours.
    private(set) var hostPID: Int32 = 0
    private var observer: NSObjectProtocol?

    init() {
        // When a plugin's process goes, the system says so: stop calling it at once,
        // rather than finding out on the audio thread, then reload it.
        observer = NotificationCenter.default.addObserver(
            forName: Notification.Name(kAudioComponentInstanceInvalidationNotification as String), object: nil, queue: nil
        ) { [weak self] note in
            guard let self else { return }
            if let pid = note.userInfo?["Service PID"] as? NSNumber { self.hostPID = pid.int32Value }
            guard let value = note.userInfo?["audioUnit"] as? NSValue, let unit = value.pointerValue else { return }
            self.lock.lock()
            if let au = self.byUnit[unit] { pp_au_mark_gone(au) }
            self.lock.unlock()
            DispatchQueue.main.async { self.goneNow?() }
        }
    }

    /// Called on the main queue after a plugin's process went away.
    var goneNow: (() -> Void)?

    // MARK: Windows

    private var windows: [String: NSWindow] = [:]
    private var windowFor: [String: UnsafeMutableRawPointer] = [:]
    private var closers: [String: WindowCloser] = [:]
    /// The plugin's state changed (seen while its window is open, or as it closes).
    var stateChanged: (String, String) -> Void = { _, _ in }
    private var lastState: [String: String] = [:]
    /// The state each running plugin was last given or reported, to tell a new one.
    private var knownState: [String: String] = [:]

    private func setState(_ unit: AudioUnit, _ base64: String) {
        guard let data = Data(base64Encoded: base64),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return }
        var value: CFPropertyList = plist as CFPropertyList
        AudioUnitSetProperty(unit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &value,
            UInt32(MemoryLayout<CFPropertyList>.size))
    }
    private var watching: DispatchSourceTimer?

    var openWindows: [String] { Array(windows.keys) }

    /// Shows a plugin's own window (the plugin draws it in its process; macOS shows it here).
    func openWindow(_ key: String, title: String, done: @escaping (String?) -> Void) {
        if let w = windows[key] {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            done(nil)
            return
        }
        guard let i = instances[key] else { done("that plugin isn't loaded yet"); return }
        i.av.auAudioUnit.requestViewController { [weak self] vc in
            DispatchQueue.main.async {
                guard let self, let vc else { done("this plugin has no window of its own"); return }
                guard self.instances[key] != nil else { done("that plugin was removed"); return }
                var size = vc.preferredContentSize
                if size.width < 50 || size.height < 50 { size = vc.view.frame.size }
                if size.width < 50 || size.height < 50 { size = NSSize(width: 600, height: 400) }
                let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                    styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
                w.title = title
                w.isReleasedWhenClosed = false
                w.contentViewController = vc
                w.setContentSize(size)
                w.center()
                let closer = WindowCloser { [weak self] in self?.windowClosed(key) }
                w.delegate = closer
                self.closers[key] = closer
                self.windows[key] = w
                self.windowFor[key] = UnsafeMutableRawPointer(i.unit)
                self.lastState[key] = self.state(key)
                w.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                self.watch()
                done(nil)
            }
        }
    }

    func closeWindow(_ key: String) {
        windows[key]?.close() // the delegate does the rest
    }

    private func windowClosed(_ key: String) {
        checkState(key)
        windows[key] = nil
        windowFor[key] = nil
        closers[key] = nil
        lastState[key] = nil
        if windows.isEmpty {
            watching?.cancel()
            watching = nil
        }
    }

    /// While a window is open, its plugin's state is read every 2 seconds and saved when
    /// it has changed.
    private func watch() {
        guard watching == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            for key in self.windows.keys { self.checkState(key) }
        }
        t.resume()
        watching = t
    }

    func checkState(_ key: String) {
        guard let now = state(key), now != lastState[key] else { return }
        lastState[key] = now
        knownState[key] = now
        stateChanged(key, now)
    }

    /// Every loaded plugin's state now, by key, to save (before a scene or a preset).
    func allStates() -> [String: String] {
        var out: [String: String] = [:]
        for key in instances.keys {
            if let s = state(key) {
                out[key] = s
                knownState[key] = s
            }
        }
        return out
    }

    /// Render timings, for diagnosis: "<key>: first x ms, slowest y ms, n calls".
    var timings: [String] {
        instances.map { key, i in
            var first = 0.0, slowest = 0.0
            var calls: UInt64 = 0
            pp_au_timing(i.au, &first, &slowest, &calls)
            return String(format: "%@: first %.3f ms, slowest %.3f ms, %llu calls, %llu blocks dry", key, first, slowest, calls, pp_au_late(i.au))
        }.sorted()
    }

    /// Before a dead instance goes, what its calls looked like.
    private(set) var lastDead: [String] = []

    private func release(_ i: Instance, now: Bool = false) {
        for (key, w) in windows where windowFor[key] == UnsafeMutableRawPointer(i.unit) {
            w.delegate = nil
            w.close()
            windows[key] = nil
        }
        // Detached already (or its chain is gone); the audio thread may be finishing a
        // block with it, so wait a moment unless the engine is stopped.
        lock.lock()
        byUnit[UnsafeMutableRawPointer(i.unit)] = nil
        lock.unlock()
        let free = {
            pp_au_destroy(i.au)
            AudioUnitUninitialize(i.unit)
            _ = i.av // it owns the AudioUnit; it goes when this does
        }
        if now { free() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: free) }
    }

    private func load(_ key: String, _ e: EffectSetting, kind: Int32, slot: Int, index: Int, chainChannels: Int) {
        guard var desc = AudioUnitCatalog.description(e.type), let component = AudioComponentFindNext(nil, &desc) else {
            problems[key] = "isn't installed"
            return
        }
        loading.insert(key)
        let started = generation
        let variant = PluginVariant(id: e.type, channels: e.channels ?? "", name: e.plugin ?? "")
        let rate = self.rate
        _ = component
        AVAudioUnit.instantiate(with: desc, options: .loadOutOfProcess) { [weak self] av, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard started == self.generation else { return } // the engine restarted meanwhile
                self.loading.remove(key)
                guard let av else {
                    self.problems[key] = "wouldn't load (\(error?.localizedDescription ?? "no reason given"))"
                    return
                }
                let unit = av.audioUnit
                let inputs = variant.inputs, outputs = variant.outputs
                func format(_ n: Int) -> AudioStreamBasicDescription {
                    AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagsNativeEndian,
                        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: UInt32(n), mBitsPerChannel: 32, mReserved: 0)
                }
                var inF = format(inputs), outF = format(outputs)
                let size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                var maxFrames: UInt32 = 4096
                var st = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &inF, size)
                if st == noErr { st = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &outF, size) }
                AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, 4)
                if st == noErr { st = AudioUnitInitialize(unit) }
                guard st == noErr else {
                    self.problems[key] = "wouldn't start at \(Int(rate)) Hz, \(inputs) in, \(outputs) out (\(st))"
                    return
                }
                if let saved = self.restore(key) ?? e.state {
                    self.setState(unit, saved)
                    self.knownState[key] = saved
                }
                var latency: Float64 = 0
                var lsize = UInt32(MemoryLayout<Float64>.size)
                AudioUnitGetProperty(unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &latency, &lsize)
                guard let au = pp_au_create(unit, Int32(inputs), Int32(outputs), Int32(maxFrames), Int32((latency * rate).rounded()), rate) else { return }
                let instance = Instance(av: av, unit: unit, au: au, kind: kind, slot: slot, index: index, chainChannels: chainChannels)
                self.lock.lock()
                self.byUnit[UnsafeMutableRawPointer(unit)] = au
                self.lock.unlock()
                self.instances[key] = instance
                self.problems[key] = nil
                if let now = self.mixerNow() { self.attach(now, instance) }
            }
        }
    }
}

/// Tells the host when a plugin's window closes.
final class WindowCloser: NSObject, NSWindowDelegate {
    let closed: () -> Void
    init(_ closed: @escaping () -> Void) { self.closed = closed }
    func windowWillClose(_ notification: Notification) { closed() }
}
