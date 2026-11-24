// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RasheedSupport",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "RasheedSupport", targets: ["RasheedSupport"]),
        .library(name: "RasheedCore", targets: ["RasheedCore"]),
        .library(name: "RasheedNotificationService", targets: ["RasheedNotificationService"]),
    ],
    targets: [
        .binaryTarget(
            name: "RasheedCoreFFI",
            url: "https://github.com/AlfayezDev/rasheed-ios/releases/download/1.0.0-rc.0/RasheedCoreFFI.xcframework.zip",
            checksum: "cedb90174fc8f055f1031791897e7f8f4205d080a5e2fe5f3ca085f51942fa4b"
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
            name: "RasheedSupport",
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
