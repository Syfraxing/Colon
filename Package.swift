// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Emojify",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Emojify", targets: ["Emojify"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "EmojifyCore",
            resources: [.copy("Resources/emoji.json")]
        ),
        .executableTarget(
            name: "Emojify",
            dependencies: [
                "EmojifyCore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ]
        ),
        .testTarget(
            name: "EmojifyCoreTests",
            dependencies: ["EmojifyCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
