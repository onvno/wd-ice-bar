// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TopShelfLite",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TopShelfLite", targets: ["TopShelfLite"]),
    ],
    targets: [
        .executableTarget(
            name: "TopShelfLite",
            path: "Sources/TopShelfLite"
        ),
    ]
)
