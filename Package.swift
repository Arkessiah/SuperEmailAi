// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SuperEmailAi",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SuperEmailAi",
            path: "SuperEmailAi",
            exclude: ["Info.plist", "SuperEmailAi.entitlements"]
        )
    ]
)
