// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// Spike S3: the main app's part. Registers and removes the login item.
import Foundation
import ServiceManagement

let service = SMAppService.loginItem(identifier: "com.kingsqueak.patchprimemac.s3.helper")

func describe(_ s: SMAppService.Status) -> String {
    switch s {
    case .notRegistered: return "notRegistered"
    case .enabled: return "enabled"
    case .requiresApproval: return "requiresApproval"
    case .notFound: return "notFound"
    @unknown default: return "unknown"
    }
}

let verb = CommandLine.arguments.dropFirst().first ?? "--status"
do {
    switch verb {
    case "--register":
        try service.register()
    case "--unregister":
        try service.unregister()
    default:
        break
    }
    print("login item status: \(describe(service.status))")
} catch {
    print("failed: \(error), status \(describe(service.status))")
    exit(1)
}
