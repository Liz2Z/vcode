// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VCode",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "VCode", targets: ["VCode"])],
    targets: [
        .executableTarget(name: "VCode"),
        .testTarget(name: "VCodeTests", dependencies: ["VCode"], path: "tests/VCodeTests")
    ]
)
