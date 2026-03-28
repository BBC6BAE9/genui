// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "A2UI",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .watchOS(.v10),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "A2UIV08",
            targets: ["A2UIV08"]
        ),
        .library(
            name: "A2UIV09",
            targets: ["A2UIV09"]
        ),
        .library(
            name: "A2UIV09_A2A",
            targets: ["A2UIV09_A2A"]
        ),
    ],
    targets: [
        .target(
            name: "A2UIV09",
            path: "Sources/A2UIV09"
        ),
        .target(
            name: "A2UIV09_A2A",
            dependencies: ["A2UIV09"],
            path: "Sources/A2UIV09_A2A"
        ),
        .target(
            name: "A2UIV08",
            path: "Sources/A2UIV08"
        ),
        .testTarget(
            name: "A2UIV09Tests",
            dependencies: ["A2UIV09"],
            path: "Tests/A2UIV09Tests"
        ),
        .testTarget(
            name: "A2UIV09_A2ATests",
            dependencies: ["A2UIV09_A2A"],
            path: "Tests/A2UIV09_A2ATests"
        ),
        .testTarget(
            name: "A2UIV08Tests",
            dependencies: ["A2UIV08"],
            path: "Tests/A2UIV08Tests"
        ),
    ]
)
