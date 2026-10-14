import Foundation
import Testing
import VMCore
@testable import DiskTools

/// A compressed disk in a folder of its own, next to what it should hold.
private final class Fixture {
    let folder: URL
    let url: URL
    var expected: [UInt8]
    private var seed: UInt64 = 0x9E37_79B9_7F4A_7C15

    init(capacity: Int) throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "swiftvm-compressed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appending(path: "disk.\(CompressedDisk.fileExtension)")
        expected = [UInt8](repeating: 0, count: capacity)
        try CompressedDisk.create(at: url, capacity: UInt64(capacity))
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    func open() throws -> CompressedDisk {
        try CompressedDisk(url: url, commitInterval: nil)
    }

    /// Bytes that don't compress.
    func noise(_ count: Int) -> [UInt8] {
        (0..<count).map { _ in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: seed >> 33)
        }
    }

    /// Bytes that compress well, and differ with `tag`.
    func text(_ count: Int, tag: Int) -> [UInt8] {
        let line = Array("cluster \(tag) holds this line over and over, as files do. ".utf8)
        return (0..<count).map { line[$0 % line.count] }
    }

    func write(_ bytes: [UInt8], at offset: Int, to disk: CompressedDisk) throws {
        try bytes.withUnsafeBytes { try disk.write(at: UInt64(offset), from: $0) }
        expected.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }

    func contents(of disk: CompressedDisk) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0xAA, count: expected.count)
        try bytes.withUnsafeMutableBytes { try disk.read(at: 0, into: $0) }
        return bytes
    }

    /// What the journal's part of the file holds.
    func journal() throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(2 * CompressedDisk.blockSize))
        return try #require(try handle.read(upToCount: (CompressedDisk.guardBlock - 2) * CompressedDisk.blockSize))
    }

    /// Puts back what the journal held at an earlier time, lines that were tidied away since included.
    func putBack(journal: Data) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(2 * CompressedDisk.blockSize))
        try handle.write(contentsOf: journal)
    }

    /// Bytes the file occupies. Asked of the file itself: a `URL` remembers what it answered before.
    var allocated: Int {
        var info = stat()
        return stat(url.path, &info) == 0 ? Int(info.st_blocks) * 512 : 0
    }
}

private let cluster = CompressedDisk.clusterSize

@Suite struct CompressedDiskTests {
    @Test func keepsWhatIsWrittenAndGrows() throws {
        let fixture = try Fixture(capacity: 8 * cluster)
        var disk = try fixture.open()
        try fixture.write(fixture.text(3 * cluster, tag: 1), at: 0, to: disk)
        try fixture.write(fixture.noise(cluster), at: 3 * cluster, to: disk)
        // Across two clusters, neither of them whole, and on no block's edge.
        try fixture.write(fixture.noise(5000), at: cluster - 700, to: disk)
        try fixture.write(fixture.text(999, tag: 2), at: 6 * cluster + 13, to: disk)
        try fixture.write([UInt8](repeating: 0, count: cluster), at: 2 * cluster, to: disk)
        #expect(try fixture.contents(of: disk) == fixture.expected)
        try disk.close()

        disk = try fixture.open()
        #expect(disk.replayedChanges == 0)
        #expect(try fixture.contents(of: disk) == fixture.expected)

        // Far enough to need more pages of the map.
        let grown = 1200 * cluster + 512
        try disk.grow(to: UInt64(grown))
        fixture.expected.append(contentsOf: [UInt8](repeating: 0, count: grown - fixture.expected.count))
        try fixture.write(fixture.text(3000, tag: 3), at: grown - 3000, to: disk)
        try disk.close()

        #expect(try CompressedDisk.capacity(of: fixture.url) == UInt64(grown))
        disk = try fixture.open()
        #expect(try fixture.contents(of: disk) == fixture.expected)
        try disk.close()
    }

