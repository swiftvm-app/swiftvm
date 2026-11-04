import Foundation
import IOKit.ps
import Testing
@testable import QEMUEngine

@Suite struct HostBatteryTests {
    private func description(current: Int = 37, maximum: Int = 100, onAC: Bool = false, charging: Bool = false) -> [String: Any] {
        [
            kIOPSTypeKey: kIOPSInternalBatteryType,
            kIOPSIsPresentKey: true,
            kIOPSCurrentCapacityKey: current,
            kIOPSMaxCapacityKey: maximum,
            kIOPSPowerSourceStateKey: onAC ? kIOPSACPowerValue : kIOPSBatteryPowerValue,
            kIOPSIsChargingKey: charging,
        ]
    }

    @Test func normalizesCapacityAndKeepsExternalPowerSeparateFromCharging() throws {
        let discharging = try #require(HostBattery(description: description(current: 1850, maximum: 5000)))
        #expect(discharging.status == 0x100 | 37)
        // Divide-then-multiply falls just below these exact percentages in binary floating point.
        for percentage in [29, 57, 58] {
            #expect(HostBattery(description: description(current: percentage))?.percentage == percentage)
        }
        let charging = try #require(HostBattery(description: description(onAC: true, charging: true)))
        #expect(charging.status == 0x700 | 37)
        // Optimized charging can stop below 100%, without unplugging the power adapter.
        let held = try #require(HostBattery(description: description(current: 80, onAC: true)))
        #expect(held.status == 0x300 | 80)
        #expect(HostBattery(description: description(current: 101))?.percentage == 100)
        #expect(HostBattery(description: description(current: 0))?.status == 0x100)
        #expect(HostBattery(description: description(charging: true))?.isCharging == false)
    }

    @Test func neverTurnsAnAccessoryOrInvalidReadingIntoAnEmptySystemBattery() {
        for key in [kIOPSTypeKey, kIOPSCurrentCapacityKey, kIOPSMaxCapacityKey, kIOPSPowerSourceStateKey] {
            var reading = description()
            reading.removeValue(forKey: key)
            #expect(HostBattery(description: reading) == nil)
        }
        #expect(HostBattery(description: description(maximum: 0)) == nil)
        #expect(HostBattery(description: description(current: -1)) == nil)
        var reading = description()
        reading[kIOPSTypeKey] = kIOPSUPSType
        #expect(HostBattery(description: reading) == nil)
        reading[kIOPSTypeKey] = kIOPSInternalBatteryType
        reading[kIOPSIsPresentKey] = false
        #expect(HostBattery(description: reading) == nil)
    }

    @Test @MainActor func sendsCurrentStateChangesAndRemovalButNotDuplicates() async {
        var reading = HostBattery(description: description())
        var sent: [Int] = []
        let battery = QEMUBattery(read: { reading }) { command, arguments in
            if command == "qom-list" { return [["name": "battery-status"]] }
            #expect(command == "qom-set")
            #expect(arguments["path"] == "/machine")
            #expect(arguments["property"] == "battery-status")
            sent.append(try #require(arguments["value"]?.int))
            return [:]
        }
        await battery.start()
        await battery.refresh()
        reading = HostBattery(description: description(onAC: true, charging: true))
        await battery.refresh()
        reading = nil
        await battery.refresh()
        #expect(sent == [0x100 | 37, 0x700 | 37, 0])
        battery.stop()
        reading = HostBattery(description: description())
        await battery.refresh()
        #expect(sent.count == 3)
    }

    @Test @MainActor func retriesFailedUpdatesAndReseedsANewRun() async {
        var attempts = 0
        let reading = HostBattery(description: description())
        let battery = QEMUBattery(read: { reading }) { command, _ in
            if command == "qom-list" { return [["name": "battery-status"]] }
            attempts += 1
            if attempts == 1 { throw QEMUError.disconnected }
            return [:]
        }
        defer { battery.stop() }
        await battery.start()
        await battery.refresh()
        await battery.refresh()
        #expect(attempts == 2)
        // A new backend makes a new feeder, including when resuming saved guest memory.
        let resumed = QEMUBattery(read: { reading }) { command, _ in
            if command == "qom-list" { return [["name": "battery-status"]] }
            attempts += 1
            return [:]
        }
        defer { resumed.stop() }
        await resumed.start()
        #expect(attempts == 3)
    }

    @Test @MainActor func anOlderQEMUIsNeverSentBatteryCommands() async {
        var calls: [String] = []
        let battery = QEMUBattery(read: { nil }) { command, _ in
            calls.append(command)
            return [["name": "unrelated-property"]]
        }
        await battery.start()
        await battery.refresh()
        battery.stop()
        #expect(calls == ["qom-list"])
    }
}
