// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris

import AppKit
import PPShared
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    // The menu bar item stays when the window closes, as the audio does.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // In front when opened, not behind the installer or whatever opened it.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct PatchPrimeMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = Model()

    init() {
        if let at = CommandLine.arguments.firstIndex(of: "--render"), at + 1 < CommandLine.arguments.count {
            Self.render(to: CommandLine.arguments[at + 1])
            exit(0)
        }
        EngineAgent.ensure()
    }

    var body: some Scene {
        WindowGroup("PatchPrimeMac", id: "mixer") {
            ContentView()
                .environmentObject(model)
                .onAppear { model.start() }
        }
        .defaultSize(width: 860, height: 560)
        // The window's minimum comes from what's in it (the full mixer or the mini view),
        // and nothing more: the remembered sizes are ours to set.
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .help) { HelpCommand() }
        }
        WindowGroup("Effects", id: "effects", for: EffectsTarget.self) { $target in
            if let target {
                EffectsWindow(target: target).environmentObject(model)
            }
        }
        .defaultSize(width: 720, height: 720)
        .windowResizability(.contentMinSize)
        Window("Soundboard", id: "soundboard") {
            SoundboardView().environmentObject(model)
        }
        .defaultSize(width: 680, height: 560)
        Window("Recordings", id: "recordings") {
            RecordingsView().environmentObject(model)
        }
        .defaultSize(width: 760, height: 520)
        Window("PatchPrimeMac Help", id: "help") {
            HelpView()
        }
        .defaultSize(width: 900, height: 640)
        MenuBarExtra("PatchPrimeMac", systemImage: "slider.vertical.3") {
            MenuContent().environmentObject(model)
        }
    }

    /// Draws each page with sample data to PNG files, so the look can be checked
    /// without the engine or a screen.
    @MainActor static func render(to base: String) {
        let model = Model(sample: .sample)
        func save<V: View>(_ view: V, _ name: String, _ size: CGSize) {
            let page = view.environmentObject(model)
                .frame(width: size.width, height: size.height)
                .background(Color(white: 0.15))
                .preferredColorScheme(.dark)
            let hosting = NSHostingView(rootView: page)
            hosting.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = hosting
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = .windowBackgroundColor
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            hosting.layoutSubtreeIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: base + name + ".png"))
        }
        save(ContentView(), "-mixer", CGSize(width: 860, height: 560))
        save(RoutingView(), "-routing", CGSize(width: 620, height: 300))
        save(SetupView(), "-setup", CGSize(width: 620, height: 700))
        save(RecordingsView(), "-recordings", CGSize(width: 860, height: 420))
        save(SoundboardView(), "-soundboard", CGSize(width: 680, height: 560))
        save(MiniView {}, "-mini", CGSize(width: 170, height: 520))
        save(HelpView(), "-help", CGSize(width: 900, height: 640))
        save(EffectsEditor(stage: .input, slot: 0, label: "RE20") {}, "-effects", CGSize(width: 720, height: 1400))
        save(EffectsEditor(stage: .input, slot: 1, label: "PR30") {}, "-effects2", CGSize(width: 720, height: 1700))
        save(EffectsEditor(stage: .input, slot: 2, label: "Desktop") {}, "-effects3", CGSize(width: 720, height: 1000))
    }
}

/// The menu bar item's menu.
struct MenuContent: View {
    @EnvironmentObject var model: Model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.reachable ? "Engine running" : "Engine isn't running")
        Divider()
        Button("Open Mixer") {
            NSApp.activate(ignoringOtherApps: true)
            // The mixer window if it's there (even minimised); a new one if it was closed.
            if let w = NSApp.windows.first(where: {
                ($0.identifier?.rawValue.hasPrefix("mixer") == true || $0.title == "PatchPrimeMac") && ($0.isVisible || $0.isMiniaturized)
            }) {
                if w.isMiniaturized { w.deminiaturize(nil) }
                w.makeKeyAndOrderFront(nil)
            } else {
                openWindow(id: "mixer")
            }
        }
        Button("Help") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "help")
        }
        Divider()
        Button("Quit (audio keeps running)") { NSApp.terminate(nil) }
    }
}

/// Help → PatchPrimeMac Help.
struct HelpCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("PatchPrimeMac Help") { openWindow(id: "help") }
            .keyboardShortcut("?", modifiers: .command)
        if let uninstaller = EngineAgent.uninstaller {
            Divider()
            Button("Uninstall PatchPrimeMac…") { NSWorkspace.shared.open(uninstaller) }
        }
    }
}

/// The engine's LaunchAgent, for an installed copy (the engine inside this app's
/// bundle): written and started if it's missing or points at another copy, so the
/// engine runs for every user who opens the app, and after the app moves between the
/// system's and the user's Applications folders.
enum EngineAgent {
    static let label = "com.kingsqueak.patchprimemac.engine"

    /// The engine inside this app, if this is an installed copy: in Applications (the
    /// system's or the user's). A copy anywhere else (a build folder, an unpacked
    /// installer, a disk image) leaves the engine that's running alone.
    static var bundledEngine: URL? {
        let app = Bundle.main.bundleURL.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard app == "/Applications/PatchPrimeMac.app" || app == home + "/Applications/PatchPrimeMac.app" else { return nil }
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/PatchPrimeEngine.app/Contents/MacOS/PatchPrimeEngine")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static func ensure() {
        guard let engine = bundledEngine else { return } // a development build: scripts do this
        let home = FileManager.default.homeDirectoryForCurrentUser
        let plist = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        let logs = home.appendingPathComponent("Library/Logs/PatchPrimeMac")
        if let current = NSDictionary(contentsOf: plist), current["Program"] as? String == engine.path { return }
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        let agent: NSDictionary = [
            "Label": label,
            "Program": engine.path,
            "RunAtLoad": true,
            "MachServices": [label: true],
            "ProcessType": "Interactive",
            "StandardOutPath": logs.appendingPathComponent("engine.log").path,
            "StandardErrorPath": logs.appendingPathComponent("engine.log").path,
            "AssociatedBundleIdentifiers": "com.kingsqueak.patchprimemac",
        ]
        let domain = "gui/\(getuid())"
        run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        guard agent.write(to: plist, atomically: true) else { return }
        run("/bin/launchctl", ["bootstrap", domain, plist.path])
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// The uninstaller inside the app, if this is an installed copy.
    static var uninstaller: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Uninstall PatchPrimeMac.app")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
