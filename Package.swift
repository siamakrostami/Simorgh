// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Simorgh",
    platforms: [
        .iOS(.v13),
        .macOS(.v13),
        .tvOS(.v13),
        .watchOS(.v7)
    ],
    products: [
        .library(
            name: "Simorgh",
            targets: ["Simorgh"]
        ),
    ],
    targets: [
        .target(
            name: "Simorgh",
            path: "Sources",
            sources: [
                "Simorgh",
                "HeaderHandler",
                "Encoding",
                "Log",
                "Mime",
                "Error",
                "Client",
                "UploadProgress",
                "Router",
                "Data",
                "Reachability",
                "WebSocket",
                "DownloadManager"
            ],
            swiftSettings: [
                .define("SPM_SWIFT_6"),
                .define("SWIFT_PACKAGE")
            ]
        ),
        .testTarget(
            name: "SimorghTests",
            dependencies: ["Simorgh"],
            path: "Tests/SimorghTests"
        ),
    ],
    swiftLanguageModes: [.v6, .v5]
)
