// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "ProxyTray",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "ProxyTray", targets: ["ProxyTray"]),
        .executable(name: "ProxyTrayHelper", targets: ["ProxyTrayHelper"])
    ],
    targets: [
        .target(
            name: "ProxyNetwork",
            path: "Sources/ProxyNetwork"
        ),
        .executableTarget(
            name: "ProxyTrayHelper",
            dependencies: ["ProxyNetwork"],
            path: "Sources/ProxyTrayHelper"
        ),
        .executableTarget(
            name: "ProxyTray",
            dependencies: ["ProxyNetwork"],
            path: "Sources/ProxyTray",
            resources: []
        ),
        .testTarget(
            name: "ProxyTrayTests",
            dependencies: ["ProxyTray"],
            path: "Tests/ProxyTrayTests"
        ),
        .testTarget(
            name: "ProxyNetworkTests",
            dependencies: ["ProxyNetwork"],
            path: "Tests/ProxyNetworkTests"
        )
    ]
)
