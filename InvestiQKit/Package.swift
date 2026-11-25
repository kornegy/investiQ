// swift-tools-version: 6.0
// InvestiQKit — all platform-independent business logic of InvestiQ.
// Builds and is tested on Linux (Docker, Swift 6.2) and macOS. See docs/ARCHITECTURE.md.
import PackageDescription

let strictSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "InvestiQKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(
            name: "InvestiQKit",
            targets: [
                "InvestiQCore", "InvestiQSecurity", "InvestiQPersistence", "InvestiQData",
                "InvestiQAnalytics", "InvestiQContent", "InvestiQServices", "InvestiQPresentation",
                "InvestiQPlatformApple",
            ]
        ),
    ],
    dependencies: [
        // Argon2id (libsodium). Exact pin — see docs/DECISIONS.md ADR-004.
        .package(url: "https://github.com/jedisct1/swift-sodium.git", exact: "0.12.0"),
        // CryptoKit-compatible API on Linux only (Apple platforms use CryptoKit directly).
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"6.0.0"),
    ],
    targets: [
        // System SQLite on Linux. Apple platforms use the SDK's SQLite3 module.
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite",
            pkgConfig: "sqlite3",
            providers: [.apt(["libsqlite3-dev"])]
        ),
        .target(name: "InvestiQCore", swiftSettings: strictSettings),
        .target(
            name: "InvestiQSecurity",
            dependencies: [
                "InvestiQCore",
                .product(name: "Sodium", package: "swift-sodium"),
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
            ],
            swiftSettings: strictSettings
        ),
        .target(
            name: "InvestiQPersistence",
            dependencies: [
                "InvestiQCore", "InvestiQSecurity",
                .target(name: "CSQLite", condition: .when(platforms: [.linux])),
            ],
            swiftSettings: strictSettings
        ),
        .target(name: "InvestiQAnalytics", dependencies: ["InvestiQCore"], swiftSettings: strictSettings),
        .target(
            name: "InvestiQData",
            dependencies: ["InvestiQCore", "InvestiQSecurity"],
            swiftSettings: strictSettings
        ),
        .target(
            name: "InvestiQContent",
            dependencies: ["InvestiQCore"],
            resources: [.copy("Resources")],
            swiftSettings: strictSettings
        ),
        .target(
            name: "InvestiQServices",
            dependencies: [
                "InvestiQCore", "InvestiQSecurity", "InvestiQPersistence", "InvestiQData",
                "InvestiQAnalytics", "InvestiQContent",
            ],
            swiftSettings: strictSettings
        ),
        .target(
            name: "InvestiQPresentation",
            dependencies: ["InvestiQCore", "InvestiQServices", "InvestiQAnalytics", "InvestiQData", "InvestiQContent", "InvestiQSecurity"],
            swiftSettings: strictSettings
        ),
        .target(
            name: "InvestiQPlatformApple",
            dependencies: ["InvestiQCore", "InvestiQSecurity", "InvestiQServices", "InvestiQData"],
            swiftSettings: strictSettings
        ),

        .target(name: "InvestiQTestSupport", dependencies: ["InvestiQCore", "InvestiQSecurity", "InvestiQData", "InvestiQServices"], path: "Tests/InvestiQTestSupport"),
        .testTarget(name: "InvestiQCoreTests", dependencies: ["InvestiQCore", "InvestiQTestSupport"]),
        .testTarget(name: "InvestiQSecurityTests", dependencies: ["InvestiQSecurity", "InvestiQTestSupport"]),
        .testTarget(name: "InvestiQPersistenceTests", dependencies: ["InvestiQPersistence", "InvestiQTestSupport"]),
        .testTarget(name: "InvestiQAnalyticsTests", dependencies: ["InvestiQAnalytics", "InvestiQTestSupport"]),
        .testTarget(
            name: "InvestiQDataTests",
            dependencies: ["InvestiQData", "InvestiQTestSupport"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "InvestiQServicesTests", dependencies: ["InvestiQServices", "InvestiQTestSupport", "InvestiQPersistence"]),
        .testTarget(name: "InvestiQPresentationTests", dependencies: ["InvestiQPresentation", "InvestiQTestSupport"]),
        .testTarget(name: "InvestiQContentTests", dependencies: ["InvestiQContent"]),
        .testTarget(name: "InvestiQPlatformAppleTests", dependencies: ["InvestiQPlatformApple"]),
    ]
)
