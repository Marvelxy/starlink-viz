// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StarlinkViz",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "StarlinkViz", targets: ["StarlinkViz"])
    ],
    targets: [
        .executableTarget(
            name: "StarlinkViz",
            path: "Sources/StarlinkViz"
        )
    ]
)
