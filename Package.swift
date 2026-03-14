// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "macrobo",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0")
    ],
    targets: [
        .target(
            name: "MacroboLib",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .executableTarget(
            name: "macrobo",
            dependencies: ["MacroboLib"]
        ),
        .testTarget(
            name: "macroboTests",
            dependencies: ["MacroboLib"]
        )
    ]
)
