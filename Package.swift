// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuotaBar",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "QuotaBar", targets: ["QuotaBar"])],
    targets: [
        .target(name: "ProcessSupport", publicHeadersPath: "include"),
        .target(name: "QuotaCore", dependencies: ["ProcessSupport"]),
        .executableTarget(name: "QuotaBar", dependencies: ["QuotaCore"], resources: [.copy("Resources")]),
        .executableTarget(name: "QuotaCoreChecks", dependencies: ["QuotaCore"], path: "Tests/QuotaCoreTests"),
    ])
