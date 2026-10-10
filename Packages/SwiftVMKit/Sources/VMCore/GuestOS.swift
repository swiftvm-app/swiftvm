import Foundation

/// The operating system family a virtual machine runs.
public enum GuestFamily: String, Codable, Sendable, CaseIterable, Hashable {
    case macOS
    case linux
    case windows

    public var displayName: String {
        switch self {
        case .macOS: "macOS"
        case .linux: "Linux"
        case .windows: "Windows"
        }
    }
}

/// The virtualization engine that runs a machine.
public enum VMEngineKind: String, Codable, Sendable, Hashable {
    /// Apple Virtualization.framework (macOS and Linux guests).
    case virtualization
    /// Bundled QEMU + Hypervisor.framework helper (Windows guests).
    case qemu

    public static func `default`(for family: GuestFamily) -> VMEngineKind {
        switch family {
        case .macOS, .linux: .virtualization
        case .windows: .qemu
        }
    }
}

/// What is known about the guest operating system.
public struct GuestOS: Codable, Sendable, Hashable {
    public var family: GuestFamily
    /// Distribution identifier for Linux guests, e.g. `ubuntu` or `fedora`.
    public var distribution: String?
    /// Human-readable product name including version, e.g. `Ubuntu 26.04.1 LTS` or `macOS 27.0.1`.
    public var productName: String?
    /// Build identifier, e.g. `26A434` for macOS or `25H2` for Windows.
    public var build: String?

    public init(family: GuestFamily, distribution: String? = nil, productName: String? = nil, build: String? = nil) {
        self.family = family
        self.distribution = distribution
        self.productName = productName
        self.build = build
    }

    /// One-line description such as `macOS 27.0.1 (26A434)`.
    public var summary: String {
        let name = productName ?? family.displayName
        if let build, !build.isEmpty {
            return "\(name) (\(build))"
        }
        return name
    }
}
