// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CameraCore",
    platforms: [.iOS("27.0"), .macOS("26.0")],
    products: [.library(name: "CameraCore", targets: ["CameraCore"])],
    targets: [
        .target(name: "CameraCore"),
        .testTarget(name: "CameraCoreTests", dependencies: ["CameraCore"])
    ]
)
