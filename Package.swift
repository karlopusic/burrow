// swift-tools-version:5.9
import PackageDescription

// The .app bundle (Info.plist, icon, localizations, bundled rclone) is assembled by scripts/build.sh.
// This manifest exists so the project opens in Xcode / VS Code and `swift build` type-checks it.
let package = Package(
    name: "StorageBoxSync",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .executableTarget(
            name: "StorageBoxSync",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/StorageBoxSync"
        )
    ]
)
