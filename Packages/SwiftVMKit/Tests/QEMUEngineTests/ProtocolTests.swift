import Foundation
import GuestChannel
import Testing
@testable import QEMUEngine

/// Waits a few seconds at most for `signal`, on a thread that may wait.
private func waitBriefly(for signal: DispatchSemaphore, timeout: DispatchTime = .now() + 5) -> Bool {
    signal.wait(timeout: timeout) == .success
}

/// The other end of a socket pair, played by a test: QEMU, its VNC server, or a guest's agent.
private final class Peer: @unchecked Sendable {
    let descriptor: Int32

    init(_ descriptor: Int32) {
        self.descriptor = descriptor
        var seconds = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &seconds, socklen_t(MemoryLayout<timeval>.size))
    }

    deinit {
        close(descriptor)
    }

    static func pair() -> (app: Int32, peer: Peer) {
        var ends: [Int32] = [0, 0]
        socketpair(AF_UNIX, SOCK_STREAM, 0, &ends)
        return (ends[0], Peer(ends[1]))
    }

    func write(_ data: Data) {
        _ = ByteRelay.writeAll(ArraySlice(data), to: descriptor)
    }

    func write(_ text: String) {
        write(Data(text.utf8))
    }

    func read(_ count: Int) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: count)
        while data.count < count {
            let received = Darwin.read(descriptor, &buffer, count - data.count)
            guard received > 0 else { break }
            data.append(contentsOf: buffer[0..<received])
        }
        return data
    }

    func readLine() -> String {
        var line = Data()
        while true {
            let byte = read(1)
            guard let first = byte.first, first != UInt8(ascii: "\n") else { break }
            line.append(first)
        }
        return String(decoding: line, as: UTF8.self)
    }
}

@Suite struct QMPConnectionTests {
    @Test func answersCommandsAndPassesEventsOn() async throws {
        let (app, qemu) = Peer.pair()
        let connection = QMPConnection(descriptor: app)
        let events = EventLog()
        connection.onEvent = { events.add($0.name) }
        let server = Thread {
            qemu.write("{\"QMP\": {\"version\": {}, \"capabilities\": []}}\r\n")
            let capabilities = try? JSONSerialization.jsonObject(with: Data(qemu.readLine().utf8)) as? [String: Any]
            qemu.write("{\"return\": {}, \"id\": \(capabilities?["id"] ?? 0)}\r\n")
            let status = try? JSONSerialization.jsonObject(with: Data(qemu.readLine().utf8)) as? [String: Any]
            // An event arrives between a question and its answer.
            qemu.write("{\"event\": \"RESET\", \"data\": {}}\r\n")
            qemu.write("{\"return\": {\"status\": \"running\"}, \"id\": \(status?["id"] ?? 0)}\r\n")
            let bad = try? JSONSerialization.jsonObject(with: Data(qemu.readLine().utf8)) as? [String: Any]
            qemu.write("{\"error\": {\"class\": \"GenericError\", \"desc\": \"No such device\"}, \"id\": \(bad?["id"] ?? 0)}\r\n")
        }
        server.start()

        try await connection.open()
        let status = try await connection.execute("query-status")
        #expect(status["status"]?.string == "running")
        await #expect(throws: QEMUError.refused("No such device")) {
            try await connection.execute("device_del", ["id": "nothing"])
        }
        #expect(events.names == ["RESET"])
        connection.close()
    }

    @Test func tellsWhoWaitsThatQEMUHasGone() async throws {
        let (app, qemu) = Peer.pair()
        let connection = QMPConnection(descriptor: app)
        _ = qemu
        let opening = Task { try await connection.open() }
        shutdown(qemu.descriptor, SHUT_RDWR)
        await #expect(throws: QEMUError.disconnected) { try await opening.value }
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []

    func add(_ name: String) {
        lock.withLock { list.append(name) }
    }

    var names: [String] {
        lock.withLock { list }
    }
}

