// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TunnelApp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TunnelApp", targets: ["TunnelApp"])
    ],
    targets: [
        .executableTarget(
            name: "TunnelApp",
            path: "TunnelApp",
            exclude: ["Assets.xcassets"]
        ),
        .testTarget(
            name: "TunnelAppTests",
            dependencies: ["TunnelApp"],
            path: "TunnelAppTests"
        )
    ]
)
