// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CameraCore",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [.library(name: "CameraCore", targets: ["CameraCore"])],
    targets: [
        .target(name: "CameraCore", resources: [.copy("Resources/Knowledge")]),
        .executableTarget(name: "LogitEval", dependencies: ["CameraCore"]),
        .testTarget(name: "CameraCoreTests", dependencies: ["CameraCore"])
    ]
)
