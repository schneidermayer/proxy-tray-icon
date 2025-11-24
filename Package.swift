// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "ProxyTray",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "ProxyTray", targets: ["ProxyTray"])
    ],
    targets: [
        .executableTarget(
            name: "ProxyTray",
            path: "Sources/ProxyTray",
            resources: []
        )
    ]
)
