// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MScan",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MScanCore", targets: ["MScanCore"]),
               .executable(name: "MScan", targets: ["MScan"])],
    targets: [
        .target(name: "MScanCore", resources: [.process("Resources")]),
        .executableTarget(name: "MScan", dependencies: ["MScanCore"]),
        .testTarget(name: "MScanCoreTests", dependencies: ["MScanCore"]),
        .testTarget(name: "MScanTests", dependencies: ["MScan", "MScanCore"])
    ]
)
