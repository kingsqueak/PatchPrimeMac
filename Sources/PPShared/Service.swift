// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// How the GUI and patchprime-ctl talk to the engine helper.

import Foundation

public let engineMachService = "com.kingsqueak.patchprimemac.engine"

@objc public protocol PPEngineService {
    /// Takes a JSON array of words, and answers with JSON.
    func request(_ data: Data, reply: @escaping (Data) -> Void)
}

public struct Reply: Codable, Sendable {
    public var ok: Bool
    public var text: String

    public init(ok: Bool, text: String) {
        self.ok = ok
        self.text = text
    }
}

/// Sends one request. Fails after a few seconds rather than hanging.
public func sendToEngine(_ words: [String], timeout: TimeInterval = 8) -> Reply {
    let connection = NSXPCConnection(machServiceName: engineMachService)
    connection.remoteObjectInterface = NSXPCInterface(with: PPEngineService.self)
    connection.resume()
    defer { connection.invalidate() }
    let done = DispatchSemaphore(value: 0)
    let box = ReplyBox()
    let proxy = connection.remoteObjectProxyWithErrorHandler { error in
        box.value = Reply(ok: false, text: "engine isn't reachable: \(error.localizedDescription)")
        done.signal()
    } as? PPEngineService
    guard let proxy, let data = try? JSONEncoder().encode(words) else {
        return Reply(ok: false, text: "engine isn't reachable")
    }
    proxy.request(data) { answer in
        box.value = (try? JSONDecoder().decode(Reply.self, from: answer)) ?? Reply(ok: false, text: "bad answer")
        done.signal()
    }
    if done.wait(timeout: .now() + timeout) == .timedOut {
        return Reply(ok: false, text: "engine didn't answer in \(Int(timeout)) s")
    }
    return box.value ?? Reply(ok: false, text: "no answer")
}

private final class ReplyBox: @unchecked Sendable {
    var value: Reply?
}
