// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = [
    .library(name: "SproutCore", targets: ["SproutCore"]),
    .library(name: "SproutCrypto", targets: ["SproutCrypto"]),
    .library(name: "SproutEconomics", targets: ["SproutEconomics"]),
    .library(name: "SproutStorage", targets: ["SproutStorage"]),
    .library(name: "SproutTransport", targets: ["SproutTransport"]),
    .library(name: "SproutBridge", targets: ["SproutBridge"]),
    .library(name: "SproutResolverAdapter", targets: ["SproutResolverAdapter"]),
    .library(name: "SproutAdminSupport", targets: ["SproutAdminSupport"]),
    .library(name: "SproutAppSupport", targets: ["SproutAppSupport"]),
    .executable(name: "sprout-cli", targets: ["sproutCLI"]),
    .executable(name: "sprout", targets: ["sproutCLI"]),
    .executable(name: "sprout-updater", targets: ["sproutUpdater"]),
    .executable(name: "sprout-admin", targets: ["sproutAdmin"])
]

var targets: [Target] = [
        .target(
            name: "SproutCrypto",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "Packages/SproutCrypto/Sources/SproutCrypto"
        ),
        .target(
            name: "SproutEconomics",
            dependencies: ["SproutTransport"],
            path: "Packages/SproutEconomics/Sources/SproutEconomics"
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
            dependencies: ["SproutCrypto", "SproutEconomics"],
            path: "Packages/SproutResolverAdapter/Sources/SproutResolverAdapter"
        ),
        .target(
            name: "SproutAdminSupport",
            dependencies: [
                "SproutCrypto",
                "SproutResolverAdapter",
                "SproutCore",
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "Packages/SproutAdminSupport/Sources/SproutAdminSupport"
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
                "SproutCrypto"
            ],
            path: "Packages/SproutAppSupport/Sources/SproutAppSupport"
        ),
        .executableTarget(
            name: "sproutCLI",
            dependencies: [
                "SproutCore",
                "SproutCrypto",
                "SproutEconomics",
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
            name: "sproutAdmin",
            dependencies: [
                "SproutAdminSupport",
                "SproutCrypto",
                "SproutResolverAdapter"
            ],
            path: "Apps/sprout-admin/Sources/sprout-admin"
        ),
        .testTarget(
            name: "SproutCryptoTests",
            dependencies: ["SproutCrypto"],
            path: "Tests/SproutCryptoTests"
        ),
        .testTarget(
            name: "SproutEconomicsTests",
            dependencies: ["SproutEconomics"],
            path: "Tests/SproutEconomicsTests"
        ),
        .testTarget(
            name: "SproutCoreTests",
            dependencies: [
                "SproutCore",
                "SproutCrypto",
                "SproutEconomics",
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
        ),
        .testTarget(
            name: "SproutAdminSupportTests",
            dependencies: [
                "SproutAdminSupport",
                "SproutCrypto",
                "SproutCore",
                "SproutResolverAdapter"
            ],
            path: "Tests/SproutAdminSupportTests"
        )
]

#if os(macOS)
products.append(.executable(name: "sprout-macos", targets: ["sproutMacOS"]))
targets.append(
    .executableTarget(
        name: "sproutMacOS",
        dependencies: ["SproutAppSupport"],
        path: "Apps/sprout-macos/Sources/sprout-macos"
    )
)
#endif

let package = Package(
    name: "sprout",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: products,
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-crypto.git",
            "3.15.1"..<"5.0.0"
        )
    ],
    targets: targets
)
