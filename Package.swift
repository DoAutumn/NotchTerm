// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Renotch",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Renotch", targets: ["Renotch"])
    ],
    targets: [
        .executableTarget(
            name: "Renotch",
            path: "Sources/Renotch",
            resources: [
                .copy("Resources/TrayIconTemplate.png")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
