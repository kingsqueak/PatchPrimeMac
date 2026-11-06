// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
import PackageDescription

let package = Package(
    name: "PatchPrimeMac",
    platforms: [.macOS("26.0")],
    targets: [
        // The realtime core: no allocation, locks or Objective-C on the audio path.
        // Swift reaches it through a plain C API.
        .target(
            name: "PPCore",
            path: "Sources/PPCore",
            cxxSettings: [.unsafeFlags(["-O3", "-ffast-math", "-fno-exceptions", "-fno-rtti"])]),
        .executableTarget(
            name: "ppcore-test",
            dependencies: ["PPCore"],
            path: "Sources/ppcore-test"),
    ],
    cxxLanguageStandard: .cxx20
)
