// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "iClaw",
    defaultLocalization: "en",
    platforms: [
        .macOS("26.0"),
        .iOS("26.0")
    ],
    products: [
        .library(name: "iClawCore", targets: ["iClawCore"]),
        .executable(name: "iClaw", targets: ["iClaw"]),
        .executable(name: "iClawMobile", targets: ["iClawMobile"]),
        .executable(name: "iClawNativeHost", targets: ["iClawNativeHost"]),
        .executable(name: "iClawStressTest", targets: ["iClawStressTest"]),
        .executable(name: "iClawEnergyBench", targets: ["iClawEnergyBench"]),
        .executable(name: "iClawCLI", targets: ["iClawCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.6.0"),
        .package(url: "https://github.com/mattt/Replay.git", from: "0.4.0"),
        .package(url: "https://github.com/mgriebling/SwiftMath.git", from: "1.7.3"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.7.0"),
    ],
    targets: [
        .target(
            name: "ObjCExceptionCatcher",
            path: "Sources/ObjCExceptionCatcher",
            publicHeadersPath: "include"
        ),
        .target(
            name: "iClawCore",
            dependencies: [
                "ObjCExceptionCatcher",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
                .product(name: "SwiftMath", package: "SwiftMath"),
            ],
            path: "Sources/iClawCore",
            exclude: ["Resources/Info.plist", "Resources/iClaw.entitlements", "Resources/iClaw-MAS.entitlements"],
            resources: [
                .process("Resources/en.lproj"),
                .copy("Resources/Assets.car"),
                .copy("Resources/iClaw.icns"),
                .process("Resources/SOUL.md"),
                .process("Resources/BRAIN.md"),
                .process("Resources/BRAIN-conversational.md"),
                .copy("Resources/Config"),
                .copy("Resources/Skills"),
                .copy("Resources/ToolClassifier_MaxEnt_Merged.mlmodelc"),
                .copy("Resources/ToxicityClassifier_MaxEnt.mlmodelc"),
                .copy("Resources/FollowUpClassifier_MaxEnt.mlmodelc"),
                .copy("Resources/ResponsePathologyClassifier_MaxEnt.mlmodelc"),
                .copy("Resources/ConversationIntentClassifier_MaxEnt.mlmodelc"),
                .copy("Resources/UserFactClassifier_MaxEnt.mlmodelc")
            ]
        ),
        .executableTarget(
            name: "iClaw",
            dependencies: [
                "iClawCore",
                .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS])),
            ],
            path: "Sources/iClaw",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/iClawCore/Resources/Info.plist"
                ])
            ]
        ),
        .executableTarget(
            name: "iClawMobile",
            dependencies: ["iClawCore"],
            path: "Sources/iClawMobile",
            exclude: ["Resources/iClawMobile.entitlements", "Resources/Info-iOS.plist"]
        ),
        .executableTarget(
            name: "iClawNativeHost",
            path: "Sources/iClawNativeHost"
        ),
        .executableTarget(
            name: "iClawStressTest",
            dependencies: ["iClawCore"],
            path: "Sources/iClawStressTest",
            exclude: ["Resources/Info.plist", "Resources/StressTest.entitlements"],
            resources: [
                .copy("Resources/Config")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/iClawStressTest/Resources/Info.plist"
                ])
            ]
        ),
        .executableTarget(
            name: "iClawEnergyBench",
            path: "Sources/iClawEnergyBench",
            exclude: ["Resources/Info.plist", "Resources/EnergyBench.entitlements"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/iClawEnergyBench/Resources/Info.plist"
                ])
            ]
        ),
        .executableTarget(
            name: "iClawCLI",
            dependencies: ["iClawCore"],
            path: "Sources/iClawCLI",
            exclude: ["Info.plist", "iClawCLI.entitlements"]
        ),
        .testTarget(
            name: "iClawTests",
            dependencies: [
                "iClawCore",
                .product(name: "Replay", package: "Replay"),
            ],
            path: "Tests/iClawTests",
            exclude: ["CreateToolTests.swift.disabled"],
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
