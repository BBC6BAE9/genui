// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "GenAIPrimitives",
    products: [
        .library(
            name: "GenAIPrimitives",
            targets: ["GenAIPrimitives"]
        ),
    ],
    targets: [
        .target(
            name: "GenAIPrimitives"
        ),
        .testTarget(
            name: "GenAIPrimitivesTests",
            dependencies: ["GenAIPrimitives"]
        ),
    ]
)
