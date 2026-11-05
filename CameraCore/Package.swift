// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CameraCore",
    products: [.library(name: "CameraCore", targets: ["CameraCore"])],
    targets: [
        .target(name: "CameraCore"),
        .testTarget(name: "CameraCoreTests", dependencies: ["CameraCore"])
    ]
)
