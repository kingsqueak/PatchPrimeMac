// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// Checking for a newer version: GitHub's latest release, compared with this one, once
// at startup and from Help → Check for Updates. Nothing is downloaded or installed: a
// newer version gets a quiet grey note in the top bar (until dismissed, for that
// version) with a link to the Releases page. Nothing is sent but the request itself.

import AppKit
import SwiftUI

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    static let releasesPage = URL(string: "https://github.com/kingsqueak/PatchPrimeMac/releases")!
    private static let latestAPI = URL(string: "https://api.github.com/repos/kingsqueak/PatchPrimeMac/releases/latest")!
    private static let dismissedKey = "updateDismissedVersion"

    /// A newer release than this one, when one was found.
    @Published private(set) var newer: (version: String, page: URL)?
    private var checkedAtStart = false

    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// Whether the note shows: a newer version, not dismissed.
    var showsNote: Bool {
        guard let newer else { return false }
        return UserDefaults.standard.string(forKey: Self.dismissedKey) != newer.version
    }

    func dismiss() {
        guard let newer else { return }
        UserDefaults.standard.set(newer.version, forKey: Self.dismissedKey)
        objectWillChange.send()
    }

    /// "0.1.10" against "0.1.9", number by number.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".")
                .map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// The latest release's version and page, or nil with why.
    static func fetchLatest() async -> (version: String, page: URL)? {
        var request = URLRequest(url: latestAPI, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("PatchPrimeMac/\(current)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return nil }
        let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesPage
        return (version, page)
    }

    /// Once per launch, quietly.
    func checkAtStart() {
        guard !checkedAtStart else { return }
        checkedAtStart = true
        Task {
            if let latest = await Self.fetchLatest(), Self.isNewer(latest.version, than: Self.current) {
                newer = latest
            }
        }
    }

    /// From the Help menu: says what it found, either way.
    func checkNow() {
        Task {
            let latest = await Self.fetchLatest()
            let alert = NSAlert()
            if let latest, Self.isNewer(latest.version, than: Self.current) {
                newer = latest
                alert.messageText = "PatchPrimeMac \(latest.version) is available"
                alert.informativeText = "You have \(Self.current). The Releases page has the new version and what's changed; download and install it from there when you're ready."
                alert.addButton(withTitle: "Open Releases Page")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(latest.page) }
            } else if latest != nil {
                alert.messageText = "PatchPrimeMac is up to date"
                alert.informativeText = "\(Self.current) is the latest version."
                alert.runModal()
            } else {
                alert.messageText = "Couldn't check for updates"
                alert.informativeText = "GitHub didn't answer. Check your internet connection, or look at the Releases page yourself."
                alert.addButton(withTitle: "Open Releases Page")
                alert.addButton(withTitle: "OK")
                if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(Self.releasesPage) }
            }
        }
    }
}

/// The quiet note in the top bar: a newer version, a link to it, and a ✕ that hides it
/// (for that version).
struct UpdateNote: View {
    @ObservedObject var checker = UpdateChecker.shared

    var body: some View {
        if checker.showsNote, let newer = checker.newer {
            HStack(spacing: 6) {
                Link("Version \(newer.version) is available", destination: newer.page)
                    .foregroundStyle(.secondary)
                Button { checker.dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Hide this until the next version")
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.12), in: Capsule())
            .fixedSize()
            .help("Opens the Releases page, where you can download it")
        }
    }
}
