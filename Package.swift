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
        // Patch Prime's built-in effects, copied from the Linux app, behind a C API.
        // No fast-math here: the effects check for non-finite samples.
        // Xiph.Org's RNNoise (BSD-3-Clause), vendored: see Sources/RNNoise/VENDORING.md.
        .target(
            name: "RNNoise",
            path: "Sources/RNNoise",
            exclude: ["COPYING", "AUTHORS", "VENDORING.md"],
            cSettings: [.unsafeFlags(["-O2", "-w"])]),
        .target(
            name: "PPDSP",
            dependencies: ["RNNoise"],
            path: "Sources/PPDSP",
            cxxSettings: [.define("PATCHPRIME_HAVE_RNNOISE"), .unsafeFlags(["-O3"])]),
        .target(
            name: "PPCore",
            dependencies: ["PPDSP"],
            path: "Sources/PPCore",
            cxxSettings: [.unsafeFlags(["-O3", "-ffast-math", "-fno-exceptions", "-fno-rtti"])],
            linkerSettings: [.linkedFramework("CoreAudio")]),
        .target(
            name: "PPShared",
            dependencies: ["PPCore"],
            path: "Sources/PPShared",
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "PatchPrimeEngine",
            dependencies: ["PPCore", "PPDSP", "PPShared"],
            path: "Sources/PatchPrimeEngine",
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "PatchPrimeMac",
            dependencies: ["PPShared", "PPDSP"],
            path: "Sources/PatchPrimeMac",
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "patchprime-ctl",
            dependencies: ["PPShared"],
            path: "Sources/patchprime-ctl",
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "patchprime-scan",
            dependencies: ["PPShared"],
            path: "Sources/patchprime-scan",
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "ppshared-test",
            dependencies: ["PPShared"],
            path: "Sources/ppshared-test"),
        .executableTarget(
            name: "ppengine-live",
            dependencies: ["PPCore"],
            path: "Sources/ppengine-live",
            linkerSettings: [.linkedFramework("CoreAudio"), .linkedFramework("CoreFoundation")]),
        .executableTarget(
            name: "ppdsp-test",
            dependencies: ["PPDSP"],
            path: "Sources/ppdsp-test",
            cxxSettings: [.headerSearchPath("../PPDSP"), .define("PATCHPRIME_HAVE_RNNOISE"), .unsafeFlags(["-O2"])]),
        .executableTarget(
            name: "ppcore-test",
            dependencies: ["PPCore", "PPDSP"],
            path: "Sources/ppcore-test"),
    ],
    cxxLanguageStandard: .cxx2b
)