    @Test func losesNothingWhenTheAppGoesDown() throws {
        let fixture = try Fixture(capacity: 16 * cluster)
        var disk = try fixture.open()
        try fixture.write(fixture.text(4 * cluster, tag: 1), at: 0, to: disk)
        try disk.flush()
        try fixture.write(fixture.noise(2 * cluster), at: cluster, to: disk)
        try fixture.write(fixture.text(100, tag: 2), at: 9 * cluster + 5, to: disk)
        try disk.discard(at: 0, length: UInt64(cluster))
        fixture.expected.replaceSubrange(0..<cluster, with: [UInt8](repeating: 0, count: cluster))
        disk.abandon()

        disk = try fixture.open()
        #expect(disk.replayedChanges == 4)
        #expect(try fixture.contents(of: disk) == fixture.expected)

        // Once more, over the same clusters: what the first time left in the journal mustn't come back.
        try fixture.write(fixture.text(3 * cluster, tag: 3), at: 0, to: disk)
        try fixture.write(fixture.noise(700), at: 9 * cluster, to: disk)
        disk.abandon()

        disk = try fixture.open()
        #expect(try fixture.contents(of: disk) == fixture.expected)
        try disk.close()
        disk = try fixture.open()
        #expect(disk.replayedChanges == 0)
        #expect(try fixture.contents(of: disk) == fixture.expected)
        try disk.close()
    }

    /// When the Mac goes down, data that was on its way may not be in the file while the journal's line
    /// about it is. The disk then has to be as it was just before that line, and no later.
    @Test func comesBackAsItWasBeforeDataThatNeverArrived() throws {
        let fixture = try Fixture(capacity: 8 * cluster)
        var disk = try fixture.open()
        try fixture.write(fixture.text(4 * cluster, tag: 1), at: 0, to: disk)
        try disk.flush()

        try fixture.write(fixture.noise(cluster), at: 0, to: disk)
        let before = fixture.expected
        try fixture.write(fixture.noise(cluster), at: cluster, to: disk)
        try fixture.write(fixture.noise(cluster), at: 2 * cluster, to: disk)
        let lost = try #require(disk.placement(ofCluster: 1))
        disk.abandon()

        let handle = try FileHandle(forWritingTo: fixture.url)
        try handle.seek(toOffset: UInt64(lost.offset))
        try handle.write(contentsOf: Data(repeating: 0, count: lost.length))
        try handle.close()

        disk = try fixture.open()
        #expect(disk.replayedChanges == 1)
        #expect(try fixture.contents(of: disk) == before)
        try disk.close()
    }

    @Test(arguments: [CompressedDisk.CommitStep.mapWritten, .mapSynchronized, .superblockWritten])
    func survivesACommitThatFails(at step: CompressedDisk.CommitStep) throws {
        let fixture = try Fixture(capacity: 8 * cluster)
        var disk = try fixture.open()
        try fixture.write(fixture.text(2 * cluster, tag: 1), at: 0, to: disk)
        try disk.flush()
        try fixture.write(fixture.noise(cluster + 10), at: cluster, to: disk)

        disk.commitFault = step
        #expect(throws: CompressedDisk.DiskError.self) { try disk.flush() }
        // The guest carries on while the commit is still owed.
        try fixture.write(fixture.text(300, tag: 2), at: 5 * cluster, to: disk)
        #expect(try fixture.contents(of: disk) == fixture.expected)
        disk.abandon()

        disk = try fixture.open()
        #expect(try fixture.contents(of: disk) == fixture.expected)

        // And a commit that fails and then gets through leaves a disk that closes and opens as usual.
        try fixture.write(fixture.noise(cluster), at: 0, to: disk)
        disk.commitFault = step
        #expect(throws: CompressedDisk.DiskError.self) { try disk.flush() }
        disk.commitFault = nil
        try fixture.write(fixture.text(cluster, tag: 3), at: 3 * cluster, to: disk)
        try disk.close()
        disk = try fixture.open()
        #expect(disk.replayedChanges == 0)
        #expect(try fixture.contents(of: disk) == fixture.expected)
        try disk.close()
    }

