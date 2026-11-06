// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DshCore",
    platforms: [
        .iOS(.v17), .macOS(.v14)
    ],
    products: [
        .library(name: "DshCore", targets: ["DshCore"])
    ],
    dependencies: [
        // SSH client (auth, exec, direct-tcpip local forwarding).
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.12.1"),
    ],
    targets: [
        .target(name: "DshCore", dependencies: [
            .product(name: "Citadel", package: "Citadel")
        ]),
        .testTarget(name: "DshCoreTests", dependencies: ["DshCore"]),
        // End-to-end probe against a local `dsh web` (smoke, not unit-tested):
        // swift run DshProbe
        .executableTarget(name: "DshProbe", dependencies: ["DshCore"]),
    ]
)
