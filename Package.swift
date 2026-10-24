// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VCode",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "VCode", targets: ["VCode"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.0")],
    targets: [
        .executableTarget(name: "VCode", dependencies: [.product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "VCodeTests", dependencies: ["VCode"], path: "tests/VCodeTests")
    ]
)
