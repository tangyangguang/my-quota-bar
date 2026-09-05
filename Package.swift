// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyQuotaBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MyQuotaBar", targets: ["MyQuotaBar"]),
        .executable(name: "CredHelper", targets: ["CredHelper"])
    ],
    targets: [
        .executableTarget(
            name: "MyQuotaBar",
            path: "Sources/MyQuotaBar"
        ),
        .executableTarget(
            name: "CredHelper",
            path: "Sources/CredHelper"
        ),
        .testTarget(
            name: "MyQuotaBarTests",
            dependencies: ["MyQuotaBar"],
            path: "Tests/MyQuotaBarTests"
        )
    ]
)