private final class CursorLog: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [RFBClient.Cursor?] = []

    func add(_ cursor: RFBClient.Cursor?) {
        lock.withLock { list.append(cursor) }
    }

    var events: [RFBClient.Cursor?] {
        lock.withLock { list }
    }
}

@Suite struct RFBClientTests {
    /// Plays a VNC server through its hello, for a display of `width` by `height`.
    private func greet(_ server: Peer, width: UInt16, height: UInt16) {
        server.write("RFB 003.008\n")
        _ = server.read(12)
        // One kind of security: none.
        server.write(Data([1, 1]))
        _ = server.read(1)
        server.write(Data([0, 0, 0, 0]))
        // The client's "shared" flag.
        _ = server.read(1)
        var initial = Data()
        initial.append(contentsOf: [UInt8(width >> 8), UInt8(width & 0xFF), UInt8(height >> 8), UInt8(height & 0xFF)])
        initial.append(Data(count: 16))
        initial.append(contentsOf: [0, 0, 0, 0])
        server.write(initial)
        // The pixel format, then the encodings: four bytes, and four for each.
        _ = server.read(20)
        let encodings = server.read(4)
        _ = server.read((Int(encodings[2]) << 8 | Int(encodings[3])) * 4)
    }

    private func rectangle(x: UInt16 = 0, y: UInt16 = 0, width: UInt16, height: UInt16, encoding: RFBClient.Encoding = .raw, payload: Data = Data()) -> Data {
        var data = Data()
        for value in [x, y, width, height] { data.append(bigEndian: value) }
        data.append(bigEndian: UInt32(bitPattern: encoding.rawValue))
        data.append(payload)
        return data
    }

    /// Reads the protocol payload back without IOSurface's row padding.
    private func pixels(in picture: RFBClient.Picture) -> Data {
        let surface = picture.surface
        surface.lock(options: .readOnly, seed: nil)
        defer {
            surface.unlock(options: .readOnly, seed: nil)
            withExtendedLifetime(picture) {}
        }
        var data = Data()
        for row in 0..<picture.height {
            data.append(Data(bytes: surface.baseAddress + row * surface.bytesPerRow, count: picture.width * 4))
        }
        return data
    }

    private func connectedDisplay(width: UInt16, height: UInt16) async throws -> (RFBClient, Peer) {
        let (app, server) = Peer.pair()
        let client = RFBClient(descriptor: app)
        let greeted = DispatchSemaphore(value: 0)
        let thread = Thread {
            self.greet(server, width: width, height: height)
            greeted.signal()
        }
        thread.start()
        try await Task.detached { try client.open() }.value
        try #require(await Task.detached { waitBriefly(for: greeted) }.value)
        #expect(server.read(10).prefix(2) == Data([3, 0]))
        return (client, server)
    }

    @Test func keepsRetainedPicturesUnchangedAfterPublication() async throws {
        let (client, server) = try await connectedDisplay(width: 2, height: 2)
        defer { client.close() }
        let updated = DispatchSemaphore(value: 0)
        client.onUpdate = { _ in updated.signal() }
        let first = Data(repeating: 17, count: 16)
        server.write(Data([0, 0, 0, 1]) + rectangle(width: 2, height: 2, payload: first))
        try #require(await Task.detached { waitBriefly(for: updated) }.value)
        let retained = try #require(client.picture)
        let second = Data(repeating: 29, count: 16)
        server.write(Data([0, 0, 0, 1]) + rectangle(width: 2, height: 2, payload: second))
        try #require(await Task.detached { waitBriefly(for: updated) }.value)
        #expect(pixels(in: retained) == first)
        #expect(pixels(in: try #require(client.picture)) == second)
    }

