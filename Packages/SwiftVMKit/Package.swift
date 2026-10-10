// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SwiftVMKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "VMCore", targets: ["VMCore"]),
        .library(name: "VZEngine", targets: ["VZEngine"]),
        .library(name: "VMNetworking", targets: ["VMNetworking"]),
        .library(name: "SSHIntegration", targets: ["SSHIntegration"]),
        .library(name: "DiskTools", targets: ["DiskTools"]),
        .library(name: "Installers", targets: ["Installers"]),
        .library(name: "VMControl", targets: ["VMControl"]),
        .executable(name: "swiftvm", targets: ["swiftvm"]),
    ],
    targets: [
        .target(name: "VMCore"),
        .target(name: "DiskTools", dependencies: ["VMCore"]),
        .target(name: "VMNetworking", dependencies: ["VMCore"]),
        .target(name: "SSHIntegration", dependencies: ["VMCore"]),
        .target(
            name: "Installers",
            dependencies: ["VMCore", "DiskTools"],
            resources: [.process("Resources")]
        ),
        .target(name: "VZEngine", dependencies: ["VMCore", "VMNetworking", "DiskTools"]),
        .target(name: "VMControl"),
        .executableTarget(name: "swiftvm", dependencies: ["VMControl"]),
        .testTarget(name: "VMCoreTests", dependencies: ["VMCore"]),
        .testTarget(name: "DiskToolsTests", dependencies: ["DiskTools"]),
        .testTarget(name: "SSHIntegrationTests", dependencies: ["SSHIntegration"]),
        .testTarget(name: "InstallersTests", dependencies: ["Installers", "DiskTools"]),
        .testTarget(name: "VMNetworkingTests", dependencies: ["VMNetworking"]),
        .testTarget(name: "VMControlTests", dependencies: ["VMControl"]),
    ]
)