    /// The open after a crash writes to the file itself. Cut short, it has to leave everything in
    /// place that the next open goes by, and what it has brought back must never be followed again.
    @Test(arguments: [CompressedDisk.CommitStep.mapWritten, .mapSynchronized, .superblockWritten])
    func anOpenThatIsCutShortLosesNothing(at step: CompressedDisk.CommitStep) throws {
        let fixture = try Fixture(capacity: 8 * cluster)
        var disk = try fixture.open()
        try fixture.write(fixture.noise(2 * cluster), at: 0, to: disk)
        try disk.flush()
        // Changes that replace what the last commit holds, and each other.
        try fixture.write(fixture.noise(cluster), at: cluster, to: disk)
        try fixture.write(fixture.noise(cluster), at: cluster, to: disk)
        try disk.discard(at: 0, length: UInt64(cluster))
        fixture.expected.replaceSubrange(0..<cluster, with: [UInt8](repeating: 0, count: cluster))
        // And a commit that is still owed when the app goes down, with changes after it.
        disk.commitFault = .mapWritten
        #expect(throws: CompressedDisk.DiskError.self) { try disk.flush() }
        try fixture.write(fixture.noise(cluster), at: cluster, to: disk)
        try fixture.write(fixture.text(500, tag: 1), at: 3 * cluster, to: disk)
        disk.abandon()
        let journal = try fixture.journal()

        #expect(throws: CompressedDisk.DiskError.self) {
            _ = try CompressedDisk(url: fixture.url, readOnly: false, commitInterval: nil, failingAt: step)
        }
        disk = try fixture.open()
        #expect(try fixture.contents(of: disk) == fixture.expected)
        disk.abandon()

        // As if the journal had never been tidied after that.
        try fixture.putBack(journal: journal)
        disk = try fixture.open()
        #expect(disk.replayedChanges == 0)
        #expect(try fixture.contents(of: disk) == fixture.expected)
        try fixture.write(fixture.noise(cluster), at: cluster, to: disk)
        try disk.close()
        disk = try fixture.open()
        #expect(try fixture.contents(of: disk) == fixture.expected)
        try disk.close()
    }

    @Test func callsNoWriteDoneThatTheJournalDoesNotCover() throws {
        let fixture = try Fixture(capacity: 64 * cluster)
        var disk = try fixture.open()
        try fixture.write(fixture.text(cluster, tag: 1), at: 0, to: disk)

        disk.journalFault = true
        let noise = fixture.noise(cluster)
        let done = UnsafeMutablePointer<Bool>.allocate(capacity: 32)
        done.initialize(repeating: false, count: 32)
        defer { done.deallocate() }
        let results = SendablePointer(done)
        let writing = disk
        // Many at once, so that one writes the lines of the others: none of them may be told it is done.
        DispatchQueue.concurrentPerform(iterations: 32) { writer in
            results.pointer[writer] = (try? noise.withUnsafeBytes { try writing.write(at: UInt64((writer + 1) * cluster), from: $0) }) != nil
        }
        #expect((0..<32).allSatisfy { !done[$0] })

        // A commit starts the journal anew, and what is on the disk then stays, the app going down or not.
        disk.journalFault = false
        try disk.flush()
        fixture.expected = try fixture.contents(of: disk)
        try fixture.write(fixture.text(900, tag: 2), at: 40 * cluster, to: disk)
        disk.abandon()
        disk = try fixture.open()
        #expect(disk.replayedChanges == 1)
        #expect(try fixture.contents(of: disk) == fixture.expected)
        try disk.close()
    }

    @Test func takesLessSpaceAndGivesItBack() throws {
        let megabyte = 1 << 20
        let fixture = try Fixture(capacity: 64 * megabyte)
        var disk = try fixture.open()
        try fixture.write(fixture.text(24 * megabyte, tag: 1), at: 0, to: disk)
        try fixture.write(fixture.noise(8 * megabyte), at: 32 * megabyte, to: disk)
        try disk.close()
        // The text shrinks to a fraction, the noise stays as large as it is.
        #expect(fixture.allocated > 8 * megabyte)
        #expect(fixture.allocated < 12 * megabyte)

        disk = try fixture.open()
        // Writing the same place again and again must not make the file grow.
        for _ in 0..<4 {
            try fixture.write(fixture.noise(8 * megabyte), at: 32 * megabyte, to: disk)
            try disk.flush()
        }
        try disk.discard(at: UInt64(megabyte), length: UInt64(60 * megabyte))
        try disk.close()
        #expect(fixture.allocated < 2 * megabyte)

        disk = try fixture.open()
        fixture.expected.replaceSubrange(megabyte..<(61 * megabyte), with: [UInt8](repeating: 0, count: 60 * megabyte))
        #expect(try fixture.contents(of: disk) == fixture.expected)
        try disk.close()
    }

    @Test func servesManyWritersAtOnce() throws {
        let fixture = try Fixture(capacity: 256 * cluster)
        let disk = try CompressedDisk(url: fixture.url, commitInterval: 0.01)
        let workers = 8
        let region = fixture.expected.count / workers
        // Each worker has a part of the disk to itself and checks it as it goes; all of them share the
        // map, the journal and the commits that run meanwhile.
        let parts: [[UInt8]] = (0..<workers).map { fixture.text(region, tag: $0) }
        let results = UnsafeMutablePointer<Bool>.allocate(capacity: workers)
        results.initialize(repeating: false, count: workers)
        defer { results.deallocate() }
        let failures = SendablePointer(results)
        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            var mine = [UInt8](repeating: 0, count: region)
            var seed = UInt64(worker) &* 0x9E37_79B9 &+ 12345
            func next(_ limit: Int) -> Int {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Int(seed >> 33) % limit
            }
            do {
                for round in 0..<300 {
                    let length = 1 + next(3 * cluster)
                    let offset = next(region - length)
                    let bytes = Array(parts[worker][offset..<(offset + length)].map { $0 &+ UInt8(truncatingIfNeeded: round) })
                    try bytes.withUnsafeBytes { try disk.write(at: UInt64(worker * region + offset), from: $0) }
                    mine.replaceSubrange(offset..<(offset + length), with: bytes)
                    if round % 16 == 0 {
                        var read = [UInt8](repeating: 0, count: region)
                        try read.withUnsafeMutableBytes { try disk.read(at: UInt64(worker * region), into: $0) }
                        guard read == mine else { return }
                    }
                }
                var read = [UInt8](repeating: 0, count: region)
                try read.withUnsafeMutableBytes { try disk.read(at: UInt64(worker * region), into: $0) }
                failures.pointer[worker] = read == mine
            } catch {}
        }
        #expect((0..<workers).allSatisfy { results[$0] })
        let live = try fixture.contents(of: disk)
        try disk.close()

        let reopened = try fixture.open()
        #expect(try fixture.contents(of: reopened) == live)
        try reopened.close()
    }
}

