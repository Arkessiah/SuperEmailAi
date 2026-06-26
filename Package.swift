// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SuperEmailAi",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0")
    ],
    targets: [
        .executableTarget(
            name: "SuperEmailAi",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "SuperEmailAi",
            exclude: ["Info.plist", "SuperEmailAi.entitlements"]
        )
    ]
)
