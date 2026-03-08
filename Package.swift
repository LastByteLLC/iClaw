// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iClaw",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "iClaw", targets: ["iClaw"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.6.0"),
        .package(url: "https://github.com/MacPaw/PermissionsKit.git", branch: "master"),
    ],
    targets: [
        .executableTarget(
            name: "iClaw",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
                .product(name: "PermissionsKit", package: "PermissionsKit"),
            ],
            path: "Sources/iClaw",
            exclude: ["Resources/Info.plist", "Resources/iClaw.entitlements"],
            resources: [
                .copy("Resources/Assets.car"),
                .copy("Resources/iClaw.icns"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/iClaw/Resources/Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "iClawTests",
            dependencies: ["iClaw"],
            path: "Tests/iClawTests"
        )
    ]
)