    @Test func recyclesSurfacesWithMissedDamageAndOverlappingCopies() async throws {
        let (client, server) = try await connectedDisplay(width: 4, height: 3)
        defer { client.close() }
        let updated = DispatchSemaphore(value: 0)
        client.onUpdate = { _ in updated.signal() }
        var expected = Data(count: 48)
        var surfaces = Set<ObjectIdentifier>()
        for index in 0..<9 {
            let x = index % 4, y = index / 4
            let pixel = Data(repeating: UInt8(index + 1), count: 4)
            expected.replaceSubrange(((y * 4 + x) * 4)..<((y * 4 + x + 1) * 4), with: pixel)
            server.write(Data([0, 0, 0, 1]) + rectangle(x: UInt16(x), y: UInt16(y), width: 1, height: 1, payload: pixel))
            try #require(await Task.detached { waitBriefly(for: updated) }.value)
            let picture = try #require(client.picture)
            surfaces.insert(ObjectIdentifier(picture.surface))
            #expect(pixels(in: picture) == expected)
        }
        #expect(surfaces.count == 3)
        let beforeCopy = expected
        for row in 1..<3 {
            expected.replaceSubrange(((row * 4 + 1) * 4)..<((row * 4 + 4) * 4), with: beforeCopy[((row - 1) * 16)..<((row - 1) * 16 + 12)])
        }
        server.write(Data([0, 0, 0, 1]) + rectangle(x: 1, y: 1, width: 3, height: 2, encoding: .copyRect, payload: Data([0, 0, 0, 0])))
        try #require(await Task.detached { waitBriefly(for: updated) }.value)
        #expect(pixels(in: try #require(client.picture)) == expected)
        // Copy upwards and leftwards too, after another pool slot has missed the previous copy.
        let beforeSecondCopy = expected
        for row in 0..<2 {
            expected.replaceSubrange((row * 16)..<(row * 16 + 12), with: beforeSecondCopy[((row + 1) * 16 + 4)..<((row + 2) * 16)])
        }
        server.write(Data([0, 0, 0, 1]) + rectangle(width: 3, height: 2, encoding: .copyRect, payload: Data([0, 1, 0, 1])))
        try #require(await Task.detached { waitBriefly(for: updated) }.value)
        #expect(pixels(in: try #require(client.picture)) == expected)
    }

