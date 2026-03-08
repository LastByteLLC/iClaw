// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenClawLocal",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "OpenClawLocal", targets: ["OpenClawLocal"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.6.0"),
        .package(url: "https://github.com/MacPaw/PermissionsKit.git", branch: "master"),
    ],
    targets: [
        .executableTarget(
            name: "OpenClawLocal",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
                .product(name: "PermissionsKit", package: "PermissionsKit"),
            ],
            path: "Sources/OpenClawLocal"
        )
    ]
)
