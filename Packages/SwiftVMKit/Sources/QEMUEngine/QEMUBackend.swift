import AppKit
import DiskTools
import GuestChannel
import ImageIO
import UniformTypeIdentifiers
import VMCore
import VMNetworking

/// A machine running on QEMU, in a process of its own.
///
/// QEMU starts with its guest held, and the app puts its lines in place before letting it run: the
/// machine protocol (QMP), the display, the network and the agent's serial line. A restart of the guest
/// ends QEMU (`-no-reboot`), and the machine starts it again, so that the next run gets the hardware the
/// machine is configured with by then.
@MainActor
public final class QEMUBackend: VMBackend {
    public var eventHandler: (@MainActor (VMBackendEvent) -> Void)?

    private let configuration: VMConfiguration
    private let bundle: VMBundle
    private let installation: QEMUInstallation
    private let adapter: DisplayAdapter
    private let network: VmnetNetwork?
    private let console: SerialConsole.GuestEnd
    /// The guest's disk is still empty and an installer disc is plugged in: the disc only starts when a
    /// key is pressed, which nobody is there to do.
    private let pressesKeyToBootInstaller: Bool

    private let screen: RFBClient
    /// QEMU's end of the display's line, until it has been handed over.
    private var screenEnd: Int32
    private let view: GuestScreenView
    private var process: QEMUProcess?
    private var monitor: QMPConnection?
    private var agentChannel: AgentChannel?
    private var ports: [VmnetPort] = []
    private var diskExports: [CompressedDiskExport] = []
    /// The drives that are plugged in, which an unplug finds its devices by.
    private var drives: [UUID: RemovableImage] = [:]
    /// The USB port of each drive and disk on USB, by its identifier, which a restore puts them back in.
    private var usbPorts: [UUID: Int] = [:]
    /// The console's line, while it is relayed.
    private var consoleLine: ConsoleLine?
    private var isRunning = false
    /// The app has asked QEMU to end, and its end is no news.
    private var expectsExit = false
    /// Why QEMU said the guest went down, from its `SHUTDOWN` event.
    private var shutdownReason: String?
    private var isLaunching = false
    private var hasExited = false
    private var isMonitorClosed = false
    private var hasReportedExit = false
    /// Who waits for QEMU to say a device is gone, by the device's ID.
    private var removals: [String: [CheckedContinuation<Void, Never>]] = [:]
    /// What was asked of the mouse and the keyboard last. The next thing waits for it.
    private var turn = Task<Void, Never> {}

    init(
        configuration: VMConfiguration, bundle: VMBundle, installation: QEMUInstallation, adapter: DisplayAdapter,
        network: VmnetNetwork?, console: SerialConsole.GuestEnd, pressesKeyToBootInstaller: Bool
    ) throws {
        self.configuration = configuration
        self.bundle = bundle
        self.installation = installation
        self.adapter = adapter
        self.network = network
        self.console = console
        self.pressesKeyToBootInstaller = pressesKeyToBootInstaller
        let (app, engine) = try Self.socketPair(SOCK_STREAM)
        screen = RFBClient(descriptor: app)
        screenEnd = engine
        view = GuestScreenView(client: screen)
        view.capturesSystemKeys = configuration.keyboard.capturesSystemKeys
        view.resizesGuest = adapter == .virtioGPU && configuration.display.automaticallyResizes
        connectScreen()
    }

    // MARK: Display

    public var displayView: NSView { view }

    /// Passes what the display's client hears on to the view, on the main thread. A display that
    /// changes faster than the screen is drawn is drawn once for all of it.
    private func connectScreen() {
        let redraw = Redraw()
        screen.onResize = { [weak view] picture in
            DispatchQueue.main.async { MainActor.assumeIsolated { view?.show(picture) } }
        }
        screen.onUpdate = { [weak view] _ in
            guard redraw.claim() else { return }
            DispatchQueue.main.async {
                redraw.release()
                MainActor.assumeIsolated { view?.pictureDidChange() }
            }
        }
        screen.onCursor = { [weak view] cursor in
            DispatchQueue.main.async { MainActor.assumeIsolated { view?.show(cursor: cursor) } }
        }
    }

