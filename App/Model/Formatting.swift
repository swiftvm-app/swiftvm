import Foundation
import VMCore

/// Text formatting shared by the menu bar panel and the machine windows.
enum Formatting {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter
    }()

    /// A size such as `7.47 GB`, `135.1 MB` or `Zero KB`.
    static func bytes(_ value: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(clamping: value))
    }

    /// `4 CPU · 8 GB RAM`
    static func hardware(of configuration: VMConfiguration) -> String {
        "\(configuration.cpuCount) CPU · \(bytes(configuration.memorySize)) RAM"
    }

    /// `4 CPU · 8 GB RAM · 7.47 GB of 1 TB · macOS 27.0.1 (26A434)`
    static func summary(of machine: VirtualMachine) -> String {
        let configuration = machine.configuration
        var parts = [hardware(of: configuration)]
        if configuration.totalDiskCapacity > 0 {
            parts.append("\(bytes(machine.allocatedDiskSize)) of \(bytes(configuration.totalDiskCapacity))")
        }
        parts.append(configuration.os.summary)
        return parts.joined(separator: " · ")
    }
}

extension VMState {
    /// Short description for accessibility and tooltips.
    var label: String {
        switch self {
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .running: "Running"
        case .paused: "Paused"
        case .suspending: "Suspending"
        case .suspended: "Suspended"
        case .restoring: "Resuming"
        case .stopping: "Shutting Down"
        }
    }
}
