import AppKit
import Foundation
import Testing
@testable import VMCore

/// A backend that hands USB devices to a pretend guest, says what it was asked to do in which order, and
/// can fail on demand.
@MainActor
private final class USBBackend: VMBackend {
    var eventHandler: (@MainActor (VMBackendEvent) -> Void)?
    let displayView = NSView()
    let canRequestStop = true
    /// The devices the guest has.
    var devices: [USBDevice] = []
    /// What was asked for, in order.
    var log: [String] = []
    var attachError: (any Error)?
    var detachError: (any Error)?
    var saveError: (any Error)?
    /// Runs while a device is on its way to the guest, which waits for it.
    var whileAttaching: (() async -> Void)?

    func start(options: VMStartOptions) async throws { log.append(options.savedState == nil ? "start" : "restore") }
    func requestStop() throws {}
    func stop() async throws { log.append("stop") }
    func pause() async throws { log.append("pause") }
    func resume() async throws { log.append("resume") }
    func saveState(to url: URL) async throws {
        log.append("save")
        if let saveError { throw saveError }
        try Data("memory".utf8).write(to: url)
    }
    func setNetworkInterface(_ id: UUID, connected: Bool) throws {}
    func setSharedFolders(_ folders: [SharedFolder]) throws {}
    func attachRemovableImage(_ image: RemovableImage) async throws {}
    func detachRemovableImage(_ id: UUID) async throws {}
    func setCapturesSystemKeys(_ capturesSystemKeys: Bool) {}
    func connectToGuest(port: UInt32) async throws -> FileHandle { throw POSIXError(.ECONNRESET) }
    func invalidate() {}

    /// How many times a device was offered to the guest, whether it took it or not.
    var attachAttempts = 0

    func attachUSBDevice(_ device: USBDevice) async throws {
        attachAttempts += 1
        await whileAttaching?()
        if let attachError { throw attachError }
        devices.append(device)
        log.append("attach \(device.id)")
    }

    func detachUSBDevice(_ id: USBDevice.ID) async throws {
        if let detachError { throw detachError }
        devices.removeAll { $0.id == id }
        log.append("detach \(id)")
    }
}

@MainActor
private final class USBProvider: VMBackendProvider {
    let backend = USBBackend()

    func makeBackend(for machine: VirtualMachine, console: SerialConsole.GuestEnd) async throws -> any VMBackend { backend }
    func backendDidStop(for machine: VirtualMachine) {}
}

private struct Refusal: Error, LocalizedError {
    var errorDescription: String? { "The guest won't have it." }
}

/// Machines in a scratch folder, each with a pretend engine of its own.
@MainActor
private final class Scratch {
    let directory = FileManager.default.temporaryDirectory.appending(path: "swiftvm-tests-\(UUID().uuidString)")
    /// A machine only holds on to its provider loosely.
    private var providers: [USBProvider] = []

