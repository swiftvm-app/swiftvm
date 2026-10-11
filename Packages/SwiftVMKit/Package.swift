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
        .library(name: "GuestChannel", targets: ["GuestChannel"]),
        .library(name: "GuestAgentMac", targets: ["GuestAgentMac"]),
        .executable(name: "swiftvm", targets: ["swiftvm"]),
        .executable(name: "swiftvm-agent", targets: ["swiftvm-agent"]),
    ],
    targets: [
        .target(name: "GuestChannel"),
        // The guest agent for macOS guests. It runs inside a virtual machine, not on the host.
        .target(name: "GuestAgentMac", dependencies: ["GuestChannel"]),
        .executableTarget(name: "swiftvm-agent", dependencies: ["GuestAgentMac"]),
        .target(name: "VMCore", dependencies: ["GuestChannel"]),
        .target(name: "DiskTools", dependencies: ["VMCore"]),
        .target(name: "VMNetworking", dependencies: ["VMCore"]),
        .target(name: "SSHIntegration", dependencies: ["VMCore"]),
        .target(
            name: "Installers",
            dependencies: ["VMCore", "DiskTools", "GuestChannel"],
            resources: [.process("Resources")]
        ),
        .target(name: "VZEngine", dependencies: ["VMCore", "VMNetworking", "DiskTools"]),
        .target(name: "VMControl"),
        .executableTarget(name: "swiftvm", dependencies: ["VMControl"]),
        .testTarget(name: "GuestChannelTests", dependencies: ["GuestChannel"]),
        .testTarget(name: "GuestAgentMacTests", dependencies: ["GuestAgentMac", "GuestChannel"]),
        .testTarget(name: "VMCoreTests", dependencies: ["VMCore", "GuestChannel"]),
        .testTarget(name: "DiskToolsTests", dependencies: ["DiskTools"]),
        .testTarget(name: "SSHIntegrationTests", dependencies: ["SSHIntegration"]),
        .testTarget(name: "InstallersTests", dependencies: ["Installers", "DiskTools", "GuestChannel"]),
        .testTarget(name: "VMNetworkingTests", dependencies: ["VMNetworking"]),
        .testTarget(name: "VMControlTests", dependencies: ["VMControl"]),
        .testTarget(name: "VZEngineTests", dependencies: ["VZEngine", "VMCore"]),
    ]
)
