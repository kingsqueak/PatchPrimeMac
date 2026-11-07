// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris

import AppKit
import PPShared
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    // The menu bar item stays when the window closes, as the audio does.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
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
        save(MiniView {}, "-mini", CGSize(width: 170, height: 520))
        save(EffectsEditor(stage: .input, slot: 0, label: "RE20") {}, "-effects", CGSize(width: 720, height: 1400))
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
        Button("Quit (audio keeps running)") { NSApp.terminate(nil) }
    }
}
