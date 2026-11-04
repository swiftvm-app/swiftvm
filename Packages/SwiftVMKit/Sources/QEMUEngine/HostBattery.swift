import Foundation
import IOKit.ps

/// Only the Mac's internal battery, not a UPS or a battery in an attached accessory.
struct HostBattery: Equatable, Sendable {
    var percentage: Int
    var isOnAC: Bool
    var isCharging: Bool

    /// The atomic status word understood by `qemu-battery.patch`. Zero means no battery.
    var status: UInt32 {
        UInt32(percentage) | 0x100 | (isOnAC ? 0x200 : 0) | (isCharging ? 0x400 : 0)
    }

    init?(description: [String: Any]) {
        guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              description[kIOPSIsPresentKey] as? Bool == true,
              let current = description[kIOPSCurrentCapacityKey] as? Int, current >= 0,
              let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0,
              let source = description[kIOPSPowerSourceStateKey] as? String,
              source == kIOPSACPowerValue || source == kIOPSBatteryPowerValue
        else { return nil }
        percentage = Int(min(100, (Double(current) * 100 / Double(maximum)).rounded(.down)))
        isOnAC = source == kIOPSACPowerValue
        isCharging = isOnAC && description[kIOPSIsChargingKey] as? Bool == true
    }

    static func read() -> HostBattery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            if let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
               let battery = HostBattery(description: description) {
                return battery
            }
        }
        return nil
    }
}

/// Feeds QEMU while it is alive, also while paused. A restored machine gets today's battery, not
/// the one it was saved with. Older or custom QEMU builds without the device are left alone.
@MainActor
final class QEMUBattery {
    private let read: () -> HostBattery?
    private let execute: (String, [String: QMPValue]) async throws -> QMPValue
    private var lastStatus: UInt32?
    private var isEnabled = false
    private var isRefreshing = false
    private var watch: Task<Void, Never>?

    init(
        read: @escaping () -> HostBattery? = HostBattery.read,
        execute: @escaping (String, [String: QMPValue]) async throws -> QMPValue
    ) {
        self.read = read
        self.execute = execute
    }

    deinit { watch?.cancel() }

    func start() async {
        let properties = try? await execute("qom-list", ["path": "/machine"])
        guard properties?.array?.contains(where: { $0["name"]?.string == "battery-status" }) == true else { return }
        isEnabled = true
        await refresh()
        guard isEnabled else { return }
        watch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    func stop() {
        isEnabled = false
        watch?.cancel()
        watch = nil
    }

    func refresh() async {
        guard isEnabled, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let status = read()?.status ?? 0
        guard status != lastStatus else { return }
        do {
            _ = try await execute("qom-set", ["path": "/machine", "property": "battery-status", "value": .number(Double(status))])
            lastStatus = status
        } catch {
            // Keep the last acknowledged state so a temporary failure is retried.
        }
    }
}
