// swift-tools-version: 5.9
// Hangprobe — MIT Open Source (see LICENSE and docs/adr/0003-mit-open-source.md).

import PackageDescription

let package = Package(
    name: "Hangprobe",
    platforms: [.macOS(.v14), .iOS(.v16)],
    products: [
        .library(name: "HangprobeKit", targets: ["HangprobeKit"]),
        .library(name: "HangprobeCore", targets: ["HangprobeCore"]),
        .executable(name: "hangprobe", targets: ["hangprobe"]),
        .executable(name: "HangprobeApp", targets: ["HangprobeApp"]),
    ],
    targets: [
        .target(
            name: "HangprobeKit",
            path: "oss/HangprobeKit/Sources/HangprobeKit"
        ),
        .target(
            name: "HangprobeCore",
            path: "Sources/HangprobeCore"
        ),
        .executableTarget(
            name: "hangprobe",
            dependencies: ["HangprobeCore"],
            path: "Sources/hangprobe"
        ),
        .executableTarget(
            name: "HangprobeApp",
            dependencies: ["HangprobeCore"],
            path: "Sources/HangprobeApp",
            resources: [
                .copy("Resources/Fonts"),
            ]
        ),
        .testTarget(
            name: "HangprobeCoreTests",
            dependencies: ["HangprobeCore", "HangprobeKit"],
            path: "Tests/HangprobeCoreTests"
        ),
    ]
)
