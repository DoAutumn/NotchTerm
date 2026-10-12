// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NotchTerm",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "NotchTerm", targets: ["NotchTerm"])
    ],
    targets: [
        .executableTarget(
            name: "NotchTerm",
            path: "Sources/NotchTerm",
            resources: [
                .copy("Resources/TrayIconTemplate.png"),
                .copy("Resources/TrayIconTemplate@2x.png"),
                .copy("Resources/TrayIconTemplate@3x.png"),
                .copy("Resources/notchterm-agent-hook.sh")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
