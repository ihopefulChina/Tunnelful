// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TunnelApp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TunnelApp", targets: ["TunnelApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.2")
    ],
    targets: [
        .executableTarget(
            name: "TunnelApp",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "TunnelApp",
            exclude: ["Assets.xcassets", "Tunnelful.entitlements"]
        ),
        .testTarget(
            name: "TunnelAppTests",
            dependencies: ["TunnelApp"],
            path: "TunnelAppTests"
        )
    ]
)
