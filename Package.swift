// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CrateDigger",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "CrateDiggerCore", targets: ["CrateDiggerCore"]),
        .executable(name: "CrateDiggerApp", targets: ["CrateDiggerApp"])
    ],
    targets: [
        .target(
            name: "CrateDiggerCore",
            path: "Sources/CrateDiggerCore"
        ),
        .executableTarget(
            name: "CrateDiggerApp",
            dependencies: ["CrateDiggerCore"],
            path: "Sources/CrateDiggerApp",
            resources: [
                // Starter album installed into the library on first run
                // (see LibraryViewModel+Onboarding.installStarterContentIfNeeded).
                .copy("Resources/StarterCrate")
            ]
        ),
        .testTarget(
            name: "CrateDiggerCoreTests",
            dependencies: ["CrateDiggerCore"],
            path: "Tests/CrateDiggerCoreTests"
        ),
        .testTarget(
            name: "CrateDiggerAppTests",
            dependencies: ["CrateDiggerApp"],
            path: "Tests/CrateDiggerAppTests"
        )
    ]
)