    // MARK: Lifecycle

    public var canRequestStop: Bool { monitor != nil && isRunning }

    public func start(options: VMStartOptions) async throws {
        isLaunching = true
        defer { isLaunching = false }
        do {
            try await launch(restoringFrom: options.savedState)
        } catch {
            await tearDown()
            throw error
        }
    }

    private func launch(restoringFrom savedState: URL?) async throws {
        await QEMUProcess.endLeftover(pidFile: Self.pidFile(in: bundle), machineID: configuration.id)

        var sources: [UUID: QEMUCommandLine.DiskSource] = [:]
        for disk in configuration.disks {
            let url = bundle.diskURL(for: disk)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw VMError.invalidConfiguration("The virtual machine is missing “\(disk.fileName)”.")
            }
            switch disk.format {
            case .raw:
                sources[disk.id] = .file(url)
            case .compressed:
                let export = try CompressedDiskExport(diskAt: url, readOnly: disk.readOnly)
                diskExports.append(export)
                sources[disk.id] = .nbd(socketPath: export.socketPath)
            case .asif:
                throw VMError.invalidConfiguration(
                    "QEMU can't read “\(disk.fileName)”, which is in Apple's sparse image format. Convert the disk to a raw or compressed one in the machine's settings."
                )
            }
        }
        for image in configuration.removableImages where !FileManager.default.fileExists(atPath: image.path) {
            throw VMError.invalidConfiguration("The disk image “\(image.name)” can't be found. Put it back, or eject it in the virtual machine's settings.")
        }
        if !FileManager.default.fileExists(atPath: bundle.efiVariableStoreURL.path) {
            try installation.makeVariableStore(at: bundle.efiVariableStoreURL)
        }

        let commandLine = QEMUCommandLine(
            configuration: configuration, bundle: bundle, installation: installation, diskSources: sources,
            display: adapter == .virtioGPU ? .virtioGPU : .framebuffer, restoresSavedState: savedState != nil,
            usbPorts: try savedState.map { try SavedStateHeader.read(from: $0).usbPorts } ?? [:]
        )
        let arguments = try commandLine.arguments()
        usbPorts = try commandLine.startingUSBPorts()

        // The lines, in the order QEMU's command line numbers them.
        let monitorPair = try Self.socketPair(SOCK_STREAM)
        let consolePair = try Self.socketPair(SOCK_STREAM)
        let agentPair = try Self.socketPair(SOCK_STREAM)
        var networkPairs: [(port: Int32, engine: Int32)] = []
        for _ in configuration.networkInterfaces {
            networkPairs.append(try VmnetPort.makeSocketPair())
        }
        let engineEnds = [monitorPair.engine, consolePair.engine, agentPair.engine] + networkPairs.map(\.engine)
        let appEnds = [monitorPair.app, consolePair.app, agentPair.app] + networkPairs.map(\.port)
        let process: QEMUProcess
        do {
            process = try QEMUProcess.launch(
                program: installation.program, arguments: arguments, descriptors: engineEnds,
                log: bundle.logsDirectory.appending(path: "qemu.log"), pidFile: Self.pidFile(in: bundle)
            )
        } catch {
            (engineEnds + appEnds).forEach { close($0) }
            throw error
        }
        engineEnds.forEach { close($0) }
        self.process = process
        process.onExit = { [weak self] status in
            Task { @MainActor in self?.processDidExit(status) }
        }

        relayConsole(over: consolePair.app)
        let agentChannel = AgentChannel(descriptor: agentPair.app)
        agentChannel.start()
        self.agentChannel = agentChannel

