// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Notchd",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Notchd", path: "Sources/Notchd"),
        .testTarget(name: "NotchdTests", dependencies: ["Notchd"], path: "Tests/NotchdTests"),
    ]
)
