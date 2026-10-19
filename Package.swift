// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Canopy",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Canopy", targets: ["CanopyApp"])],
    targets: [
        .target(name: "CanopyCore"),
        .executableTarget(name: "CanopyApp", dependencies: ["CanopyCore"]),
        .testTarget(name: "CanopyCoreTests", dependencies: ["CanopyCore"]),
        .testTarget(name: "CanopyAppTests", dependencies: ["CanopyApp", "CanopyCore"])
    ],
    swiftLanguageVersions: [.v5]
)
