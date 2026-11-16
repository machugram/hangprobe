// swift-tools-version: 5.9
// SPDX-License-Identifier: MIT
// Root Package.swift for the public `hangprobe-sdk` GitHub repository (exported 1:1 from `oss/`).

import PackageDescription

let package = Package(
    name: "HangprobeKit",
    platforms: [.iOS(.v16), .macOS(.v14)],
    products: [
        .library(name: "HangprobeKit", targets: ["HangprobeKit"]),
    ],
    targets: [
        .target(name: "HangprobeKit", path: "HangprobeKit/Sources/HangprobeKit"),
    ]
)
