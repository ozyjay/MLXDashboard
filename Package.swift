// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MLXDashboard",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MLXCore", targets: ["MLXCore"]),
        .library(name: "MLXPythonBridge", targets: ["MLXPythonBridge"]),
        .library(name: "MLXServerControl", targets: ["MLXServerControl"]),
        .library(name: "MLXProviderServer", targets: ["MLXProviderServer"]),
        .executable(name: "MLXDashboard", targets: ["MLXDashboardApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.78.0")
    ],
    targets: [
        .target(
            name: "MLXCore",
            linkerSettings: [.linkedFramework("Security")]
        ),
        .target(
            name: "MLXPythonBridge",
            dependencies: ["MLXCore"]
        ),
        .target(
            name: "MLXServerControl",
            dependencies: ["MLXCore"]
        ),
        .target(
            name: "MLXProviderServer",
            dependencies: [
                "MLXCore",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio")
            ]
        ),
        .executableTarget(
            name: "MLXDashboardApp",
            dependencies: [
                "MLXCore",
                "MLXPythonBridge",
                "MLXServerControl",
                "MLXProviderServer"
            ]
        ),
        .testTarget(
            name: "MLXCoreTests",
            dependencies: ["MLXCore"]
        ),
        .testTarget(
            name: "MLXPythonBridgeTests",
            dependencies: ["MLXPythonBridge"]
        ),
        .testTarget(
            name: "MLXServerControlTests",
            dependencies: ["MLXServerControl"]
        ),
        .testTarget(
            name: "MLXProviderServerTests",
            dependencies: ["MLXProviderServer"]
        ),
        .testTarget(
            name: "MLXDashboardAppTests",
            dependencies: ["MLXDashboardApp"]
        )
    ]
)
