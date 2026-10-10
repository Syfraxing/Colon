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
    ],
    targets: [
        .target(
            name: "ColonCore",
            resources: [.copy("Resources/emoji.json")]
        ),
        .executableTarget(
            name: "Colon",
            dependencies: [
                "ColonCore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ]
        ),
        .testTarget(
            name: "ColonCoreTests",
            dependencies: ["ColonCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
