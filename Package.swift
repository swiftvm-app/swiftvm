// swift-tools-version: 6.2
import PackageDescription

// The app. `swift run SwiftVM` builds it and opens a development copy; `scripts/build.sh` builds the app
// itself. Either way the product is only the app's program: `scripts/bundle-app.sh` makes an app of it.
//
// The `swiftvm` tool and the guest agent are built from `Packages/SwiftVMKit` in a build folder of their
// own. Products of one build share a folder, and on a disk that doesn't tell upper case from lower,
// `swiftvm` and `SwiftVM` would be one file.
let package = Package(
    name: "SwiftVM",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "SwiftVM", targets: ["SwiftVM"]),
    ],
    dependencies: [
        .package(path: "Packages/SwiftVMKit"),
    ],
    targets: [
        .executableTarget(
            name: "SwiftVM",
            dependencies: [
                .product(name: "VMCore", package: "SwiftVMKit"),
                .product(name: "VZEngine", package: "SwiftVMKit"),
                .product(name: "VMNetworking", package: "SwiftVMKit"),
                .product(name: "SSHIntegration", package: "SwiftVMKit"),
                .product(name: "DiskTools", package: "SwiftVMKit"),
                .product(name: "Installers", package: "SwiftVMKit"),
                .product(name: "VMControl", package: "SwiftVMKit"),
            ],
            path: "App",
            // Compiled by `scripts/bundle-app.sh`: the app's icon has to be in the app itself, not in
            // the bundle that a package's resources go to.
            exclude: ["AppIcon.icon", "Assets.xcassets"],
            swiftSettings: [
                // The app's code runs on the main actor unless it says otherwise.
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]
        ),
        .testTarget(
            name: "SwiftVMTests",
            dependencies: [
                "SwiftVM",
                .product(name: "VMCore", package: "SwiftVMKit"),
            ]
        ),
    ]
)
