// swift-tools-version: 6.0
import PackageDescription

// Lightweight build path for contributors. `swift build` / `swift run` works with just the
// Command Line Tools (`xcode-select --install`) — no full Xcode required. The release pipeline
// still uses MacColi.xcodeproj (asset catalog, code signing, notarization); see README.
let package = Package(
    name: "MacColi",
    platforms: [.macOS(.v14)],            // matches MACOSX_DEPLOYMENT_TARGET = 14.0
    targets: [
        .executableTarget(
            name: "MacColi",
            path: "MacColi",
            // Asset catalog compilation needs `actool`, which ships only inside Xcode.app.
            // It's cosmetic here (app icon + accent override); excluding it lets the build run
            // on Command Line Tools alone. Dev builds get a generic icon and the system accent.
            exclude: ["Assets.xcassets"]
        )
    ]
)
