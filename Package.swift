// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Rasheed",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "Rasheed", targets: ["Rasheed"]),
        .library(name: "RasheedCore", targets: ["RasheedCore"]),
        .library(name: "RasheedNotificationService", targets: ["RasheedNotificationService"]),
    ],
    targets: [
        .binaryTarget(
            name: "RasheedCoreFFI",
            url: "https://github.com/AlfayezDev/rasheed-ios/releases/download/1.0.0-rc.2/RasheedCoreFFI.xcframework.zip",
            checksum: "52846333efa7335d06f3cac75cea5cf2ae842ae7002b37cec800d198fcd6516e"
        ),
        .target(
            name: "RasheedCore",
            dependencies: ["RasheedCoreFFI"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("SystemConfiguration"),
                .linkedLibrary("resolv"),
            ]
        ),
        .target(
            name: "Rasheed",
            dependencies: ["RasheedCore", "RasheedNotificationSupport"],
            resources: [.copy("Fonts"), .copy("Sounds")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "RasheedNotificationSupport",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "RasheedNotificationService",
            dependencies: ["RasheedNotificationSupport"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