        // Every card is on the network, also one whose cable is out: QEMU drops what goes over a
        // link that is down, and plugging the cable in is a word to QEMU.
        for (index, pair) in networkPairs.enumerated() {
            guard let network else {
                close(pair.port)
                continue
            }
            do {
                ports.append(try await VmnetPort.open(on: network, peer: pair.port))
            } catch {
                // The port has let go of its end. The others, and the monitor's line, are nobody's yet.
                networkPairs[(index + 1)...].forEach { close($0.port) }
                close(monitorPair.app)
                throw error
            }
        }

        let monitor = QMPConnection(descriptor: monitorPair.app)
        monitor.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        // After the events it passed on, which come over the same line.
        monitor.onClose = { [weak self] in
            Task { @MainActor in self?.monitorDidClose() }
        }
        self.monitor = monitor
        do {
            try await monitor.open()
        } catch {
            throw QEMUError.didNotStart(await reason(process))
        }

        // The display's line, handed to QEMU over the machine protocol, which carries descriptors.
        try await monitor.execute("getfd", ["fdname": "screen"], passing: screenEnd)
        close(screenEnd)
        screenEnd = -1
        try await monitor.execute("add_client", ["protocol": "vnc", "fdname": "screen", "skipauth": true])
        let screen = screen
        try await Task.detached { try screen.open() }.value

        for (index, interface) in configuration.networkInterfaces.enumerated() where !interface.isConnected {
            try await monitor.execute("set_link", ["name": .string(QEMUCommandLine.networkDeviceID(at: index)), "up": false])
        }
        for image in configuration.removableImages {
            drives[image.id] = image
        }

