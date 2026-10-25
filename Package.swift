// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "LogiBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LogiBar",
            path: "Sources/LogiBar",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("ServiceManagement")]
        )
    ]
)
