import AppKit
import DiskTools
import GuestChannel
import VMControl
import VMCore
import VMNetworking

/// A machine running on QEMU, which `swiftvm serve` runs for the app.
///
/// The app hands the machine to the service with the lines that only the app can make: the serial
/// console's, one per network card on vmnet, and the display's. The service starts QEMU with its guest
/// held, and the app connects the display before letting it run. Everything else is a request to the
/// service, which tells on a line of its own how QEMU ended. A restart of the guest ends QEMU, and the
/// machine starts it again, so that the next run gets the hardware the machine is configured with by then.
///
/// QEMU outlives the service: a service that stops lets go of it, and the next takes it on. This backend
/// then hears from the next one.
@MainActor
public final class QEMUBackend: VMBackend {
    public var eventHandler: (@MainActor (VMBackendEvent) -> Void)?

    private let configuration: VMConfiguration
    private let service: QEMUService
    private let info: QEMUMachineInfo
    let adapter: DisplayAdapter
    private let console: SerialConsole.GuestEnd
    /// The app's end of the console's line, until it is relayed.
    private var consoleEnd: Int32

    private let screen: RFBClient?
    private let spice: SpiceClient?
    private let input: any GuestScreenInput
    private let view: GuestScreenView
    /// Older Windows 3D drivers take a new size only as they start. The guest confirms whether its
    /// active driver can resize; until then the view only reports the size that would fit sharply.
    private let needsDisplayResizeSupport: Bool
    private var hasDisplayResizeSupport = false
    private var startsAtDisplaySize: Bool {
        needsDisplayResizeSupport && configuration.display.automaticallyResizes && !hasDisplayResizeSupport
    }
    /// The views of parts of the display that are open: windows of the guest's apps on the Mac.
    private let regionViews = NSHashTable<GuestScreenView>.weakObjects()
    /// The views of part of the VNC client's picture that haven't been closed.
    private var openRegions = 0
    /// The guest's pointer as the display last drew it, for a view of part of it that opens later.
    private var cursor: RFBClient.Cursor?
    /// The pointer the guest hands over for the Mac to draw, for a view of part of it that opens later.
    private var pointer: GuestCursor?
    /// What waits for the display's next picture. See ``afterDisplayUpdate(_:)``.
    private var afterUpdate: [@MainActor () -> Void] = []

    private var ports: [VmnetPort]
    private var diskExports: [CompressedDiskExport]
    /// Follows the line the service tells how QEMU ended on.
    private let follower: EventFollower
    /// The console's line, while it is relayed.
    private var consoleLine: ConsoleLine?
    private var isRunning = false
    /// The app has asked QEMU to end, and its end is no news.
    private var expectsExit = false
    private var isLaunching = false
    private var hasExited = false
    private var hasReportedExit = false
    private var isTornDown = false

    private init(
        configuration: VMConfiguration, service: QEMUService, info: QEMUMachineInfo, installation: QEMUInstallation,
        console: SerialConsole.GuestEnd, consoleEnd: Int32, displayEnd: Int32, ports: [VmnetPort], diskExports: [CompressedDiskExport],
        events: ServiceConnection
    ) throws {
        self.configuration = configuration
        self.service = service
        self.info = info
        self.console = console
        self.consoleEnd = consoleEnd
        self.ports = ports
        self.diskExports = diskExports
        follower = EventFollower(connection: events)
        adapter = DisplayAdapter(rawValue: info.adapter.rawValue) ?? .framebuffer
        if adapter == .virtioGPU3D {
            guard let socket = info.spiceSocket else { throw QEMUError.didNotStart("The service didn't say where the display is.") }
            let spice = try SpiceClient(library: installation.displayLibrary, socket: URL(fileURLWithPath: socket))
            self.spice = spice
            screen = nil
            input = spice
            view = GuestScreenView(input: spice, content: spice.view)
        } else {
            let screen = RFBClient(descriptor: displayEnd)
            self.screen = screen
            spice = nil
            input = screen
            view = GuestScreenView(client: screen)
        }
        needsDisplayResizeSupport = adapter == .virtioGPU3D && configuration.os.family == .windows
        view.capturesSystemKeys = configuration.keyboard.capturesSystemKeys
        // Wait for the guest to confirm that its active 3D driver can add modes.
        view.resizesGuest = adapter != .framebuffer && configuration.display.automaticallyResizes && !startsAtDisplaySize
        connectScreen()
    }

