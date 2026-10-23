// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "PhotoViewer",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "PhotoViewer", targets: ["PhotoViewer"])],
    targets: [
        .target(name: "PhotoCore"),
        .executableTarget(name: "PhotoViewer", dependencies: ["PhotoCore"]),
        .testTarget(name: "PhotoCoreTests", dependencies: ["PhotoCore"]),
        .testTarget(name: "PhotoViewerUITests", dependencies: ["PhotoViewer", "PhotoCore"])
    ]
)
