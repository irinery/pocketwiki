// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PocketWikiMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PocketWikiMac", targets: ["PocketWikiMac"])
    ],
    targets: [
        .executableTarget(
            name: "PocketWikiMac",
            path: "Sources/PocketWikiMac",
            resources: [
                .process("Resources")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
