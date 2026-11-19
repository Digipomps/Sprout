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
                "SproutResolverAdapter",
                .product(name: "Crypto", package: "swift-crypto"),
                // CellProtocol's own BridgeChannelAuthentication.Endpoint decides
                // whether a native bridge endpoint can be opened (R9).
                .product(name: "CellBase", package: "CellProtocol")
            ],
            path: "Packages/SproutCore/Sources/SproutCore",
            exclude: ["Resources"]
        ),
        .target(
            name: "SproutAppSupport",
            dependencies: [
                "SproutCore",
                "SproutCrypto",
                .product(name: "CellBase", package: "CellProtocol"),
                // NativePortholeBindingRuntime is compiled only with
                // -DSPROUT_ENABLE_CELLPROTOCOL_RUNTIME (CI job
                // cellprotocol-runtime); without it CellApple is linked but unused.
                .product(name: "CellApple", package: "CellProtocol", condition: .when(platforms: [.macOS, .iOS]))
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
                "SproutTransport",
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "Tests/SproutCoreTests",
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "SproutAppSupportTests",
            dependencies: [
                "SproutAppSupport",
                "SproutCore",
                "SproutCrypto",
                "SproutResolverAdapter",
                .product(name: "CellBase", package: "CellProtocol"),
                .product(name: "CellApple", package: "CellProtocol", condition: .when(platforms: [.macOS, .iOS]))
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
        dependencies: [
            "SproutAppSupport",
            .product(name: "CellApple", package: "CellProtocol")
        ],
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
            "4.5.2"..<"5.0.0"
        ),
        // Same revision as HavenAgentD pins (CellProtocol main 033875c = #94 squash: musl support,
        // needed by the static Linux release). SproutCore uses
        // CellBase directly instead of restating CellProtocol's rules.
        .package(
            url: "https://github.com/Digipomps/CellProtocol.git",
            revision: "033875c86fb1fddac643638fede6f36b0c32a820"
        )
    ],
    targets: targets
)
