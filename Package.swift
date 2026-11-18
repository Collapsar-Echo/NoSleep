// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NoSleep",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "NoSleep",
            targets: ["NoSleep"]
        )
    ],
    targets: [
        .executableTarget(
            name: "NoSleep",
            path: "NoSleep",
            exclude: [
                "Info.plist",
                "NoSleep.entitlements"
            ],
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        .testTarget(
            name: "NoSleepTests",
            dependencies: ["NoSleep"],
            path: "Tests/NoSleepTests"
        )
    ]
)