    func makeMachine(named name: String = "Box") throws -> (machine: VirtualMachine, backend: USBBackend) {
        let disk = DiskConfiguration(fileName: "disk.img", capacity: 1 << 20, format: .raw)
        let configuration = VMConfiguration(name: name, os: GuestOS(family: .linux), cpuCount: 2, memorySize: 4 << 30, disks: [disk])
        let bundle = try VMBundle.create(at: directory.appending(path: "\(UUID().uuidString).swiftvm"), configuration: configuration)
        try Data("disk".utf8).write(to: bundle.diskURL(for: disk))
        let machine = try VirtualMachine(bundle: bundle)
        let provider = USBProvider()
        providers.append(provider)
        machine.backendProvider = provider
        machine.isHostLocked = { false }
        return (machine, provider.backend)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Waits for something that happens in a task of its own.
@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<300 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

private let stick = USBDevice(id: 4_302_399_248, vendorID: 0x0781, productID: 0x5581, name: "Ultra", manufacturer: "SanDisk", serialNumber: "4C530001")
private let key = USBDevice(id: 4_302_399_301, vendorID: 0x1050, productID: 0x0407, name: "YubiKey OTP+FIDO+CCID")

@Suite struct USBDeviceTests {
    @Test func readsADevicesNumbersFromItsDescriptor() {
        // What a SanDisk stick hands over: 18 bytes, a device descriptor, USB 3.2, the class left to
        // its interfaces, vendor 0781, product 5581.
        let bytes: [UInt8] = [18, 1, 0x20, 0x03, 0, 0, 0, 9, 0x81, 0x07, 0x81, 0x55, 0x00, 0x01, 1, 2, 3, 1]
        let descriptor = USBDeviceDescriptor(Data(bytes))
        #expect(descriptor?.vendorID == 0x0781)
        #expect(descriptor?.productID == 0x5581)
        #expect(descriptor?.deviceClass == 0)

        // More than the 18 bytes is fine; fewer, or another kind of descriptor, is not one.
        #expect(USBDeviceDescriptor(Data(bytes + [9, 2])) == descriptor)
        #expect(USBDeviceDescriptor(Data(bytes.dropLast())) == nil)
        #expect(USBDeviceDescriptor(Data([18, 2] + bytes.dropFirst(2))) == nil)
        #expect(USBDeviceDescriptor(Data()) == nil)
    }

    @Test func aDeviceIsCalledWhatItCallsItself() {
        let padded = USBDevice(id: 1, vendorID: 0x05e3, productID: 0x0751, name: "USB Storage  \0", manufacturer: " Genesys ", serialNumber: "   ")
        #expect(padded.name == "USB Storage")
        #expect(padded.manufacturer == "Genesys")
        #expect(padded.serialNumber == nil)
        #expect(padded.identifier == "05e3:0751")

        // One that says nothing is called by its numbers.
        #expect(USBDevice(id: 2, vendorID: 0x05e3, productID: 0x0751, name: " ").name == "USB Device 05e3:0751")
        #expect(USBDevice(id: 3, vendorID: 0, productID: 0xa).name == "USB Device 0000:000a")
    }

    @Test func findsTheDeviceSomeoneMeans() {
        let twin = USBDevice(id: 7, vendorID: stick.vendorID, productID: stick.productID, name: "Ultra", serialNumber: "4C530002")
        let devices = [stick, key, twin]
        #expect(devices.matching("4302399301") == [key])
        #expect(devices.matching("1050:0407") == [key])
        #expect(devices.matching(" yubikey otp+fido+ccid ") == [key])
        #expect(devices.matching("4c530002") == [twin])
        // Two of a make go by one name and one pair of numbers.
        #expect(devices.matching("0781:5581") == [stick, twin])
        #expect(devices.matching("Ultra") == [stick, twin])
        // The maker's name in front, as on the box.
        #expect(devices.matching("SanDisk Ultra") == [stick])
        #expect(devices.matching("7") == [twin])
        #expect(devices.matching("Cruzer").isEmpty)
        #expect(devices.matching("").isEmpty)
    }

    @Test func aMachineRemembersTheMakeOfADeviceItTakesByItself() throws {
        var configuration = USBConfiguration()
        #expect(!configuration.connectsAutomatically(stick))

        configuration.setConnectsAutomatically(true, for: stick)
        configuration.setConnectsAutomatically(true, for: stick)
        #expect(configuration.autoConnect == [.init(vendorID: 0x0781, productID: 0x5581, name: "Ultra")])
        #expect(configuration.autoConnect.first?.id == "0781:5581")
        // The same stick plugged in again has another number, and so has its twin.
        #expect(configuration.connectsAutomatically(USBDevice(id: 99, vendorID: 0x0781, productID: 0x5581)))
        #expect(!configuration.connectsAutomatically(key))
        #expect(try JSONDecoder().decode(USBConfiguration.self, from: JSONEncoder().encode(configuration)) == configuration)

        configuration.setConnectsAutomatically(false, for: stick)
        #expect(configuration.autoConnect.isEmpty)
    }

    @Test func whichDevicesAMachineTakesIsThisMacsToSay() {
        var original = VMConfiguration(name: "Box", os: GuestOS(family: .linux), cpuCount: 2, memorySize: 4 << 30, disks: [])
        original.usb.setConnectsAutomatically(true, for: stick)

        // A copy takes none by itself: a device can only be with one guest.
        #expect(original.duplicated(name: "Box copy", sshAlias: "box-copy").usb.autoConnect.isEmpty)

        // Going back to a snapshot brings back the hardware of the time, not what was decided since
        // about this Mac's devices.
        var now = original
        now.usb.setConnectsAutomatically(false, for: stick)
        now.usb.setConnectsAutomatically(true, for: key)
        for includesMemory in [false, true] {
            let snapshot = VMSnapshot(name: "Then", includesMemory: includesMemory, configuration: original)
            #expect(now.reverted(to: snapshot).usb.autoConnect.map(\.id) == ["1050:0407"])
        }
    }
}

@MainActor
@Suite struct USBDeviceMachineTests {
    private let scratch = Scratch()

    @Test func onlyARunningGuestTakesADevice() async throws {
        defer { scratch.cleanUp() }
        let (machine, backend) = try scratch.makeMachine()
        await #expect(throws: VMError.self) { try await machine.attachUSBDevice(stick) }
        #expect(machine.usbDevices.isEmpty)

        await machine.start()
        try await machine.attachUSBDevice(stick)
        try await machine.attachUSBDevice(key)
        // Asked a second time, there is nothing to do.
        try await machine.attachUSBDevice(stick)
        #expect(machine.usbDevices == [stick, key])
        #expect(backend.devices == [stick, key])
        // None of it is written down: a device is the guest's while it runs.
        #expect(try machine.bundle.loadConfiguration() == machine.configuration)

        await machine.pause()
        let refusal = await #expect(throws: VMError.self) { try await machine.attachUSBDevice(USBDevice(id: 3, vendorID: 1, productID: 2)) }
        #expect(refusal?.localizedDescription.contains("is paused") == true)
        // A paused guest can still give one back.
        try await machine.detachUSBDevice(key.id)
        #expect(machine.usbDevices == [stick])
        await machine.forceStop()
    }

    @Test func aGuestGivesADeviceBack() async throws {
        defer { scratch.cleanUp() }
        let (machine, backend) = try scratch.makeMachine()
        await machine.start()
        try await machine.attachUSBDevice(stick)

        try await machine.detachUSBDevice(stick.id)
        #expect(machine.usbDevices.isEmpty)
        #expect(backend.devices.isEmpty)
        // One it doesn't have is nothing to give back.
        try await machine.detachUSBDevice(key.id)
        #expect(backend.log == ["start", "attach \(stick.id)", "detach \(stick.id)"])

        // A device that won't go stays where it is, and is said to.
        try await machine.attachUSBDevice(key)
        backend.detachError = Refusal()
        await #expect(throws: Refusal.self) { try await machine.detachUSBDevice(key.id) }
        #expect(machine.usbDevices == [key])
        await machine.forceStop()
    }

    @Test func aDeviceTheGuestRefusesIsNotItsOwn() async throws {
        defer { scratch.cleanUp() }
        let (machine, backend) = try scratch.makeMachine()
        await machine.start()
        backend.attachError = Refusal()
        await #expect(throws: Refusal.self) { try await machine.attachUSBDevice(stick) }
        #expect(machine.usbDevices.isEmpty)
        await machine.forceStop()
    }

    @Test func aMachineThatStopsHoldsNoDevice() async throws {
        defer { scratch.cleanUp() }
        let (machine, backend) = try scratch.makeMachine()
        await machine.start()
        try await machine.attachUSBDevice(stick)

        await machine.forceStop()
        #expect(machine.usbDevices.isEmpty)

        // Nor does one whose guest shut itself down.
        await machine.start()
        try await machine.attachUSBDevice(stick)
        backend.eventHandler?(.guestDidStop)
        #expect(machine.state == .stopped)
        #expect(machine.usbDevices.isEmpty)
    }

    @Test func aGuestThatStopsWhileADeviceIsOnItsWayDoesNotGetIt() async throws {
        defer { scratch.cleanUp() }
        let (machine, backend) = try scratch.makeMachine()
        await machine.start()
        backend.whileAttaching = { backend.eventHandler?(.guestDidStop) }
        await #expect(throws: VMError.self) { try await machine.attachUSBDevice(stick) }
        #expect(machine.state == .stopped)
        #expect(machine.usbDevices.isEmpty)
    }

    @Test func aDeviceThatIsPulledOutIsGoneWithoutAComplaint() async throws {
        defer { scratch.cleanUp() }
        let (machine, backend) = try scratch.makeMachine()
        await machine.start()
        try await machine.attachUSBDevice(stick)
        try await machine.attachUSBDevice(key)

        // The engine says so.
        backend.eventHandler?(.usbDeviceDisconnected(stick.id))
        #expect(machine.usbDevices == [key])
        #expect(machine.lastError == nil)
        #expect(machine.state == .running)

        // The host says so, perhaps first, perhaps alone: the guest's list follows at once, and the
        // engine is told to let go of what it still holds.
        machine.usbDeviceDidDisappear(key.id)
        #expect(machine.usbDevices.isEmpty)
        #expect(await eventually { backend.log.last == "detach \(key.id)" })
        machine.usbDeviceDidDisappear(key.id)
        await machine.forceStop()
    }

    @Test func aSuspendedGuestComesBackWithoutItsDevices() async throws {
        defer { scratch.cleanUp() }
        let (machine, backend) = try scratch.makeMachine()
        await machine.start()
        try await machine.attachUSBDevice(stick)
        try await machine.attachUSBDevice(key)

        await machine.suspend()
        #expect(machine.state == .suspended)
        #expect(machine.lastError == nil)
        #expect(machine.usbDevices.isEmpty)
        // Nothing is taken from the guest before it is safely away: its devices go with the machine.
        #expect(backend.log == ["start", "attach \(stick.id)", "attach \(key.id)", "pause", "save", "stop"])

        // It comes back without them. Who takes which device then is for the app to say.
        var starts = 0
        machine.onGuestStart = { _ in starts += 1 }
        await machine.start()
        #expect(machine.state == .running)
        #expect(machine.usbDevices.isEmpty)
        #expect(starts == 1)
        await machine.forceStop()
    }

    @Test func aSuspendThatFailsCostsTheGuestNoDevice() async throws {
        defer { scratch.cleanUp() }
        let (machine, backend) = try scratch.makeMachine()
        await machine.start()
        try await machine.attachUSBDevice(stick)

        backend.saveError = Refusal()
        await machine.suspend()
        #expect(machine.state == .running)
        #expect(machine.lastError?.title == "Couldn't suspend “Box”")
        #expect(machine.usbDevices == [stick])
        #expect(backend.devices == [stick])
        await machine.forceStop()
    }

    @Test func aRunningGuestWithADeviceIsNotSnapshotted() async throws {
        defer { scratch.cleanUp() }
        let (machine, backend) = try scratch.makeMachine()
        await machine.start()
        try await machine.attachUSBDevice(stick)

        let refusal = await #expect(throws: VMError.self) { try await machine.takeSnapshot() }
        #expect(refusal?.localizedDescription.contains("“Ultra”") == true)
        #expect(refusal?.localizedDescription.contains("snapshot can't cover") == true)
        // The guest carries on with its device, none the wiser.
        #expect(machine.state == .running)
        #expect(machine.activity == nil)
        #expect(machine.usbDevices == [stick])
        #expect(machine.snapshots.isEmpty)
        #expect(!backend.log.contains("pause"))

        // Without it, or shut down, there is nothing in the way.
        try await machine.detachUSBDevice(stick.id)
        var starts = 0
        machine.onGuestStart = { _ in starts += 1 }
        #expect(try await machine.takeSnapshot().includesMemory)
        // The guest carries on where it was. It hasn't come up, as far as anyone waiting for that goes.
        #expect(machine.state == .running)
        #expect(starts == 0)
        await machine.forceStop()
    }

    @Test func aSnapshotWaitsForADeviceThatIsOnItsWay() async throws {
        defer { scratch.cleanUp() }
        let (machine, backend) = try scratch.makeMachine()
        await machine.start()

        // The device isn't on the guest's list yet, and the snapshot goes by that list.
        var arrival: CheckedContinuation<Void, Never>?
        backend.whileAttaching = { await withCheckedContinuation { arrival = $0 } }
        let attaching = Task { try await machine.attachUSBDevice(stick) }
        #expect(await eventually { arrival != nil })
        await #expect(throws: VMError.self) { try await machine.takeSnapshot() }
        #expect(machine.state == .running)
        #expect(machine.activity == nil)

        arrival?.resume()
        try await attaching.value
        #expect(machine.usbDevices == [stick])
        await machine.forceStop()
    }

    @Test func theLibraryPassesOnThatAGuestHasComeUp() async throws {
        defer { scratch.cleanUp() }
        let provider = USBProvider()
        let library = VMLibrary(rootDirectory: scratch.directory.appending(path: "Library"))
        library.backendProvider = provider
        let configuration = VMConfiguration(name: "Listed", os: GuestOS(family: .linux), cpuCount: 2, memorySize: 4 << 30, disks: [])
        let listed = try library.add(VMBundle.create(at: scratch.directory.appending(path: "Listed.swiftvm"), configuration: configuration))
        listed.isHostLocked = { false }

        var started: [UUID] = []
        library.onMachineStart = { started.append($0.id) }
        await listed.start()
        #expect(started == [listed.id])
        // Also when it comes back from being suspended.
        await listed.suspend()
        await listed.start()
        #expect(started == [listed.id, listed.id])
        await listed.forceStop()
    }
}

@MainActor
@Suite struct USBPassthroughTests {
    private let scratch = Scratch()

    /// A coordinator that has been told it may, with these machines to hand devices to.
    private func makePassthrough(_ machines: [VirtualMachine]) -> USBPassthrough {
        let usb = USBPassthrough()
        usb.availability = .available
        usb.settlingTime = .milliseconds(100)
        usb.machines = { machines }
        for machine in machines {
            machine.onGuestStart = { usb.machineDidStart($0) }
        }
        return usb
    }

    @Test func aCopyThatMayNotSaysWhy() async throws {
        defer { scratch.cleanUp() }
        let (machine, backend) = try scratch.makeMachine()
        await machine.start()
        let usb = makePassthrough([machine])
        usb.deviceDidConnect(stick)

        for (availability, words) in [
            (USBPassthrough.Availability.notSigned, "provisioning profile"),
            (.failed("Unable to communicate with service."), "Unable to communicate with service."),
            (.starting, "still finding out"),
        ] {
            usb.availability = availability
            let refusal = await #expect(throws: USBPassthrough.Failure.self) { try await usb.attach(stick, to: machine) }
            #expect(refusal == .unavailable(availability))
            #expect(refusal?.localizedDescription.contains(words) == true)
        }
        #expect(backend.devices.isEmpty)
        await machine.forceStop()
    }

    @Test func aDeviceIsWithOneGuestAtATime() async throws {
        defer { scratch.cleanUp() }
        let (first, firstBackend) = try scratch.makeMachine(named: "First")
        let (second, secondBackend) = try scratch.makeMachine(named: "Second")
        await first.start()
        await second.start()
        let usb = makePassthrough([first, second])
        usb.deviceDidConnect(stick)
        #expect(usb.devices == [stick])
        #expect(usb.holder(of: stick.id) == nil)

        try await usb.attach(stick, to: first)
        #expect(usb.holder(of: stick.id)?.id == first.id)
        // Asked again for the guest that has it, there is nothing to do.
        try await usb.attach(stick, to: first)
        #expect(firstBackend.log.filter { $0.hasPrefix("attach") }.count == 1)

        let refusal = await #expect(throws: USBPassthrough.Failure.self) { try await usb.attach(stick, to: second) }
        #expect(refusal == .inUse(device: "Ultra", by: "First"))
        #expect(secondBackend.devices.isEmpty)

        try await usb.detach(stick, from: first)
        try await usb.attach(stick, to: second)
        #expect(usb.holder(of: stick.id)?.id == second.id)

        // A machine that stops has let go of it.
        await second.forceStop()
        #expect(usb.holder(of: stick.id) == nil)
        await first.forceStop()
    }

    @Test func aDeviceThatHasGoneCanNotBeHandedOver() async throws {
        defer { scratch.cleanUp() }
        let (machine, backend) = try scratch.makeMachine()
        await machine.start()
        let usb = makePassthrough([machine])
        usb.deviceDidConnect(stick)
        usb.deviceDidDisconnect(stick.id)
        #expect(usb.devices.isEmpty)

        let refusal = await #expect(throws: USBPassthrough.Failure.self) { try await usb.attach(stick, to: machine) }
        #expect(refusal == .gone(device: "Ultra"))
        #expect(backend.devices.isEmpty)
        await machine.forceStop()
    }

    @Test func aDeviceThatGoesIsOffItsGuestsListToo() async throws {
        defer { scratch.cleanUp() }
        let (machine, _) = try scratch.makeMachine()
        await machine.start()
        let usb = makePassthrough([machine])
        usb.deviceDidConnect(stick)
        usb.deviceDidConnect(key)
        try await usb.attach(stick, to: machine)

        usb.deviceDidDisconnect(stick.id)
        #expect(usb.devices == [key])
        #expect(machine.usbDevices.isEmpty)
        // A device that is reported twice is one device.
        usb.deviceDidConnect(key)
        #expect(usb.devices == [key])
        await machine.forceStop()
    }

    @Test func aMachineTakesItsDeviceWhenItIsPluggedIn() async throws {
        defer { scratch.cleanUp() }
        let (machine, backend) = try scratch.makeMachine()
        let usb = makePassthrough([machine])
        try usb.setConnectsAutomatically(true, stick, to: machine)
        #expect(try machine.bundle.loadConfiguration().usb.autoConnect.map(\.id) == ["0781:5581"])

        // While the machine is shut down, the device stays with this Mac's app.
        usb.deviceDidConnect(stick)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(usb.holder(of: stick.id) == nil)

        // It takes what is there when it starts,
        await machine.start()
        #expect(await eventually { machine.usbDevices == [stick] })
        // and, running, what is plugged in: the same stick again, under its new number.
        usb.deviceDidDisconnect(stick.id)
        let again = USBDevice(id: stick.id + 1, vendorID: stick.vendorID, productID: stick.productID, name: stick.name, serialNumber: stick.serialNumber)
        usb.deviceDidConnect(again)
        #expect(await eventually { machine.usbDevices == [again] })
        // A device it has no rule for is left alone.
        usb.deviceDidConnect(key)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(backend.devices == [again])
        await machine.forceStop()
    }

    @Test func theFirstRunningMachineThatWantsADeviceGetsIt() async throws {
        defer { scratch.cleanUp() }
        let (stopped, _) = try scratch.makeMachine(named: "Stopped")
        let (first, _) = try scratch.makeMachine(named: "First")
        let (second, secondBackend) = try scratch.makeMachine(named: "Second")
        let usb = makePassthrough([stopped, first, second])
        for machine in [stopped, first, second] {
            try usb.setConnectsAutomatically(true, stick, to: machine)
        }
        await first.start()
        await second.start()

        usb.deviceDidConnect(stick)
        #expect(await eventually { first.usbDevices == [stick] })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(secondBackend.devices.isEmpty)
        #expect(first.lastError == nil && second.lastError == nil)
        await first.forceStop()
        await second.forceStop()
    }

    /// The stick as it shows up the next time: the same device under another number.
    private func stickAgain(_ times: UInt64) -> USBDevice {
        USBDevice(id: stick.id + times, vendorID: stick.vendorID, productID: stick.productID, name: stick.name, manufacturer: stick.manufacturer, serialNumber: stick.serialNumber)
    }

    @Test func aDeviceDetachedByHandIsLeftAloneWhenItComesBack() async throws {
        defer { scratch.cleanUp() }
        let (machine, backend) = try scratch.makeMachine()
        await machine.start()
        let usb = makePassthrough([machine])
        usb.deviceDidConnect(stick)
        try usb.setConnectsAutomatically(true, stick, to: machine)
        #expect(await eventually { machine.usbDevices == [stick] })

        // Given back, the device shows up on this Mac as if it had just been plugged in. Giving it back
        // is over when it has.
        let givingBack = Task { try await usb.detach(stick, from: machine) }
        #expect(await eventually { backend.devices.isEmpty })
        usb.deviceDidDisconnect(stick.id)
        usb.deviceDidConnect(stickAgain(1))
        try await givingBack.value
        try? await Task.sleep(for: .milliseconds(50))
        #expect(usb.devices == [stickAgain(1)])
        #expect(machine.usbDevices.isEmpty)
        #expect(backend.devices.isEmpty)

        // Pulled out and plugged in after that, also at once, it is taken as before.
        usb.deviceDidDisconnect(stickAgain(1).id)
        usb.deviceDidConnect(stickAgain(2))
        #expect(await eventually { machine.usbDevices == [stickAgain(2)] })
        await machine.forceStop()
    }

    @Test func aDeviceThatStaysAwayAfterADetachIsTakenWhenItIsPluggedInLater() async throws {
        defer { scratch.cleanUp() }
        let (machine, _) = try scratch.makeMachine()
        await machine.start()
        let usb = makePassthrough([machine])
        usb.holdOff = .milliseconds(150)
        usb.deviceDidConnect(stick)
        try usb.setConnectsAutomatically(true, stick, to: machine)
        #expect(await eventually { machine.usbDevices == [stick] })

        // Detached and pulled out in one go: this Mac never reports it back.
        try await usb.detach(stick, from: machine)
        usb.deviceDidDisconnect(stick.id)
        try? await Task.sleep(for: .milliseconds(200))
        usb.deviceDidConnect(stickAgain(1))
        #expect(await eventually { machine.usbDevices == [stickAgain(1)] })
        await machine.forceStop()
    }

    @Test func aDeviceGoesBackToTheMachineThatHadIt() async throws {
        defer { scratch.cleanUp() }
        let (first, firstBackend) = try scratch.makeMachine(named: "First")
        let (second, secondBackend) = try scratch.makeMachine(named: "Second")
        let usb = makePassthrough([first, second])
        try usb.setConnectsAutomatically(true, stick, to: first)
        try usb.setConnectsAutomatically(true, stick, to: second)
        // The second one has it, and the first, which would be offered it first, comes up later.
        await second.start()
        usb.deviceDidConnect(stick)
        #expect(await eventually { second.usbDevices == [stick] })
        await first.start()

        // The second restarts. The device it lets go of comes back while it is on its way up, and waits
        // for it rather than go to the first.
        #expect(await second.restart() == .powerButton)
        secondBackend.eventHandler?(.guestDidStop)
        usb.deviceDidDisconnect(stick.id)
        usb.deviceDidConnect(stickAgain(1))
        #expect(await eventually { second.usbDevices == [stickAgain(1)] })
        #expect(firstBackend.devices.isEmpty)

        // Coming back while that machine runs, it goes to it as well.
        usb.deviceDidDisconnect(stickAgain(1).id)
        usb.deviceDidConnect(stickAgain(2))
        #expect(await eventually { second.usbDevices == [stickAgain(2)] })
        // Once that machine is shut down, the other may have it.
        await second.forceStop()
        usb.deviceDidDisconnect(stickAgain(2).id)
        usb.deviceDidConnect(stickAgain(3))
        #expect(await eventually { first.usbDevices == [stickAgain(3)] })
        #expect(first.lastError == nil && second.lastError == nil)
        await first.forceStop()
    }

    @Test func aDeviceThatGoesWhileItIsOnItsWayIsOnNobodysList() async throws {
        defer { scratch.cleanUp() }
        let (machine, backend) = try scratch.makeMachine()
        await machine.start()
        let usb = makePassthrough([machine])
        usb.deviceDidConnect(stick)

        // Pulled out at that moment, it is reported gone while no guest has it yet.
        backend.whileAttaching = { usb.deviceDidDisconnect(stick.id) }
        let refusal = await #expect(throws: USBPassthrough.Failure.self) { try await usb.attach(stick, to: machine) }
        #expect(refusal == .gone(device: "Ultra"))
        #expect(usb.devices.isEmpty)
        #expect(machine.usbDevices.isEmpty)
        await machine.forceStop()
    }

    @Test func aSnapshotHandsNoDeviceToAGuestThatWasMadeToGiveItUp() async throws {
        defer { scratch.cleanUp() }
        let (machine, backend) = try scratch.makeMachine()
        await machine.start()
        let usb = makePassthrough([machine])
        usb.deviceDidConnect(stick)
        try usb.setConnectsAutomatically(true, stick, to: machine)
        #expect(await eventually { machine.usbDevices == [stick] })

        // The snapshot is refused for the device, which is detached for it and back with this Mac.
        await #expect(throws: VMError.self) { try await machine.takeSnapshot() }
        let givingBack = Task { try await usb.detach(stick, from: machine) }
        #expect(await eventually { backend.devices.isEmpty })
        usb.deviceDidDisconnect(stick.id)
        usb.deviceDidConnect(stickAgain(1))
        try await givingBack.value

        // Running or paused, the guest carries on after its snapshot without being handed the device.
        for pausesFirst in [false, true] {
            if pausesFirst {
                await machine.pause()
            }
            _ = try await machine.takeSnapshot()
            try? await Task.sleep(for: .milliseconds(150))
            #expect(machine.state == (pausesFirst ? .paused : .running))
            #expect(machine.usbDevices.isEmpty)
            #expect(backend.devices.isEmpty)
            #expect(machine.lastError == nil)
        }
        await machine.forceStop()
    }

    @Test func turningTheRuleOnTakesADeviceThatIsFree() async throws {
        defer { scratch.cleanUp() }
        let (machine, _) = try scratch.makeMachine(named: "One")
        let (other, _) = try scratch.makeMachine(named: "Other")
        await machine.start()
        await other.start()
        let usb = makePassthrough([machine, other])
        usb.deviceDidConnect(stick)
        usb.deviceDidConnect(key)
        try await usb.attach(key, to: other)

        try usb.setConnectsAutomatically(true, stick, to: machine)
        #expect(await eventually { machine.usbDevices == [stick] })
        // A device that another guest has stays there, and turning the rule off takes nothing away.
        try usb.setConnectsAutomatically(true, key, to: machine)
        try usb.setConnectsAutomatically(false, stick, to: machine)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(machine.usbDevices == [stick])
        #expect(other.usbDevices == [key])
        #expect(machine.configuration.usb.autoConnect.map(\.id) == ["1050:0407"])
        await machine.forceStop()
        await other.forceStop()
    }

    @Test func whatGoesWrongWithADeviceThatHasGoneSinceIsOfNoInterest() async throws {
        defer { scratch.cleanUp() }
        let (machine, backend) = try scratch.makeMachine()
        let usb = makePassthrough([machine])
        usb.settlingTime = .milliseconds(400)
        try usb.setConnectsAutomatically(true, stick, to: machine)
        usb.deviceDidConnect(stick)

        // A machine that restarts reaches for the device it has just let go of, which is about to come
        // back to this Mac under another number.
        backend.attachError = Refusal()
        await machine.start()
        #expect(await eventually { backend.attachAttempts == 1 })
        usb.deviceDidDisconnect(stick.id)
        backend.attachError = nil
        usb.deviceDidConnect(stickAgain(1))
        #expect(await eventually { machine.usbDevices == [stickAgain(1)] })
        try? await Task.sleep(for: .milliseconds(600))
        #expect(machine.lastError == nil)
        await machine.forceStop()
    }

    @Test func whatGoesWrongWithADeviceThatIsStillThereIsReported() async throws {
        defer { scratch.cleanUp() }
        let (machine, backend) = try scratch.makeMachine()
        let usb = makePassthrough([machine])
        usb.settlingTime = .milliseconds(50)
        try usb.setConnectsAutomatically(true, stick, to: machine)
        usb.deviceDidConnect(stick)

        backend.attachError = Refusal()
        await machine.start()
        #expect(await eventually { machine.lastError != nil })
        #expect(machine.lastError?.title == "Couldn't attach “Ultra” to “Box”")
        #expect(machine.lastError?.message == "The guest won't have it.")
        #expect(machine.usbDevices.isEmpty)
        await machine.forceStop()
    }
}