    @Test func heldPicturesApplyBackpressureWithoutBlockingInputOrClose() async throws {
        let (client, server) = try await connectedDisplay(width: 1, height: 1)
        defer { client.close() }
        let updated = DispatchSemaphore(value: 0)
        let closed = DispatchSemaphore(value: 0)
        client.onUpdate = { _ in updated.signal() }
        client.onClose = { closed.signal() }
        var retained = [try #require(client.picture)]
        for value: UInt8 in [1, 2] {
            server.write(Data([0, 0, 0, 1]) + rectangle(width: 1, height: 1, payload: Data(repeating: value, count: 4)))
            try #require(await Task.detached { waitBriefly(for: updated) }.value)
            retained.append(try #require(client.picture))
            _ = server.read(10)
        }
        server.write(Data([0, 0, 0, 1]) + rectangle(width: 1, height: 1, payload: Data(repeating: 3, count: 4)))
        #expect(server.read(10).prefix(2) == Data([3, 1]))
        #expect(await Task.detached { !waitBriefly(for: updated, timeout: .now() + 0.05) }.value)
        client.key(0xCD, down: true)
        #expect(server.read(12) == Data([255, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0xCD]))
        #expect(pixels(in: retained[0]) == Data(count: 4))
        #expect(pixels(in: retained[1]) == Data(repeating: 1, count: 4))
        retained.removeFirst()
        try #require(await Task.detached { waitBriefly(for: updated) }.value)
        retained.append(try #require(client.picture))
        #expect(pixels(in: retained[2]) == Data(repeating: 3, count: 4))
        server.write(Data([0, 0, 0, 1]) + rectangle(width: 1, height: 1, payload: Data(repeating: 4, count: 4)))
        _ = server.read(10)
        #expect(await Task.detached { !waitBriefly(for: updated, timeout: .now() + 0.05) }.value)
        client.close()
        #expect(await Task.detached { waitBriefly(for: closed) }.value)
        #expect(!waitBriefly(for: updated, timeout: .now()))
        #expect(pixels(in: retained[2]) == Data(repeating: 3, count: 4))
    }

    @Test func resizingStartsANewPoolWhileOldPicturesAreHeld() async throws {
        let (client, server) = try await connectedDisplay(width: 1, height: 1)
        defer { client.close() }
        let updated = DispatchSemaphore(value: 0)
        client.onUpdate = { _ in updated.signal() }
        var retained = [try #require(client.picture)]
        for value: UInt8 in [1, 2] {
            server.write(Data([0, 0, 0, 1]) + rectangle(width: 1, height: 1, payload: Data(repeating: value, count: 4)))
            try #require(await Task.detached { waitBriefly(for: updated) }.value)
            retained.append(try #require(client.picture))
        }
        let pixel = Data([3, 4, 5, 0])
        server.write(Data([0, 0, 0, 2]) + rectangle(width: 2, height: 1, encoding: .desktopSize)
            + rectangle(x: 1, width: 1, height: 1, payload: pixel))
        try #require(await Task.detached { waitBriefly(for: updated) }.value)
        #expect(pixels(in: try #require(client.picture)) == Data(count: 4) + pixel)
        for (index, picture) in retained.enumerated() {
            #expect(picture.width == 1 && picture.height == 1)
            #expect(pixels(in: picture) == Data(repeating: UInt8(index), count: 4))
        }
    }

    @Test func neverPublishesCompleteRectanglesFromATruncatedFrame() async throws {
        let (client, server) = try await connectedDisplay(width: 2, height: 1)
        defer { client.close() }
        let updated = DispatchSemaphore(value: 0)
        let closed = DispatchSemaphore(value: 0)
        client.onUpdate = { _ in updated.signal() }
        client.onClose = { closed.signal() }
        let retained = try #require(client.picture)
        server.write(Data([0, 0, 0, 2]) + rectangle(width: 1, height: 1, payload: Data([1, 2, 3, 0]))
            + rectangle(x: 1, width: 1, height: 1, payload: Data([4, 5])))
        shutdown(server.descriptor, SHUT_WR)
        try #require(await Task.detached { waitBriefly(for: closed) }.value)
        #expect(!waitBriefly(for: updated, timeout: .now()))
        #expect(pixels(in: retained) == Data(count: 8))
        #expect(pixels(in: try #require(client.picture)) == Data(count: 8))
    }

    @Test func requestsNextFrameWhileReceivingFragmentedPixels() async throws {
        let (app, server) = Peer.pair()
        let client = RFBClient(descriptor: app)
        defer { client.close() }
        let updated = DispatchSemaphore(value: 0)
        client.onUpdate = { _ in updated.signal() }
        // Larger than the reader's buffer, with rows that need padding in IOSurface.
        let payload = Data((0..<(257 * 80 * 4)).map { UInt8(truncatingIfNeeded: $0 >> 4) })
        let thread = Thread {
            self.greet(server, width: 257, height: 80)
            _ = server.read(10)
            let header = Data([0, 0, 0, 1]) + self.rectangle(width: 257, height: 80)
            for byte in header { server.write(Data([byte])) }
            // Withhold the payload until the next request: waiting until the previous frame has
            // finished would stall here. This request must be incremental, to preserve dirty tracking.
            #expect(server.read(10) == Data([3, 1, 0, 0, 0, 0, 1, 1, 0, 80]))
            for start in stride(from: 0, to: payload.count, by: 997) {
                server.write(payload.subdata(in: start..<min(start + 997, payload.count)))
            }
        }
        thread.start()
        try await Task.detached { try client.open() }.value
        #expect(await Task.detached { waitBriefly(for: updated) }.value)
        #expect(pixels(in: try #require(client.picture)) == payload)
    }

    @Test func keepsBufferedFramesAlignedAcrossResizeDiscardAndOverlappingCopy() async throws {
        let (app, server) = Peer.pair()
        let client = RFBClient(descriptor: app)
        defer { client.close() }
        let updated = DispatchSemaphore(value: 0)
        let requested = DispatchSemaphore(value: 0)
        client.onUpdate = { _ in updated.signal() }
        let payload = Data((0..<(7 * 5 * 4)).map { UInt8($0) })
        let lastPixel = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let thread = Thread {
            self.greet(server, width: 4, height: 2)
            _ = server.read(10)
            var frames = Data([0, 0, 0, 4])
            frames += self.rectangle(width: 7, height: 5, encoding: .desktopSize)
            // A stale rectangle outside the new bounds must be consumed without losing the next
            // header, even when its payload is larger than the receive buffer.
            frames += self.rectangle(x: 10, width: 2, height: 9000, payload: Data(count: 72_000))
            frames += self.rectangle(width: 7, height: 5, payload: payload)
            frames += self.rectangle(x: 1, y: 1, width: 6, height: 4, encoding: .copyRect, payload: Data([0, 0, 0, 0]))
            frames += Data([0, 0, 0, 1])
            frames += self.rectangle(x: 6, y: 4, width: 1, height: 1, payload: lastPixel)
            server.write(frames)
            #expect(server.read(10) == Data([3, 1, 0, 0, 0, 0, 0, 4, 0, 2]))
            // Resizing needs a full refresh with the new bounds, including the newly exposed area.
            #expect(server.read(10) == Data([3, 0, 0, 0, 0, 0, 0, 7, 0, 5]))
            #expect(server.read(10) == Data([3, 1, 0, 0, 0, 0, 0, 7, 0, 5]))
            requested.signal()
        }
        thread.start()
        try await Task.detached { try client.open() }.value
        #expect(await Task.detached { waitBriefly(for: updated) && waitBriefly(for: updated) && waitBriefly(for: requested) }.value)
        var expected = payload
        for row in 1..<5 {
            let destination = (row * 7 + 1) * 4
            let source = (row - 1) * 7 * 4
            expected.replaceSubrange(destination..<(destination + 24), with: payload[source..<(source + 24)])
        }
        expected.replaceSubrange(136..<140, with: lastPixel)
        #expect(pixels(in: try #require(client.picture)) == expected)
    }

    @Test func disconnectsWithoutPublishingAnIncompleteRectangle() async throws {
        let (app, server) = Peer.pair()
        let client = RFBClient(descriptor: app)
        defer { client.close() }
        let closed = DispatchSemaphore(value: 0)
        let updated = DispatchSemaphore(value: 0)
        client.onClose = { closed.signal() }
        client.onUpdate = { _ in updated.signal() }
        let thread = Thread {
            self.greet(server, width: 8, height: 8)
            _ = server.read(10)
            server.write(Data([0, 0, 0, 1]) + self.rectangle(width: 8, height: 8, payload: Data(count: 17)))
            shutdown(server.descriptor, SHUT_WR)
        }
        thread.start()
        try await Task.detached { try client.open() }.value
        #expect(await Task.detached { waitBriefly(for: closed) }.value)
        #expect(!waitBriefly(for: updated, timeout: .now()))
    }

    @Test func drawsWhatTheServerSendsIntoThePicture() async throws {
        let (app, server) = Peer.pair()
        let client = RFBClient(descriptor: app)
        let updated = DispatchSemaphore(value: 0)
        client.onUpdate = { _ in updated.signal() }
        let thread = Thread {
            self.greet(server, width: 4, height: 2)
            _ = server.read(10)
            // One rectangle of two pixels at (1, 1), sent as they are.
            var update = Data([0, 0, 0, 1, 0, 1, 0, 1, 0, 2, 0, 1, 0, 0, 0, 0])
            update.append(contentsOf: [0x11, 0x22, 0x33, 0, 0x44, 0x55, 0x66, 0])
            server.write(update)
        }
        thread.start()

        try await Task.detached { try client.open() }.value
        #expect(await Task.detached { waitBriefly(for: updated) }.value)
        let picture = try #require(client.picture)
        #expect(picture.width == 4 && picture.height == 2)
        picture.surface.lock(options: .readOnly, seed: nil)
        let row = picture.surface.baseAddress + picture.surface.bytesPerRow
        let pixels = Data(bytes: row + 4, count: 8)
        picture.surface.unlock(options: .readOnly, seed: nil)
        #expect(pixels == Data([0x11, 0x22, 0x33, 0, 0x44, 0x55, 0x66, 0]))
        client.close()
    }

    @Test(arguments: [RFBClient.Encoding.alphaCursor, .cursor])
    func keepsCursorPayloadsAndVisibilityInStepWithTheFramebuffer(_ encoding: RFBClient.Encoding) async throws {
        let (app, server) = Peer.pair()
        let client = RFBClient(descriptor: app)
        defer { client.close() }
        let cursors = CursorLog()
        let updated = DispatchSemaphore(value: 0)
        client.onCursor = { cursors.add($0) }
        client.onUpdate = { _ in updated.signal() }
        // QEMU sends native ARGB words, blue first on this Mac, even for AlphaCursor. The alpha
        // payload is not in the client's negotiated pixel format and has no separate mask.
        let alpha = encoding == .alphaCursor
        let prefix = alpha ? Data([0, 0, 0, 0]) : Data()
        let shape = prefix + Data([160, 64, 32, 128, 9, 8, 7, 0]) + (alpha ? Data() : Data([0x80]))
        let thread = Thread {
            self.greet(server, width: 8, height: 8)
            _ = server.read(10)
            var update = Data([0, 0, 0, 4])
            update += self.rectangle(x: 1, width: 2, height: 1, encoding: encoding, payload: shape)
            update += self.rectangle(width: 0, height: 0, encoding: encoding, payload: prefix)
            update += self.rectangle(x: 1, width: 2, height: 1, encoding: encoding, payload: shape)
            update += self.rectangle(width: 1, height: 1, payload: Data([1, 2, 3, 0]))
            server.write(update)
        }
        thread.start()
        try await Task.detached { try client.open() }.value
        #expect(await Task.detached { waitBriefly(for: updated) }.value)
        let events = cursors.events
        try #require(events.count == 3)
        #expect(events[1] == nil)
        for index in [0, 2] {
            let cursor = try #require(events[index])
            #expect(cursor.hotSpot == CGPoint(x: 1, y: 0))
            let bytes = try #require(cursor.image.dataProvider?.data) as Data
            #expect(bytes == (alpha ? Data([80, 32, 16, 128, 0, 0, 0, 0]) : Data([160, 64, 32, 255, 0, 0, 0, 0])))
        }
        #expect(pixels(in: try #require(client.picture)).prefix(4) == Data([1, 2, 3, 0]))
    }

    @Test func pressesKeysByTheirPlaceOnAPCKeyboard() async throws {
        let (app, server) = Peer.pair()
        let client = RFBClient(descriptor: app)
        let greeted = DispatchSemaphore(value: 0)
        // The server reads on one thread only: what the client sends while greeting would otherwise go
        // to whichever thread reads first.
        let thread = Thread {
            self.greet(server, width: 8, height: 8)
            // The request for the first picture.
            _ = server.read(10)
            greeted.signal()
        }
        thread.start()
        try await Task.detached { try client.open() }.value
        #expect(await Task.detached { waitBriefly(for: greeted) }.value)

        // The right arrow is 0xE0 0x4D on a PC, and QEMU numbers it 0xCD.
        client.key(PCKeys.scancode(forMacKey: 0x7C)!, down: true)
        let message = server.read(12)
        #expect(message == Data([255, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0xCD]))
        client.close()
    }

    @Test func receivesFragmentedRectanglesAcrossReadBatches() async throws {
        let (app, server) = Peer.pair()
        let client = RFBClient(descriptor: app)
        defer { client.close() }
        let updated = DispatchSemaphore(value: 0)
        client.onUpdate = { _ in updated.signal() }
        // More than one receive batch, offset within a surface whose rows have padding.
        let width = 513, height = 1025
        let payload = Data((0..<(width * height * 4)).map { UInt8(truncatingIfNeeded: $0 / 7) })
        let thread = Thread {
            self.greet(server, width: 516, height: 1027)
            _ = server.read(10)
            var update = Data([0, 0, 0, 1])
            for value: UInt16 in [1, 1, UInt16(width), UInt16(height)] { update.append(bigEndian: value) }
            update.append(bigEndian: UInt32(0))
            update.append(payload)
            // Socket reads need not match either a row or the staging buffer's boundary.
            for offset in stride(from: 0, to: update.count, by: 7919) {
                server.write(update.subdata(in: offset..<min(offset + 7919, update.count)))
            }
            _ = server.read(10)
            // A following update proves that consuming the rectangle preserved message boundaries.
            server.write(Data([0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 9, 8, 7, 0]))
        }
        thread.start()

        try await Task.detached { try client.open() }.value
        #expect(await Task.detached { waitBriefly(for: updated) && waitBriefly(for: updated) }.value)
        let picture = try #require(client.picture)
        picture.surface.lock(options: .readOnly, seed: nil)
        defer { picture.surface.unlock(options: .readOnly, seed: nil) }
        var received = Data()
        for row in 0..<height {
            received.append(Data(bytes: picture.surface.baseAddress + (row + 1) * picture.surface.bytesPerRow + 4, count: width * 4))
        }
        #expect(received == payload)
        #expect(Data(bytes: picture.surface.baseAddress, count: 4) == Data([9, 8, 7, 0]))
    }

    @Test func closesWhenTheServerDisconnectsDuringARectangle() async throws {
        let (app, server) = Peer.pair()
        let client = RFBClient(descriptor: app)
        defer { client.close() }
        let closed = DispatchSemaphore(value: 0)
        client.onClose = { closed.signal() }
        let thread = Thread {
            self.greet(server, width: 512, height: 1024)
            _ = server.read(10)
            var update = Data([0, 0, 0, 1, 0, 0, 0, 0, 2, 0, 4, 0, 0, 0, 0, 0])
            // One complete batch, then part of the next; waiting for the rest must end on EOF.
            update.append(Data(count: (1 << 20) + 17))
            server.write(update)
            shutdown(server.descriptor, SHUT_RDWR)
        }
        thread.start()

        try await Task.detached { try client.open() }.value
        #expect(await Task.detached { waitBriefly(for: closed) }.value)
    }

    @Test func keepsTheLatestSizeRequestedBeforeResizeNegotiation() async throws {
        let (app, server) = Peer.pair()
        let client = RFBClient(descriptor: app)
        defer { client.close() }
        client.requestSize(width: 2048, height: 1152)
        client.requestSize(width: 5120, height: 2880)
        // The handshake is read to its end before this test reads on: `open` can return while the
        // encodings it sent are still unread, and they would be read here instead.
        let greeted = DispatchSemaphore(value: 0)
        let thread = Thread {
            self.greet(server, width: 640, height: 480)
            greeted.signal()
        }
        thread.start()
        try await Task.detached { try client.open() }.value
        #expect(await Task.detached { waitBriefly(for: greeted) }.value)
        // Neither size may be sent until the server supports resizing.
        #expect(server.read(10) == Data([3, 0, 0, 0, 0, 0, 2, 128, 1, 224]))

        func desktopSize(width: UInt16, height: UInt16) -> Data {
            var update = Data([0, 0, 0, 1, 0, 0, 0, 0])
            update.append(bigEndian: width)
            update.append(bigEndian: height)
            update.append(bigEndian: UInt32(bitPattern: RFBClient.Encoding.extendedDesktopSize.rawValue))
            update.append(contentsOf: [1, 0, 0, 0])
            update.append(bigEndian: UInt32(42))
            update.append(contentsOf: [0, 0, 0, 0])
            update.append(bigEndian: width)
            update.append(bigEndian: height)
            update.append(bigEndian: UInt32(0))
            return update
        }

        server.write(desktopSize(width: 640, height: 480))
        // The next update is asked for before this one is read, and then the latest size goes out.
        #expect(server.read(10) == Data([3, 1, 0, 0, 0, 0, 2, 128, 1, 224]))
        #expect(server.read(24) == Data([251, 0, 20, 0, 11, 64, 1, 0, 0, 0, 0, 42, 0, 0, 0, 0, 20, 0, 11, 64, 0, 0, 0, 0]))
        server.write(desktopSize(width: 5120, height: 2880))
        #expect(server.read(10) == Data([3, 1, 0, 0, 0, 0, 2, 128, 1, 224]))
        // Acknowledging a size must not send it again and start a resize feedback loop: what follows is
        // a request for the whole picture at the new size.
        #expect(server.read(10) == Data([3, 0, 0, 0, 0, 0, 20, 0, 11, 64]))
    }
}

@Suite struct AgentChannelTests {
    /// Plays a guest's agent: reads the app's frames and answers them.
    private final class Guest: @unchecked Sendable {
        let peer: Peer
        private var reader = ChannelFrame.Reader()
        private var pending: [ChannelFrame] = []

        init(_ peer: Peer) {
            self.peer = peer
        }

        func send(_ frame: ChannelFrame) {
            peer.write(frame.encoded)
        }

        func next() -> ChannelFrame? {
            while pending.isEmpty {
                let bytes = peer.read(1)
                guard !bytes.isEmpty else { return nil }
                pending += reader.receive(bytes)
            }
            return pending.removeFirst()
        }
    }

    @Test func carriesAConnectionBothWaysAndEachWayEndsByItself() async throws {
        let (app, peer) = Peer.pair()
        let guest = Guest(peer)
        let channel = AgentChannel(descriptor: app)
        channel.start()
        // The app says hello first, and the agent answers in kind.
        #expect(guest.next()?.kind == .hello)
        await #expect(throws: AgentChannel.ChannelError.self) { _ = try await channel.connect(port: 717, timeout: 1) }
        guest.send(.hello)
        try await Task.sleep(for: .milliseconds(100))

        let answering = Thread {
            guard let open = guest.next(), open.kind == .open, open.port == 718 else { return }
            guest.send(ChannelFrame(.accept, connection: open.connection))
            guard let data = guest.next(), data.kind == .data else { return }
            guest.send(ChannelFrame(.data, connection: open.connection, payload: Data("got ".utf8) + data.payload))
            // The agent says it is done sending, and listens for the app to hang up.
            guest.send(ChannelFrame(.end, connection: open.connection))
        }
        answering.start()

        let connection = try await channel.connect(port: 718, timeout: 2)
        try connection.write(contentsOf: Data("job".utf8))
        let answer = try connection.readToEnd() ?? Data()
        #expect(String(decoding: answer, as: UTF8.self) == "got job")
        // Hanging up reaches the guest.
        try connection.close()
        let closing = guest.next()
        #expect(closing?.kind == .end || closing?.kind == .close)
        channel.close()
    }

    @Test func saysWhenNothingListensOnAPort() async throws {
        let (app, peer) = Peer.pair()
        let guest = Guest(peer)
        let channel = AgentChannel(descriptor: app)
        channel.start()
        _ = guest.next()
        guest.send(.hello)
        try await Task.sleep(for: .milliseconds(100))
        let refusing = Thread {
            guard let open = guest.next() else { return }
            guest.send(ChannelFrame(.refuse, connection: open.connection))
        }
        refusing.start()
        await #expect(throws: AgentChannel.ChannelError.self) { _ = try await channel.connect(port: 9, timeout: 2) }
        channel.close()
    }
}
