// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "EmbarsyApp",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "EmbarsyApp", targets: ["EmbarsyApp"]),
    ],
    targets: [
        .executableTarget(
            name: "EmbarsyApp",
            path: "Sources"
        ),
    ]
)
