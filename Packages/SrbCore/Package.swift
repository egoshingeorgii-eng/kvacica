// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SrbCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "SrbCore", targets: ["SrbCore"]),
        .executable(name: "srpski-mcp", targets: ["SrpskiMCP"]),
    ],
    dependencies: [
        // FSRS-6 support (configurable learning steps) is on main but not in a tagged release yet.
        .package(
            url: "https://github.com/open-spaced-repetition/swift-fsrs",
            revision: "4fbaf20184d62f82a9f44f343337c61a2c5483e9"
        ),
    ],
    targets: [
        .target(
            name: "SrbCore",
            dependencies: [.product(name: "FSRS", package: "swift-fsrs")]
        ),
        .executableTarget(name: "SrpskiMCP", dependencies: ["SrbCore"]),
        .testTarget(name: "SrbCoreTests", dependencies: ["SrbCore"]),
    ],
    swiftLanguageModes: [.v5]
)
