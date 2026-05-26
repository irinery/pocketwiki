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
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.0.2")
    ],
    targets: [
        .executableTarget(
            name: "PocketWikiMac",
            dependencies: [
                .product(name: "MarkdownUI", package: "swift-markdown-ui")
            ],
            path: "Sources/PocketWikiMac",
            resources: [
                .process("Resources/PocketWikiMac.icns"),
                .process("Resources/wiki-review.md"),
                .process("Resources/pocketwiki-logo.png"),
                .process("Resources/GraphView"),
                .copy("Resources/ExcalidrawEditor")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
