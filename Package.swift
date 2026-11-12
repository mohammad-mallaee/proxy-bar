// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ProxyBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ProxyBar",
            path: "Sources/ProxyBar"
        )
    ]
)
