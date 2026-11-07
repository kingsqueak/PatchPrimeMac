// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// The user guide in a window: docs/user-guide.md (bundled in the app), with its topics
// down the side, search, and the links between topics followed inside the window.

import SwiftUI

struct HelpTopic: Identifiable, Hashable {
    var id: String { anchor }
    var chapter: String
    var title: String
    var anchor: String   // as GitHub makes it: lower case, spaces to dashes
    var keywords: String
    var body: [String]   // its lines
}

enum HelpGuide {
    /// The guide: from the app's bundle, or, run from a build folder, the source tree
    /// it's in (found by looking upward, so no build machine's path is built in).
    static func load() -> (intro: [String], topics: [HelpTopic]) {
        var url = Bundle.main.url(forResource: "user-guide", withExtension: "md")
        var dir = Bundle.main.executableURL?.deletingLastPathComponent()
        while url == nil, let d = dir, d.path != "/" {
            let candidate = d.appendingPathComponent("docs/user-guide.md")
            if FileManager.default.fileExists(atPath: candidate.path) { url = candidate }
            dir = d.deletingLastPathComponent()
        }
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else {
            return (["The user guide couldn't be found."], [])
        }
        return parse(text)
    }

    static func anchor(_ title: String) -> String {
        String(title.lowercased().compactMap { c -> Character? in
            if c.isLetter || c.isNumber || c == "-" { return c }
            if c == " " { return "-" }
            return nil
        })
    }

    static func parse(_ text: String) -> (intro: [String], topics: [HelpTopic]) {
        var intro: [String] = []
        var topics: [HelpTopic] = []
        var chapter = ""
        var current: HelpTopic?
        for raw in text.components(separatedBy: "\n") {
            let line = raw
            if line.hasPrefix("# ") { continue }
            if line.hasPrefix("## ") {
                if let c = current { topics.append(c) }
                current = nil
                chapter = String(line.dropFirst(3))
                // A chapter with text of its own before its first topic is a topic too.
                current = HelpTopic(chapter: chapter, title: chapter, anchor: anchor(chapter), keywords: "", body: [])
                continue
            }
            if line.hasPrefix("### ") {
                if let c = current, !(c.title == chapter && c.body.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    topics.append(c)
                }
                let title = String(line.dropFirst(4))
                current = HelpTopic(chapter: chapter, title: title, anchor: anchor(title), keywords: "", body: [])
                continue
            }
            if line.hasPrefix("<!-- keywords:") {
                current?.keywords = line.replacingOccurrences(of: "<!-- keywords:", with: "").replacingOccurrences(of: "-->", with: "")
                continue
            }
            if current != nil { current?.body.append(line) } else { intro.append(line) }
        }
        if let c = current { topics.append(c) }
        return (intro, topics)
    }
}

struct HelpView: View {
    @State private var guide = HelpGuide.load()
    @State private var selection: String?
    @State private var search = ""

    var shown: [HelpTopic] {
        let words = search.lowercased().split(separator: " ")
        guard !words.isEmpty else { return guide.topics }
        return guide.topics.filter { t in
            let hay = (t.title + " " + t.keywords + " " + t.body.joined(separator: " ")).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(chapters(shown), id: \.self) { chapter in
                    Section(chapter) {
                        ForEach(shown.filter { $0.chapter == chapter }) { t in
                            Text(t.title).tag(Optional(t.anchor))
                        }
                    }
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Search the guide")
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            ScrollViewReader { _ in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if let t = guide.topics.first(where: { $0.anchor == selection }) {
                            Text(t.chapter.uppercased()).font(.caption.bold()).foregroundStyle(.secondary)
                            Text(t.title).font(.title.bold())
                            HelpText(lines: t.body)
                        } else {
                            Text("PatchPrimeMac").font(.title.bold())
                            HelpText(lines: guide.intro)
                            Text("Choose a topic, or search.").foregroundStyle(.secondary)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(selection)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            // "#cue-headphones": another topic in this guide.
            if url.absoluteString.hasPrefix("#") {
                selection = String(url.absoluteString.dropFirst())
                search = ""
                return .handled
            }
            return .systemAction
        })
        .frame(minWidth: 700, minHeight: 480)
    }

    func chapters(_ topics: [HelpTopic]) -> [String] {
        var seen: [String] = []
        for t in topics where !seen.contains(t.chapter) { seen.append(t.chapter) }
        return seen
    }
}

/// A topic's lines: paragraphs, bullets and numbered steps, with inline formatting.
struct HelpText: View {
    var lines: [String]

    enum Block: Hashable { case paragraph(String), bullet(String), step(String, String) }

    var blocks: [Block] {
        var out: [Block] = []
        var paragraph = ""
        func flush() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph)) }
            paragraph = ""
        }
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { flush(); continue }
            if t.hasPrefix("- ") {
                flush()
                out.append(.bullet(String(t.dropFirst(2))))
            } else if let dot = t.firstIndex(of: "."), let n = Int(t[..<dot]), t[t.index(after: dot)...].hasPrefix(" ") {
                flush()
                out.append(.step("\(n).", String(t[t.index(dot, offsetBy: 2)...])))
            } else {
                paragraph += paragraph.isEmpty ? t : " " + t
            }
        }
        flush()
        return out
    }

    static func styled(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case let .paragraph(s):
                    Text(Self.styled(s)).fixedSize(horizontal: false, vertical: true)
                case let .bullet(s):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Text(Self.styled(s)).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 4)
                case let .step(n, s):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(n).foregroundStyle(.secondary).monospacedDigit()
                        Text(Self.styled(s)).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 4)
                }
            }
        }
        .textSelection(.enabled)
        .lineSpacing(2)
    }
}
