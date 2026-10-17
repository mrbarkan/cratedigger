// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CrateDigger",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "CrateDiggerCore", targets: ["CrateDiggerCore"]),
        .executable(name: "CrateDiggerApp", targets: ["CrateDiggerApp"]),
        .executable(name: "CrateDiggerMCP", targets: ["CrateDiggerMCP"])
    ],
    dependencies: [
        // In-app updates. The only third-party dependency in the app: a safe
        // self-updater is signature verification, a privileged install and a
        // relaunch, and Sparkle is the one everybody's Mac already trusts.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")
    ],
    targets: [
        .target(
            name: "CrateDiggerCore",
            dependencies: ["AssistantKit"],
            path: "Sources/CrateDiggerCore"
        ),
        // The library assistant's protocol layer: MCP's JSON-RPC, the tool
        // catalogue, the unix-socket transport and the Claude Desktop config.
        // Foundation only, because the helper below links it and nothing else.
        .target(
            name: "AssistantKit",
            path: "Sources/AssistantKit"
        ),
        // The MCP server Claude Desktop launches (stdio). It answers the
        // handshake and the tool list itself and forwards each tool call to
        // the running app over AssistantKit's socket. Shipped in the bundle
        // at Contents/MacOS/CrateDiggerMCP by scripts/package-app.sh.
        .executableTarget(
            name: "CrateDiggerMCP",
            dependencies: ["AssistantKit"],
            path: "Sources/CrateDiggerMCP"
        ),
        .executableTarget(
            name: "CrateDiggerApp",
            dependencies: [
                "CrateDiggerCore",
                "NowPlayingFeed",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/CrateDiggerApp",
            resources: [
                // Starter album installed into the library on first run
                // (see LibraryViewModel+Onboarding.installStarterContentIfNeeded).
                .copy("Resources/StarterCrate"),
                // Built-in themes, shipped in the same .cdtheme/theme.json
                // format a 3rd-party theme uses (see ThemeLoaderService) —
                // dogfoods the format instead of special-casing the defaults.
                .copy("Resources/Themes"),
                // The app's own type — Inter, JetBrains Mono and Major Mono
                // Display, the faces CarbonFont names — registered at launch
                // by FontRegistrar, which also walks each bundled theme's own
                // Fonts/ folder (Llama '97 ships its pixel faces there, like a
                // third-party theme would). BundledFontTests keeps the two in
                // step.
                .copy("Resources/Fonts")
            ],
            linkerSettings: [
                // Sparkle.framework is embedded in Contents/Frameworks by
                // scripts/package-app.sh; SwiftPM only knows how to link it,
                // not where it lives inside a .app.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                // Stamp the SDK we actually build with. Xcode 27's Swift Build
                // links through clang with --sysroot and no SDKROOT, so clang
                // can't read the SDK version and ld recorded "sdk 13.0". SwiftUI
                // then ran in its macOS 13 compatibility mode, where a Button
                // never starts a `.draggable` drag: no browser row could be
                // dragged to a crate or playlist. The last -platform_version wins.
                // ponytail: hardcoded SDK version; package-app.sh fails the
                // build when it stops matching `xcrun --show-sdk-version`.
                .unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "macos",
                              "-Xlinker", "13.0", "-Xlinker", "27.0"])
            ]
        ),
        // What the app writes and the Now Playing widget reads: one Codable
        // record plus the app-group container it lives in. The widget is not
        // a SwiftPM target: WidgetKit only lists extensions built by Xcode, so
        // Packaging/CrateDiggerWidget/CrateDiggerWidget.xcodeproj compiles
        // Sources/CrateDiggerWidget and these same files directly.
        .target(
            name: "NowPlayingFeed",
            path: "Sources/NowPlayingFeed"
        ),
        .testTarget(
            name: "CrateDiggerCoreTests",
            dependencies: ["CrateDiggerCore", "NowPlayingFeed", "AssistantKit"],
            path: "Tests/CrateDiggerCoreTests",
            resources: [
                // Real captures used as golden inputs — e.g. the `.TOC.plist`
                // macOS wrote for an actual audio CD, so the disc-ID hashing is
                // pinned against a disc MusicBrainz genuinely resolves.
                .copy("Fixtures")
            ]
        ),
        .testTarget(
            name: "CrateDiggerAppTests",
            dependencies: ["CrateDiggerApp"],
            path: "Tests/CrateDiggerAppTests"
        )
    ]
)