private struct SendablePointer: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<Bool>
    init(_ pointer: UnsafeMutablePointer<Bool>) { self.pointer = pointer }
}

/// The other end of the line: what the Virtualization framework is to a disk's server.
private final class BlockDeviceClient {
    private let descriptor: Int32
    private(set) var size: UInt64 = 0
    private var cookie: UInt64 = 0

    init(connectingTo url: URL) throws {
        let path = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "socket" }?.value)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(connected == 0)

        _ = try receive(18)
        try send(bytes(UInt32(3)))
        // "Let's go", for the disk without a name and with nothing more to ask.
        try send(bytes(UInt64(0x4948_4156_454F_5054)) + bytes(UInt32(7)) + bytes(UInt32(6)) + bytes(UInt32(0)) + bytes(UInt16(0)))
        while true {
            let head = try receive(20)
            let type = integer(head[12..<16], as: UInt32.self)
            let data = try receive(Int(integer(head[16..<20], as: UInt32.self)))
            if type == 3, integer(data[0..<2], as: UInt16.self) == 0 { size = integer(data[2..<10], as: UInt64.self) }
            if type == 1 { break }
            try #require(type == 3)
        }
    }

    deinit { close(descriptor) }

    private func bytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] { withUnsafeBytes(of: value.bigEndian) { Array($0) } }
    private func integer<T: FixedWidthInteger>(_ bytes: ArraySlice<UInt8>, as type: T.Type) -> T { bytes.reduce(T(0)) { $0 << 8 | T($1) } }

    private func send(_ bytes: [UInt8]) throws {
        var done = 0
        while done < bytes.count {
            let put = bytes[done...].withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            try #require(put > 0)
            done += put
        }
    }

    private func receive(_ count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var done = 0
        while done < count {
            let got = bytes.withUnsafeMutableBytes { read(descriptor, $0.baseAddress! + done, count - done) }
            try #require(got > 0)
            done += got
        }
        return bytes
    }

    /// Sends a request and returns the error the server answers with, 0 for none, and what it read.
    func request(_ command: UInt16, at offset: UInt64, length: Int, data: [UInt8] = []) throws -> (error: UInt32, data: [UInt8]) {
        cookie += 1
        try send(bytes(UInt32(0x2560_9513)) + bytes(UInt16(0)) + bytes(command) + bytes(cookie) + bytes(offset) + bytes(UInt32(length)) + data)
        let head = try receive(16)
        #expect(integer(head[8..<16], as: UInt64.self) == cookie)
        let error = integer(head[4..<8], as: UInt32.self)
        return (error, command == 0 && error == 0 ? try receive(length) : [])
    }
}

