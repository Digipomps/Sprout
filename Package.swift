// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "sprout",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(name: "SproutCore", targets: ["SproutCore"]),
        .library(name: "SproutCrypto", targets: ["SproutCrypto"]),
        .library(name: "SproutStorage", targets: ["SproutStorage"]),
        .library(name: "SproutTransport", targets: ["SproutTransport"]),
        .library(name: "SproutBridge", targets: ["SproutBridge"]),
        .library(name: "SproutResolverAdapter", targets: ["SproutResolverAdapter"]),
        .library(name: "SproutAppSupport", targets: ["SproutAppSupport"]),
        .executable(name: "sprout-cli", targets: ["sproutCLI"]),
        .executable(name: "sprout", targets: ["sproutCLI"]),
        .executable(name: "sprout-updater", targets: ["sproutUpdater"]),
        .executable(name: "sprout-macos", targets: ["sproutMacOS"])
    ],
    dependencies: [
        .package(path: "../CellProtocol")
    ],
    targets: [
        .target(
            name: "SproutCrypto",
            path: "Packages/SproutCrypto/Sources/SproutCrypto"
        ),
        .target(
            name: "SproutStorage",
            dependencies: ["SproutCrypto"],
            path: "Packages/SproutStorage/Sources/SproutStorage"
        ),
        .target(
            name: "SproutTransport",
            dependencies: ["SproutCrypto"],
            path: "Packages/SproutTransport/Sources/SproutTransport"
        ),
        .target(
            name: "SproutResolverAdapter",
            dependencies: ["SproutCrypto"],
            path: "Packages/SproutResolverAdapter/Sources/SproutResolverAdapter"
        ),
        .target(
            name: "SproutBridge",
            dependencies: [
                "SproutCrypto",
                "SproutTransport"
            ],
            path: "Packages/SproutBridge/Sources/SproutBridge"
        ),
        .target(
            name: "SproutCore",
            dependencies: [
                "SproutCrypto",
                "SproutStorage",
                "SproutTransport",
                "SproutBridge",
                "SproutResolverAdapter"
            ],
            path: "Packages/SproutCore/Sources/SproutCore"
        ),
        .target(
            name: "SproutAppSupport",
            dependencies: [
                "SproutCore",
                "SproutCrypto",
                .product(name: "CellBase", package: "CellProtocol"),
                .product(name: "CellApple", package: "CellProtocol")
            ],
            path: "Packages/SproutAppSupport/Sources/SproutAppSupport"
        ),
        .executableTarget(
            name: "sproutCLI",
            dependencies: [
                "SproutCore",
                "SproutCrypto",
                "SproutBridge",
                "SproutResolverAdapter",
                "SproutStorage"
            ],
            path: "Apps/sprout-cli/Sources/sprout-cli"
        ),
        .executableTarget(
            name: "sproutUpdater",
            dependencies: [
                "SproutCore",
                "SproutCrypto"
            ],
            path: "Apps/sprout-updater/Sources/sprout-updater"
        ),
        .executableTarget(
            name: "sproutMacOS",
            dependencies: [
                "SproutAppSupport",
                .product(name: "CellBase", package: "CellProtocol"),
                .product(name: "CellApple", package: "CellProtocol")
            ],
            path: "Apps/sprout-macos/Sources/sprout-macos"
        ),
        .testTarget(
            name: "SproutCryptoTests",
            dependencies: ["SproutCrypto"],
            path: "Tests/SproutCryptoTests"
        ),
        .testTarget(
            name: "SproutCoreTests",
            dependencies: [
                "SproutCore",
                "SproutCrypto",
                "SproutBridge",
                "SproutResolverAdapter",
                "SproutStorage",
                "SproutTransport"
            ],
            path: "Tests/SproutCoreTests"
        ),
        .testTarget(
            name: "SproutAppSupportTests",
            dependencies: [
                "SproutAppSupport",
                "SproutCore",
                "SproutCrypto",
                "SproutResolverAdapter"
            ],
            path: "Tests/SproutAppSupportTests"
        ),
        .testTarget(
            name: "SproutBridgeTests",
            dependencies: ["SproutBridge", "SproutCrypto"],
            path: "Tests/SproutBridgeTests"
        )
    ]
)
