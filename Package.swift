// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyQuotaBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MyQuotaBar", targets: ["MyQuotaBar"])
    ],
    targets: [
        .executableTarget(
            name: "MyQuotaBar",
            path: "Sources/MyQuotaBar"
        )
    ]
)