        if let savedState {
            try await monitor.execute("migrate-incoming", ["channels": Self.migrationChannels(to: savedState)])
            try await waitForMigration()
            await plugInAudio()
        }
        try await monitor.execute("cont")
        isRunning = true
        if pressesKeyToBootInstaller, savedState == nil {
            pressKeyForInstaller()
        }
    }

    /// Why QEMU didn't start: what it said as it ended, which it says once it has.
    private func reason(_ process: QEMUProcess) async -> String {
        _ = await process.waitForExit(timeout: .seconds(2))
        return process.complaint.map { "It said: \($0)" } ?? "It ended without saying why."
    }

    /// An installer disc's firmware asks for a key before it starts the installer, and starts from the
    /// empty disk instead when none comes. A few seconds of pressing the space bar is that key.
    private func pressKeyForInstaller() {
        Task { [weak self] in
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, isRunning, let monitor else { return }
                _ = try? await monitor.execute("send-key", ["keys": [["type": "qcode", "data": "spc"]]])
            }
        }
    }

    public func requestStop() throws {
        guard let monitor, isRunning else { throw VMError.notRunning(name: configuration.name) }
        Task { _ = try? await monitor.execute("system_powerdown") }
    }

    public func stop() async throws {
        guard let process, !process.hasExited else { return }
        expectsExit = true
        isRunning = false
        _ = try? await monitor?.execute("quit")
        if !(await process.waitForExit(timeout: .seconds(5))) {
            process.forceKill()
            _ = await process.waitForExit(timeout: .seconds(5))
        }
    }

    public func pause() async throws {
        guard let monitor else { throw VMError.notRunning(name: configuration.name) }
        try await monitor.execute("stop")
        isRunning = false
    }

    public func resume() async throws {
        guard let monitor else { throw VMError.notRunning(name: configuration.name) }
        try await monitor.execute("cont")
        isRunning = true
    }

    public func saveState(to url: URL) async throws {
        guard let monitor else { throw VMError.notRunning(name: configuration.name) }
        try? FileManager.default.removeItem(at: url)
        // QEMU can't save its USB sound card, which is unplugged for the moment saving takes.
        if configuration.audio.outputEnabled {
            await removeDevice(QEMUCommandLine.audioDeviceID)
        }
        do {
            try await monitor.execute("migrate", ["channels": Self.migrationChannels(to: url)])
            try await waitForMigration()
            try SavedStateHeader(usbPorts: usbPorts).write(into: url)
        } catch {
            await plugInAudio()
            throw error
        }
        await plugInAudio()
    }

    /// Plugs the sound card in, which a machine that was saved is without.
    private func plugInAudio() async {
        guard configuration.audio.outputEnabled, let monitor else { return }
        // A machine without sound is still of use.
        _ = try? await monitor.execute("device_add", QEMUCommandLine.audioDevice)
    }

    /// Where the machine's memory goes, or comes from: a file, given by its name rather than in a URI,
    /// which a comma in the path would cut short. It starts after the header that is SwiftVM's.
    private static func migrationChannels(to url: URL) -> QMPValue {
        [["channel-type": "main", "addr": [
            "transport": "file", "filename": .string(url.path), "offset": .number(Double(SavedStateHeader.size)),
        ]]]
    }

    private func waitForMigration() async throws {
        guard let monitor else { throw QEMUError.disconnected }
        while true {
            let status = try await monitor.execute("query-migrate")
            switch status["status"]?.string {
            case "completed":
                return
            case "failed", "cancelled":
                throw QEMUError.refused(status["error-desc"]?.string ?? "The machine's memory couldn't be saved or read back.")
            default:
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    // MARK: QEMU's own word

    private func handle(_ event: QMPEvent) {
        switch event.name {
        case "SHUTDOWN":
            shutdownReason = event.data["reason"]?.string
        case "DEVICE_DELETED":
            if let device = event.data["device"]?.string {
                finishRemoval(of: device)
            }
        case "VSERPORT_CHANGE":
            // The agent's side of its line was closed, or opened anew: what was open on it is gone.
            if event.data["open"]?.bool == false {
                agentChannel?.agentLeft()
            } else {
                agentChannel?.agentArrived()
            }
        default:
            break
        }
    }

    private func processDidExit(_ status: Int32) {
        isRunning = false
        hasExited = true
        if isMonitorClosed { reportExit() }
    }

    private func monitorDidClose() {
        isMonitorClosed = true
        if hasExited { reportExit() }
    }

    /// Says why QEMU ended, once it has and its line has closed: what it said last, its reason for the
    /// guest going down among it, has been heard by then. A start that fails says so itself.
    private func reportExit() {
        guard !expectsExit, !isLaunching, !hasReportedExit else { return }
        hasReportedExit = true
        switch shutdownReason {
        case "guest-reset":
            eventHandler?(.guestDidRestart)
        case "guest-shutdown", "guest-panic", "host-signal", "host-qmp-quit":
            eventHandler?(.guestDidStop)
        default:
            let said = process?.complaint.map { " It said: \($0)" } ?? ""
            eventHandler?(.stoppedWithError("QEMU stopped unexpectedly.\(said)"))
        }
    }

    public func invalidate() {
        // The disks a QEMU that has gone was served are let go of at once. A guest that restarted is
        // started again right away, and two that hold one disk would each reclaim space the other uses.
        if process?.hasExited ?? true {
            closeDiskExports()
        }
        Task { await tearDown() }
    }

    private func closeDiskExports() {
        for export in diskExports { try? export.close() }
        diskExports = []
    }

    /// Lets go of everything the machine had: QEMU itself if it is still there, its lines, the network
    /// ports and the disks the app served it.
    private func tearDown() async {
        isRunning = false
        expectsExit = true
        if let process, !process.hasExited {
            process.forceKill()
            _ = await process.waitForExit(timeout: .seconds(5))
        }
        monitor?.close()
        monitor = nil
        screen.close()
        if screenEnd >= 0 {
            close(screenEnd)
            screenEnd = -1
        }
        agentChannel?.close()
        agentChannel = nil
        consoleLine?.shutdown()
        consoleLine = nil
        let ports = ports
        self.ports = []
        for port in ports {
            await port.close()
        }
        closeDiskExports()
        for waiting in removals.values.joined() { waiting.resume() }
        removals = [:]
    }

    // MARK: Devices

    public func setNetworkInterface(_ id: UUID, connected: Bool) throws {
        guard let index = configuration.networkInterfaces.firstIndex(where: { $0.id == id }), let monitor else { return }
        Task { _ = try? await monitor.execute("set_link", ["name": .string(QEMUCommandLine.networkDeviceID(at: index)), "up": .bool(connected)]) }
    }

    /// Shared folders reach a Windows guest over the network, through its agent: QEMU has no part in it.
    public func setSharedFolders(_ folders: [SharedFolder]) throws {}

    public func attachRemovableImage(_ image: RemovableImage) async throws {
        guard let monitor else { throw VMError.notRunning(name: configuration.name) }
        guard let port = QEMUCommandLine.freeUSBPort(besides: usbPorts.values) else {
            throw VMError.invalidConfiguration("“\(configuration.name)” has no free USB port for “\(image.name)”. Eject another drive first.")
        }
        try await monitor.execute("blockdev-add", QEMUCommandLine.imageNode(for: image))
        do {
            for device in QEMUCommandLine.imageDevices(for: image, port: port) {
                try await monitor.execute("device_add", device)
            }
            // A drive for discs that is plugged in while the guest runs waits for its disc before the
            // guest sees it, and is told when it has one.
            if RemovableImage.isDiscImage(image.url) {
                try await monitor.execute("qom-set", [
                    "path": .string("/machine/peripheral/" + QEMUCommandLine.imageDeviceID(for: image)),
                    "property": "attached", "value": true,
                ])
            }
        } catch {
            _ = try? await monitor.execute("device_del", ["id": .string(QEMUCommandLine.imageDeviceID(for: image))])
            _ = try? await monitor.execute("blockdev-del", ["node-name": .string(QEMUCommandLine.imageNodeName(for: image.id))])
            throw error
        }
        drives[image.id] = image
        usbPorts[image.id] = port
    }

    public func detachRemovableImage(_ id: UUID) async throws {
        guard let monitor, let image = drives[id] else { return }
        await removeDevice(QEMUCommandLine.imageDeviceID(for: image))
        _ = try? await monitor.execute("blockdev-del", ["node-name": .string(QEMUCommandLine.imageNodeName(for: id))])
        drives[id] = nil
        usbPorts[id] = nil
    }

    /// Unplugs a device, and returns once QEMU says the guest has let go of it, or after a while.
    private func removeDevice(_ device: String) async {
        guard let monitor else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Who asks for it while it is on its way waits for the same.
            let isUnderWay = removals[device] != nil
            removals[device, default: []].append(continuation)
            guard !isUnderWay else { return }
            Task { [weak self] in
                do {
                    try await monitor.execute("device_del", ["id": .string(device)])
                } catch {
                    self?.finishRemoval(of: device)
                }
            }
            // A guest that never lets go doesn't keep anyone waiting for long, nor the machine with them.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                self?.finishRemoval(of: device)
            }
        }
    }

    private func finishRemoval(of device: String) {
        for waiting in removals.removeValue(forKey: device) ?? [] {
            waiting.resume()
        }
    }

    public func setCapturesSystemKeys(_ capturesSystemKeys: Bool) {
        view.capturesSystemKeys = capturesSystemKeys
    }

    // MARK: Guest socket

    public func connectToGuest(port: UInt32) async throws -> FileHandle {
        guard let agentChannel else { throw VMError.notRunning(name: configuration.name) }
        return try await agentChannel.connect(port: port)
    }

    // MARK: The console

    /// Passes bytes between the console's line to QEMU and the machine's serial console.
    private func relayConsole(over line: Int32) {
        let consoleLine = ConsoleLine(line)
        self.consoleLine = consoleLine
        let input = console.input.fileDescriptor
        let output = console.output.fileDescriptor
        // A console that nobody reads any more doesn't end the app.
        _ = fcntl(output, F_SETNOSIGPIPE, 1)
        // Each direction has a descriptor of its own, so that neither is closed under the other.
        let toGuest = dup(line)
        Thread.detachNewThread {
            _ = ByteRelay.copy(from: input, to: toGuest)
            close(toGuest)
        }
        Thread.detachNewThread {
            _ = ByteRelay.copy(from: line, to: output)
            consoleLine.close()
        }
    }

    /// The console's line, which the thread that reads it closes once QEMU has gone, and which the
    /// machine shuts to end that thread sooner: only while it is open, when its number is still its own.
    private final class ConsoleLine: @unchecked Sendable {
        private let lock = NSLock()
        private var descriptor: Int32

        init(_ descriptor: Int32) {
            self.descriptor = descriptor
        }

        func shutdown() {
            lock.withLock {
                if descriptor >= 0 { _ = Darwin.shutdown(descriptor, SHUT_RDWR) }
            }
        }

        func close() {
            lock.withLock {
                if descriptor >= 0 { _ = Darwin.close(descriptor) }
                descriptor = -1
            }
        }
    }

    // MARK: The machine's own display, mouse and keyboard

    public func screenshot() async throws -> Data {
        guard let picture = screen.picture else { throw MachineDeskError.nothingShown }
        let surface = picture.surface
        surface.lock(options: .readOnly, seed: nil)
        let pixels = Data(bytes: surface.baseAddress, count: surface.bytesPerRow * surface.height)
        let bytesPerRow = surface.bytesPerRow
        surface.unlock(options: .readOnly, seed: nil)
        return try await Task.detached(priority: .userInitiated) {
            try Self.png(pixels: pixels, width: picture.width, height: picture.height, bytesPerRow: bytesPerRow)
        }.value
    }

    nonisolated static func png(pixels: Data, width: Int, height: Int, bytesPerRow: Int) throws -> Data {
        let layout = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        let data = NSMutableData()
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: layout, provider: provider,
                  decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw MachineDeskError.nothingShown }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw MachineDeskError.nothingShown }
        return data as Data
    }

    /// How long the guest gets to take in what the mouse did before the next thing.
    private static let mousePause: Duration = .milliseconds(40)
    private static let keyPause: Duration = .milliseconds(12)

    public func pointer(_ request: GuestJob.Pointer, guestTurnsWheel: Bool) async throws {
        guard let picture = screen.picture else { throw MachineDeskError.nothingShown }
        let size = (width: picture.width, height: picture.height)
        func place(_ x: Int, _ y: Int) throws -> (Int, Int) {
            guard (0..<size.width).contains(x), (0..<size.height).contains(y) else {
                throw MachineDeskError.invalid("(\(x), \(y)) isn't on the screen, which is \(size.width) by \(size.height).")
            }
            return (x, y)
        }
        let start = try place(request.x, request.y)
        let button: RFBClient.Buttons = switch request.button ?? .left {
        case .left: .left
        case .right: .right
        case .middle: .middle
        }
        let screen = screen
        try await inTurn {
            func move(_ point: (Int, Int), _ buttons: RFBClient.Buttons) async throws {
                screen.pointer(x: point.0, y: point.1, buttons: buttons)
                try await Task.sleep(for: Self.mousePause)
            }
            // From a pixel aside, so that the guest sees the pointer arrive where it is put.
            let aside = (start.0 + (start.0 + 2 < size.width ? 2 : -2), start.1)
            switch request.action {
            case .move:
                try await move(start, [])
            case .click:
                let count = request.count ?? 1
                guard (1...3).contains(count) else { throw MachineDeskError.invalid("A click is one, two or three clicks.") }
                try await move(aside, [])
                try await move(start, [])
                for _ in 1...count {
                    try await move(start, button)
                    try await move(start, [])
                }
            case .drag:
                guard let toX = request.toX, let toY = request.toY else { throw MachineDeskError.invalid("The request doesn't say where the drag ends.") }
                let end = try place(toX, toY)
                try await move(aside, [])
                try await move(start, [])
                try await move(start, button)
                let steps = 12
                for step in 1...steps {
                    let part = Double(step) / Double(steps)
                    try await move((start.0 + Int(Double(end.0 - start.0) * part), start.1 + Int(Double(end.1 - start.1) * part)), button)
                }
                try await move(end, [])
            case .scroll:
                let (deltaX, deltaY) = (request.deltaX ?? 0, request.deltaY ?? 0)
                guard abs(deltaX) <= 100, abs(deltaY) <= 100 else { throw MachineDeskError.invalid("That is further than the wheel is turned in one go.") }
                try await move(start, [])
                // Positive is down and to the right. Windows turns its wheel as it is turned.
                for notch in 0..<max(abs(deltaX), abs(deltaY)) {
                    var wheel: RFBClient.Buttons = []
                    if notch < abs(deltaY) { wheel.insert(deltaY > 0 ? .wheelDown : .wheelUp) }
                    if notch < abs(deltaX) { wheel.insert(deltaX > 0 ? .wheelRight : .wheelLeft) }
                    screen.pointer(x: start.0, y: start.1, buttons: wheel)
                    screen.pointer(x: start.0, y: start.1, buttons: [])
                    try await Task.sleep(for: Self.keyPause)
                }
            }
        }
    }

    public func keys(_ request: GuestJob.Keys) async throws {
        // Everything is looked up before anything is typed: half of it is worse than none.
        var presses: [MacKeys.Press] = []
        for character in request.text ?? "" {
            guard let press = MacKeys.press(typing: character) else { throw MachineDeskError.notOnTheKeyboard(character) }
            presses.append(press)
        }
        do {
            presses += try (request.keys ?? []).map(MacKeys.press(for:))
        } catch let problem as MacKeys.NoSuchKey {
            throw MachineDeskError.invalid(problem.message)
        }
        guard !presses.isEmpty else { throw MachineDeskError.invalid("The request has neither text to type nor keys to press.") }
        let codes = try presses.map { press in
            do {
                return try PCKeys.scancodes(for: press)
            } catch {
                throw MachineDeskError.invalid("The machine's keyboard has no such key.")
            }
        }
        let screen = screen
        try await inTurn {
            for (held, key) in codes {
                for code in held {
                    screen.key(code, down: true)
                    try await Task.sleep(for: Self.keyPause)
                }
                if let key {
                    screen.key(key, down: true)
                    try await Task.sleep(for: Self.keyPause)
                    screen.key(key, down: false)
                    try await Task.sleep(for: Self.keyPause)
                }
                for code in held.reversed() {
                    screen.key(code, down: false)
                    try await Task.sleep(for: Self.keyPause)
                }
            }
        }
    }

    private func inTurn(_ work: @escaping @MainActor () async throws -> Void) async throws {
        let before = turn
        let mine = Task { @MainActor in
            await before.value
            try await work()
        }
        turn = Task { _ = try? await mine.value }
        try await mine.value
    }

    // MARK: Helpers

    /// Ends the QEMU that a machine was left running with by an app that stopped without stopping it,
    /// in a crash. A machine on the Virtualization framework ends with the app; one on QEMU would run on
    /// unseen, writing to its disk.
    public static func endLeftover(of configuration: VMConfiguration, in bundle: VMBundle) async {
        await QEMUProcess.endLeftover(pidFile: pidFile(in: bundle), machineID: configuration.id)
    }

    static func pidFile(in bundle: VMBundle) -> URL {
        bundle.url.appending(path: "qemu.pid")
    }

    private static func socketPair(_ type: Int32) throws -> (app: Int32, engine: Int32) {
        var ends: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, type, 0, &ends) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        for end in ends {
            _ = fcntl(end, F_SETNOSIGPIPE, 1)
            _ = fcntl(end, F_SETFD, FD_CLOEXEC)
        }
        return (ends[0], ends[1])
    }
}

/// Says whether a redraw is on its way to the main thread already.
private final class Redraw: @unchecked Sendable {
    private let lock = NSLock()
    private var isPending = false

    /// Takes the next redraw on, unless one is on its way.
    func claim() -> Bool {
        lock.withLock {
            guard !isPending else { return false }
            isPending = true
            return true
        }
    }

    func release() {
        lock.withLock { isPending = false }
    }
}