    /// Hands the machine to the service, which starts QEMU with its guest held.
    ///
    /// - Parameters:
    ///   - savedState: The saved state to resume from, for a machine that is restoring.
    ///   - network: The shared network, for cards that aren't bridged.
    static func launch(
        configuration: VMConfiguration, bundle: VMBundle, savedState: URL?, installation: QEMUInstallation, network: VmnetNetwork?,
        console: SerialConsole.GuestEnd, directX: QEMURequest.DirectX?, refreshRate: Int, service: QEMUService
    ) async throws -> QEMUBackend {
        var exports: [CompressedDiskExport] = []
        var ports: [VmnetPort] = []
        // QEMU's ends, which go to the service, and the app's ends of the console's and display's lines.
        var engineEnds: [Int32] = []
        var appEnds: [Int32] = []
        defer { engineEnds.forEach { close($0) } }
        func letGo() async {
            appEnds.forEach { close($0) }
            for port in ports { await port.close() }
            for export in exports { try? export.close() }
        }
        do {
            var request = QEMURequest(command: "qemu-start")
            request.bundle = bundle.url.path
            request.savedState = savedState?.path
            request.directX = directX
            request.refreshRate = refreshRate
            var diskSources: [String: String] = [:]
            for disk in configuration.disks where disk.format == .compressed {
                let url = bundle.diskURL(for: disk)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw VMError.invalidConfiguration("The virtual machine is missing “\(disk.fileName)”.")
                }
                let export = try CompressedDiskExport(diskAt: url, readOnly: disk.readOnly)
                exports.append(export)
                diskSources[disk.id.uuidString] = export.socketPath
            }
            request.diskSources = diskSources.isEmpty ? nil : diskSources

            let consolePair = try socketPair()
            appEnds.append(consolePair.app)
            engineEnds.append(consolePair.engine)
            var roles: [QEMURequest.Descriptor] = [.console]
            // Every card is on the network, also one whose cable is out: QEMU drops what goes over a link
            // that is down, and plugging the cable in is a word to QEMU.
            for interface in configuration.networkInterfaces {
                let pair = try VmnetPort.makeSocketPair()
                engineEnds.append(pair.engine)
                // The port takes over its end, also when it fails.
                if let identifier = interface.bridgedInterfaceIdentifier {
                    ports.append(try await VmnetPort.open(bridgedTo: identifier, peer: pair.port))
                } else if let network {
                    ports.append(try await VmnetPort.open(on: network, peer: pair.port))
                } else {
                    close(pair.port)
                    throw QEMUError.didNotStart("The shared network isn't available.")
                }
                roles.append(.network)
            }
            // The display's one client. macOS gives a local stream just 8 KB by default, and a frame is
            // several MB: QEMU's outgoing pixels get room at both ends.
            let displayPair = try socketPair()
            var pixelBufferSize: Int32 = 1 << 20
            _ = setsockopt(displayPair.app, SOL_SOCKET, SO_RCVBUF, &pixelBufferSize, socklen_t(MemoryLayout<Int32>.size))
            _ = setsockopt(displayPair.engine, SOL_SOCKET, SO_SNDBUF, &pixelBufferSize, socklen_t(MemoryLayout<Int32>.size))
            appEnds.append(displayPair.app)
            engineEnds.append(displayPair.engine)
            roles.append(.display)
            request.descriptors = roles

            let handed = engineEnds
            let (events, answer) = try await Task.detached { () throws -> (ServiceConnection, QEMUAnswer) in
                let connection = try service.connect()
                do {
                    return (connection, try connection.send(request, passing: handed))
                } catch {
                    connection.close()
                    throw error
                }
            }.value
            guard let info = answer.qemu else {
                events.close()
                throw QEMUError.didNotStart("The service didn't say what it started.")
            }
            do {
                let backend = try QEMUBackend(
                    configuration: configuration, service: service, info: info, installation: installation, console: console,
                    consoleEnd: consolePair.app, displayEnd: displayPair.app, ports: ports, diskExports: exports, events: events
                )
                // The display is shown over SPICE: its VNC line is of no use.
                if backend.adapter == .virtioGPU3D {
                    close(displayPair.app)
                }
                appEnds = []
                return backend
            } catch {
                events.close()
                var stop = QEMURequest(command: "qemu-stop", machine: info.machine)
                stop.force = true
                _ = try? await service.call(stop)
                throw error
            }
        } catch {
            await letGo()
            throw error
        }
    }

    // MARK: Display

    public var displayView: NSView { view }

    /// Every view that shows the display, all of it or part of it.
    private var screenViews: [GuestScreenView] {
        [view] + regionViews.allObjects
    }

    /// Passes what the display's client hears on to the views, on the main thread. A display that
    /// changes faster than the screen is drawn is drawn once for all of it.
    private func connectScreen() {
        view.onFittingSize = { [weak self] size in
            guard let self else { return }
            if startsAtDisplaySize {
                eventHandler?(.displaySizeWanted(size))
            } else if screen != nil, view.resizesGuest {
                // The agent sets the scale that goes with the size. SPICE says itself what it asked for.
                eventHandler?(.displaySizeRequested(width: size.width, height: size.height, scale: size.scale))
            }
        }
        spice?.onResize = { [weak self] size in
            guard let self else { return }
            screenViews.forEach { $0.show(size: size) }
            eventHandler?(.displayResized(width: Int(size.width), height: Int(size.height)))
        }
        guard let screen else { return }
        let redraw = Redraw()
        screen.onResize = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let picture = self.screen?.picture else { return }
                    self.screenViews.forEach { $0.show(picture) }
                    self.eventHandler?(.displayResized(width: picture.width, height: picture.height))
                }
            }
        }
        screen.onUpdate = { [weak self] _ in
            guard redraw.claim() else { return }
            DispatchQueue.main.async {
                redraw.release()
                MainActor.assumeIsolated {
                    guard let self, let picture = self.screen?.picture else { return }
                    self.screenViews.forEach { $0.show(picture) }
                    self.displayDidUpdate()
                }
            }
        }
        screen.onCursor = { [weak self] cursor in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.cursor = cursor
                    self.screenViews.forEach { $0.show(cursor: cursor) }
                }
            }
        }
    }

    public func makeRegionView() -> (any GuestRegionView)? {
        let region: GuestScreenView
        if let spice {
            // A display library from before views of part of the display has none to give.
            guard let content = spice.makeRegion() else { return nil }
            region = GuestScreenView(input: spice, content: content.view)
            region.onRegionChange = { content.region = $0 ?? .zero }
            region.onClose = { content.close() }
            region.show(size: spice.size)
        } else if let screen {
            region = GuestScreenView(client: screen)
            if let picture = screen.picture {
                region.show(picture)
            }
            region.show(cursor: cursor)
            // What the guest has behind its windows is no part of any of them.
            openRegions += 1
            screen.clearsBackdrop = true
            region.onClose = { [weak self, weak screen] in
                guard let self else { return }
                openRegions -= 1
                if openRegions == 0 { screen?.clearsBackdrop = false }
            }
        } else {
            return nil
        }
        region.show(pointer: pointer)
        region.capturesSystemKeys = view.capturesSystemKeys
        regionViews.add(region)
        return region
    }

    public func requestDisplaySize(width: Int, height: Int, scale: Double) {
        // Such a guest takes its size as it starts. What shows it fits itself to that one.
        guard !startsAtDisplaySize else { return }
        // Even sizes, as the window asks for: some drivers round odd ones down and then don't fit.
        input.requestSize(width: width & ~1, height: height & ~1, scale: scale)
        if screen != nil {
            // Windows switches to it through its agent, as it does for the window. SPICE says itself.
            eventHandler?(.displaySizeRequested(width: width & ~1, height: height & ~1, scale: scale))
        }
    }

    public func setLiveDisplayResizing(_ enabled: Bool) {
        guard needsDisplayResizeSupport else { return }
        hasDisplayResizeSupport = enabled
        view.resizesGuest = enabled && configuration.display.automaticallyResizes
    }

    public func showPointer(_ cursor: GuestCursor?) {
        pointer = cursor
        screenViews.forEach { $0.show(pointer: cursor) }
    }

    public func afterDisplayUpdate(_ body: @escaping @MainActor () -> Void) {
        afterUpdate.append(body)
        // A display that doesn't change says nothing. SPICE's draws without saying at all: what the
        // guest says comes about a picture before the picture does.
        let wait: Duration = screen == nil ? .milliseconds(40) : .milliseconds(100)
        Task { [weak self] in
            try? await Task.sleep(for: wait)
            self?.displayDidUpdate()
        }
    }

    private func displayDidUpdate() {
        guard !afterUpdate.isEmpty else { return }
        let waiting = afterUpdate
        afterUpdate = []
        waiting.forEach { $0() }
    }

    // MARK: Host process

    public func hostProcessID() async -> pid_t? {
        hasExited ? nil : info.pid
    }

    // MARK: Lifecycle

    public var canSaveState: Bool { info.canSaveState }

    public var canRequestStop: Bool { isRunning }

    /// A request about this machine.
    private func request(_ command: String) -> QEMURequest {
        QEMURequest(command: command, machine: info.machine)
    }

    public func start(options: VMStartOptions) async throws {
        // A desktop that doesn't follow the display's size by itself is told by the machine.
        spice?.onSizeRequest = { [weak self] width, height, scale in
            self?.eventHandler?(.displaySizeRequested(width: width, height: height, scale: scale))
        }
        isLaunching = true
        defer { isLaunching = false }
        do {
            relayConsole()
            follower.start(service: service, machine: info.machine) { [weak self] exit in
                Task { @MainActor in self?.qemuDidExit(exit) }
            }
            if let spice {
                try await spice.open()
            } else if let screen {
                try await Task.detached { try screen.open() }.value
            }
            try await service.call(request("qemu-continue"))
            isRunning = true
        } catch {
            await tearDown()
            throw error
        }
    }

    public func requestStop() throws {
        guard isRunning else { throw VMError.notRunning(name: configuration.name) }
        let request = request("qemu-powerdown")
        let service = service
        Task { _ = try? await service.call(request) }
    }

    public func stop() async throws {
        guard !hasExited else { return }
        expectsExit = true
        isRunning = false
        do {
            try await service.call(request("qemu-stop"))
        } catch ServiceClientError.failed(let code, _) where code == "wrong-state" {
            // The service doesn't run it any more: it has ended.
        }
    }

    public func pause() async throws {
        try await service.call(request("qemu-pause"))
        isRunning = false
    }

    public func resume() async throws {
        try await service.call(request("qemu-resume"))
        isRunning = true
    }

    public func saveState(to url: URL) async throws {
        guard canSaveState else { throw QEMUError.refused("The GPU cannot save running graphics state.") }
        var request = request("qemu-save")
        request.path = url.path
        try await service.call(request)
    }

    /// QEMU has ended, as the service says. Says why, unless the app asked for it, or a start that
    /// fails says so itself.
    private func qemuDidExit(_ exit: QEMUExit?) {
        isRunning = false
        hasExited = true
        guard !expectsExit, exit?.expected != true, !isLaunching, !isTornDown, !hasReportedExit else { return }
        hasReportedExit = true
        switch exit?.reason {
        case "guest-reset":
            eventHandler?(.guestDidRestart)
        case "guest-shutdown", "guest-panic", "host-signal", "host-qmp-quit":
            eventHandler?(.guestDidStop)
        default:
            let said = exit?.message.map { " It said: \($0)" } ?? ""
            eventHandler?(.stoppedWithError("QEMU stopped unexpectedly.\(said)"))
        }
    }

    public func invalidate() {
        // The disks a QEMU that has gone was served are let go of at once. A guest that restarted is
        // started again right away, and two that hold one disk would each reclaim space the other uses.
        if hasExited {
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
        guard !isTornDown else { return }
        isTornDown = true
        isRunning = false
        expectsExit = true
        if !hasExited {
            var stop = request("qemu-stop")
            stop.force = true
            do {
                try await service.call(stop)
            } catch {
                NSLog("SwiftVM: QEMU of “\(configuration.name)” couldn't be stopped: \(error.localizedDescription)")
            }
        }
        follower.stop()
        screen?.close()
        spice?.close()
        consoleLine?.shutdown()
        consoleLine = nil
        if consoleEnd >= 0 {
            close(consoleEnd)
            consoleEnd = -1
        }
        let ports = ports
        self.ports = []
        for port in ports {
            await port.close()
        }
        closeDiskExports()
    }

    // MARK: Devices

    public func setNetworkInterface(_ id: UUID, connected: Bool) throws {
        guard let index = configuration.networkInterfaces.firstIndex(where: { $0.id == id }) else { return }
        var request = request("qemu-link")
        request.index = index
        request.connected = connected
        let service = service
        Task { _ = try? await service.call(request) }
    }

    /// Shared folders reach a Windows guest over the network, through its agent: QEMU has no part in it.
    public func setSharedFolders(_ folders: [SharedFolder]) throws {}

    public func attachRemovableImage(_ image: RemovableImage) async throws {
        var request = request("qemu-attach-image")
        request.image = QEMURequest.Image(id: image.id, path: image.path, readOnly: image.readOnly)
        try await service.call(request)
    }

    public func detachRemovableImage(_ id: UUID) async throws {
        var request = request("qemu-detach-image")
        request.imageId = id
        try await service.call(request)
    }

    public func setCapturesSystemKeys(_ capturesSystemKeys: Bool) {
        screenViews.forEach { $0.capturesSystemKeys = capturesSystemKeys }
    }

    // MARK: Guest socket

    public func connectToGuest(port: UInt32) async throws -> FileHandle {
        guard !hasExited else { throw VMError.notRunning(name: configuration.name) }
        var request = request("qemu-connect")
        request.port = port
        let service = service
        let descriptor = try await Task.detached {
            let connection = try service.connect()
            do {
                try connection.send(request)
                return connection.detach()
            } catch {
                connection.close()
                throw error
            }
        }.value
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    // MARK: The console

    /// Passes bytes between the console's line to QEMU and the machine's serial console.
    private func relayConsole() {
        guard consoleEnd >= 0 else { return }
        let line = consoleEnd
        consoleEnd = -1
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

    public func frame() async throws -> ScreenFrame {
        if let spice {
            guard let frame = ScreenFrame(png: try await spice.screenshot()) else { throw MachineDeskError.nothingShown }
            return frame
        }
        let request = request("qemu-frame")
        let service = service
        return try await Task.detached {
            let connection = try service.connect()
            defer { connection.close() }
            let answer: QEMUAnswer
            do {
                answer = try connection.send(request)
            } catch ServiceClientError.failed(let code, _) where code == "unavailable" {
                throw MachineDeskError.nothingShown
            }
            guard let frame = answer.frame, let pixels = connection.read(count: frame.length) else { throw MachineDeskError.nothingShown }
            return ScreenFrame(width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow, pixels: pixels)
        }.value
    }

    public func pointer(_ request: GuestPointer, guestTurnsWheel: Bool) async throws {
        var pointer = self.request("qemu-pointer")
        pointer.pointer = request
        // The service can't take a picture of a display the guest draws with the GPU, to learn its size.
        if let spice {
            guard spice.size.width > 0, spice.size.height > 0 else { throw MachineDeskError.nothingShown }
            pointer.size = QEMURequest.Size(width: Int(spice.size.width), height: Int(spice.size.height))
        }
        try await service.call(pointer)
    }

    public func keys(_ request: GuestJob.Keys) async throws {
        var keys = self.request("qemu-keys")
        keys.keys = request
        try await service.call(keys)
    }

    // MARK: Helpers

    private static func socketPair() throws -> (app: Int32, engine: Int32) {
        var ends: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        for end in ends {
            _ = fcntl(end, F_SETNOSIGPIPE, 1)
            _ = fcntl(end, F_SETFD, FD_CLOEXEC)
        }
        return (ends[0], ends[1])
    }
}

/// Reads the line the service tells how QEMU ended on. When the service stops before QEMU has, the line
/// ends without that: the next service has taken the machine on, and is asked to tell instead.
private final class EventFollower: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: ServiceConnection?
    private var isStopped = false

    init(connection: ServiceConnection) {
        self.connection = connection
    }

    /// Starts following, on a thread of its own. `ended` is called once, with how QEMU ended, or `nil`
    /// when nobody can tell any more.
    func start(service: QEMUService, machine: UUID, ended: @escaping @Sendable (QEMUExit?) -> Void) {
        Thread.detachNewThread { [self] in
            while let connection = lock.withLock({ isStopped ? nil : self.connection }) {
                while let line = connection.readLine() {
                    guard let event = try? JSONDecoder().decode(QEMUEvent.self, from: line), event.event == "qemu-exited" else { continue }
                    connection.close()
                    ended(event.exit)
                    return
                }
                connection.close()
                switch reattach(service: service, machine: machine) {
                case .following(let next):
                    let isStillWanted = lock.withLock {
                        guard !isStopped else { return false }
                        self.connection = next
                        return true
                    }
                    if !isStillWanted { next.close() }
                case .ended(let exit):
                    ended(exit)
                    return
                case .stopped:
                    return
                }
            }
        }
    }

    private enum Reattached {
        case following(ServiceConnection)
        case ended(QEMUExit?)
        case stopped
    }

    /// Asks the next service about the machine, while it starts.
    private func reattach(service: QEMUService, machine: UUID) -> Reattached {
        for _ in 0..<40 {
            guard !lock.withLock({ isStopped }) else { return .stopped }
            do {
                let connection = try service.connect()
                do {
                    let answer = try connection.send(QEMURequest(command: "qemu-attach", machine: machine))
                    if let exit = answer.exit {
                        connection.close()
                        return .ended(exit)
                    }
                    return .following(connection)
                } catch {
                    connection.close()
                    throw error
                }
            } catch ServiceClientError.failed {
                // It doesn't run the machine: QEMU ended while no service heard how.
                return .ended(nil)
            } catch {
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        return .ended(nil)
    }

    func stop() {
        let connection = lock.withLock {
            isStopped = true
            return self.connection
        }
        connection?.shutdown()
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
