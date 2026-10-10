// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Colon",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Colon", targets: ["Colon"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .target(
            name: "ColonCore",
            resources: [.copy("Resources/emoji.json"), .copy("Resources/i18n")]
        ),
        .executableTarget(
            name: "Colon",
            dependencies: [
                "ColonCore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .testTarget(
            name: "ColonCoreTests",
            dependencies: ["ColonCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
