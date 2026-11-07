// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// Command line control of the engine: patchprime-ctl help
import Foundation
import PPShared

let words = Array(CommandLine.arguments.dropFirst())
let reply = sendToEngine(words.isEmpty ? ["status"] : words)
print(reply.text)
exit(reply.ok ? 0 : 1)