@Suite struct CompressedDiskServingTests {
    @Test func servesADiskOverItsSocket() throws {
        let fixture = try Fixture(capacity: 64 * cluster)
        let export = try CompressedDiskExport(diskAt: fixture.url, readOnly: false)
        let client = try BlockDeviceClient(connectingTo: export.url)
        #expect(client.size == UInt64(fixture.expected.count))

        let text = fixture.text(100_000, tag: 1)
        #expect(try client.request(1, at: 5000, length: text.count, data: text).error == 0)
        fixture.expected.replaceSubrange(5000..<(5000 + text.count), with: text)
        #expect(try client.request(0, at: 4096, length: 3 * cluster).data == Array(fixture.expected[4096..<(4096 + 3 * cluster)]))

        // Zeros over a part of a cluster, then a trim of a whole one, then a flush.
        #expect(try client.request(6, at: 6000, length: 1000).error == 0)
        fixture.expected.replaceSubrange(6000..<7000, with: [UInt8](repeating: 0, count: 1000))
        #expect(try client.request(4, at: UInt64(cluster), length: cluster).error == 0)
        fixture.expected.replaceSubrange(cluster..<(2 * cluster), with: [UInt8](repeating: 0, count: cluster))
        #expect(try client.request(3, at: 0, length: 0).error == 0)

        // A guest that asks for what isn't there is told so, and the line stays open.
        #expect(try client.request(0, at: UInt64(fixture.expected.count), length: 4096).error == 22)
        #expect(try client.request(1, at: UInt64(fixture.expected.count - 512), length: 4096, data: fixture.noise(4096)).error == 22)
        #expect(try client.request(0, at: 0, length: fixture.expected.count).data == fixture.expected)

        try export.close()
        let disk = try fixture.open()
        #expect(disk.replayedChanges == 0)
        #expect(try fixture.contents(of: disk) == fixture.expected)
        try disk.close()
    }

    @Test func convertsARawImageAndBack() throws {
        let megabyte = 1 << 20
        let fixture = try Fixture(capacity: cluster)
        let raw = fixture.folder.appending(path: "disk.img")
        try DiskService.createBlankDisk(at: raw, capacity: UInt64(16 * megabyte), format: .raw)
        let handle = try FileHandle(forWritingTo: raw)
        try handle.seek(toOffset: UInt64(megabyte))
        try handle.write(contentsOf: Data(fixture.text(300_000, tag: 1)))
        try handle.seek(toOffset: UInt64(9 * megabyte + 123 * 512))
        try handle.write(contentsOf: Data(fixture.noise(70_000)))
        try handle.close()

        let compressed = fixture.folder.appending(path: "converted.\(CompressedDisk.fileExtension)")
        try DiskService.convertDisk(at: raw, format: .raw, to: compressed, format: .compressed)
        #expect(try DiskService.capacity(of: compressed, format: .compressed) == UInt64(16 * megabyte))

        let back = fixture.folder.appending(path: "back.img")
        try DiskService.convertDisk(at: compressed, format: .compressed, to: back, format: .raw)
        #expect(try Data(contentsOf: back) == Data(contentsOf: raw))
        // What was empty is empty again, not written out.
        var info = stat()
        #expect(stat(back.path, &info) == 0)
        #expect(Int(info.st_blocks) * 512 < 2 * megabyte)
    }
}
