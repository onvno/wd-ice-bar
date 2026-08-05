// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "wd-ice-bar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "wd-ice-bar", targets: ["WDIceBar"]),
    ],
    targets: [
        .executableTarget(
            name: "WDIceBar",
            path: "Sources/WDIceBar"
        ),
    ]
)
