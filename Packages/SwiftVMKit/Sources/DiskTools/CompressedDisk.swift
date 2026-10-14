import Compression
import Foundation
import os
import zlib

/// A virtual disk that keeps its contents compressed, in one file.
///
/// The disk is cut into clusters of 64 KiB. Each is stored compressed, as it is when compressing doesn't
/// help, or not at all when it holds nothing but zeros. A map says where each cluster is in the file.
///
/// Nothing in the file is ever overwritten: a cluster that changes is written to free space, and the map
/// follows. The map is committed once a second, by writing its changed pages to free space as well and
/// then one block that points to them. So the file holds a complete disk at every moment, as it was at
/// the last commit, whatever happens to the Mac.
///
/// A guest is told that what it has written is safe, and it can't say when it means it: the
/// Virtualization framework passes no flushes on. So every change to the map is also noted in a journal
/// before the guest hears that its write is done. The journal isn't synchronized, which would cost a
/// write its speed. When the app goes down, the system still has all of it and nothing is lost. When the
/// Mac goes down, the journal is followed for as far as the data it speaks of proves to be there, and the
/// disk comes back as it was at one moment in its last second.
public final class CompressedDisk: @unchecked Sendable {
    public enum DiskError: Error, LocalizedError, Equatable {
        case notACompressedDisk
        case unsupportedVersion(UInt32)
        case corrupted(String)
        case outOfRange
        case readOnly
        case closed
        case cannotShrink
        case io(Int32)

        public var errorDescription: String? {
            switch self {
            case .notACompressedDisk: "The file isn't a compressed disk."
            case .unsupportedVersion(let version): "The compressed disk was made by a newer SwiftVM (format \(version))."
            case .corrupted(let what): "The compressed disk is damaged: \(what)."
            case .outOfRange: "A request went past the end of the disk."
            case .readOnly: "The compressed disk is open for reading only."
            case .closed: "The compressed disk is closed."
            case .cannotShrink: "A disk can't be made smaller."
            case .io(let code): String(cString: strerror(code))
            }
        }
    }

    public static let fileExtension = "swiftvmdisk"

    static let blockSize = 4096
    static let clusterSize = 65536
    static let entriesPerPage = blockSize / MemoryLayout<Entry>.size
    /// Blocks in each of the two halves of the journal.
    static let journalBlocks = 4096
    static let recordSize = 32
    /// A block behind the journal that is written once and never let go of. APFS fills a hole that
    /// reaches the end of a file as soon as something is written into it, so the journal's empty space
    /// needs a block that is in use behind it, also in a disk that holds nothing yet.
    static let guardBlock = 2 + 2 * journalBlocks
    /// Two blocks that point to the map, the journal and its guard. Everything after is handed out as
    /// needed.
    static let firstFreeBlock = guardBlock + 1
    static let version: UInt32 = 1
    private static let magic = Array("SVMCDISK".utf8)

    enum Kind {
        static let hole: UInt8 = 0
        static let raw: UInt8 = 1
        static let lz4: UInt8 = 2
        /// Not written yet, but read: what an idle pass will store cold clusters as.
        static let lzbitmap: UInt8 = 3
        /// In the journal: the map was frozen for a commit here, and the journal goes on in its other half.
        static let endOfEpoch: UInt8 = 255
    }

    /// Where a cluster is in the file. Eight bytes, stored as they are.
    struct Entry: Equatable {
        var block: UInt32 = 0
        /// The stored length in bytes, and the kind in the top byte.
        var info: UInt32 = 0

        init() {}

        init(block: Int, length: Int, kind: UInt8) {
            self.block = UInt32(block)
            info = UInt32(length) | UInt32(kind) << 24
        }

        var kind: UInt8 { UInt8(info >> 24) }
        var length: Int { Int(info & 0xFF_FFFF) }
        var blockCount: Int { (length + CompressedDisk.blockSize - 1) / CompressedDisk.blockSize }
        var isHole: Bool { kind == Kind.hole }
        var offset: Int64 { Int64(block) * Int64(CompressedDisk.blockSize) }
    }

    private struct TableEntry {
        var block: UInt32 = 0
        var checksum: UInt32 = 0
    }

    private struct Superblock {
        var capacity: UInt64
        var generation: UInt64
        var tableBlock: UInt32
        var tableBlockCount: UInt32
        var tableChecksum: UInt32
        var pageCount: UInt32
    }

    /// A commit between freezing the map and having it safely in the file. Kept until it gets there: the
    /// journal has moved on, so the same commit is tried again rather than a new one begun.
    private struct PendingCommit {
        var generation: UInt64
        var pages: [(index: Int, bytes: [UInt8])]
        var frees: [BlockAllocator.Run]
    }

    /// Where a commit can be made to fail, to see that the disk survives it.
    enum CommitStep {
        case mapWritten
        case mapSynchronized
        case superblockWritten
    }

    /// The journal as it is being written, and what a commit takes along when it freezes the map.
    private struct Journal {
        /// The commit that the lines of this half come after.
        var base: UInt64
        /// Bytes of this half that are spoken for, in the file or not yet.
        var tail = 0
        /// Lines that wait to be written, and where in the half they go.
        var waiting: [UInt8] = []
        var waitingStart = 0
        /// Bytes of this half that are in the file.
        var written = 0
        var isBeingWritten = false
        /// Where this half has a gap, after lines that couldn't be written. What lies behind a gap
        /// is never followed, so no write is called done from there on until a commit has started
        /// the journal anew.
        var brokenAt: Int?
        var dirtyPages: Set<Int> = []
        /// What a change to the map let go of. Kept in the file until the commit that no longer needs it.
        var pendingFree: [BlockAllocator.Run] = []
    }

    private final class Scratch {
        let plain = UnsafeMutableRawPointer.allocate(byteCount: CompressedDisk.clusterSize, alignment: 16384)
        let packed = UnsafeMutableRawPointer.allocate(byteCount: CompressedDisk.clusterSize, alignment: 16384)
        let codec: UnsafeMutableRawPointer

        init() {
            let size = [
                compression_encode_scratch_buffer_size(COMPRESSION_LZ4_RAW),
                compression_decode_scratch_buffer_size(COMPRESSION_LZ4_RAW),
                compression_decode_scratch_buffer_size(COMPRESSION_LZBITMAP),
            ].max() ?? 0
            codec = .allocate(byteCount: max(size, 16), alignment: 16)
        }

        deinit {
            plain.deallocate()
            packed.deallocate()
            codec.deallocate()
        }
    }

    public let url: URL
    /// The size of the disk as the guest sees it.
    public private(set) var capacity: UInt64
    public let isReadOnly: Bool
    /// How many changes to the map were taken from the journal when the disk was opened.
    public private(set) var replayedChanges = 0

    private let descriptor: Int32
    private var isClosed = false
    private var entries: UnsafeMutablePointer<Entry>
    private var pageCount: Int
    private var clusterCount: Int
    private let stripes: [OSAllocatedUnfairLock<Void>]
    /// Changes to the map hold this shared. A commit takes it alone for the moment it freezes the map.
    private let commitLock: UnsafeMutablePointer<pthread_rwlock_t>
    private let allocator = OSAllocatedUnfairLock(uncheckedState: BlockAllocator(start: CompressedDisk.firstFreeBlock))
    /// Guards the journal and every change to the map that it notes.
    private let journalLock = NSCondition()
    private var journal: Journal
    private let scratchPool = OSAllocatedUnfairLock<[Scratch]>(uncheckedState: [])

    // Only touched on the commit queue.
    private let commitQueue = DispatchQueue(label: "app.swiftvm.compressed-disk.commit")
    private var timer: (any DispatchSourceTimer)?
    private var generation: UInt64
    private var table: [TableEntry]
    private var tableExtent: BlockAllocator.Run
    private var pending: PendingCommit?
    var commitFault: CommitStep?
    /// Makes writing to the journal fail, to see that no write is called done without its line.
    var journalFault = false

    private static let journalBytes = journalBlocks * blockSize
    /// Past this a commit is asked for early.
    private static let journalSoftLimit = journalBytes / 2
    /// Past this writes wait for one. The rest is room for the writes that are already on their way.
    private static let journalHardLimit = journalBytes * 3 / 4

    // MARK: Creating and opening

    /// Creates an empty disk of `capacity` bytes. It takes up next to nothing until it is written to.
    public static func create(at url: URL, capacity: UInt64) throws {
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_EXCL, 0o644)
        guard descriptor >= 0 else { throw DiskError.io(errno) }
        defer { Darwin.close(descriptor) }
        let superblock = Superblock(
            capacity: capacity, generation: 0, tableBlock: 0, tableBlockCount: 0, tableChecksum: 0,
            pageCount: UInt32(pageCount(forCapacity: capacity))
        )
        do {
            // Made longer rather than written to at its end: only that is sure to leave the space
            // between empty.
            guard ftruncate(descriptor, off_t(firstFreeBlock) * off_t(blockSize)) == 0 else { throw DiskError.io(errno) }
            try write(encode(superblock), to: descriptor, at: 0)
            try write([UInt8](repeating: 0, count: blockSize), to: descriptor, at: Int64(guardBlock) * Int64(blockSize))
            try synchronize(descriptor)
        } catch {
            unlink(url.path)
            throw error
        }
    }

    /// The size in bytes of the disk at `url`, as a guest sees it.
    public static func capacity(of url: URL) throws -> UInt64 {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw DiskError.io(errno) }
        defer { Darwin.close(descriptor) }
        return try newestSuperblock(in: descriptor).capacity
    }

    /// Opens the disk at `url`, bringing back what its journal holds if it wasn't closed.
    ///
    /// - Parameter commitInterval: How often the map is committed. `nil` leaves that to ``flush()``.
    public convenience init(url: URL, readOnly: Bool = false, commitInterval: TimeInterval? = 1) throws {
        try self.init(url: url, readOnly: readOnly, commitInterval: commitInterval, failingAt: nil)
    }

    /// - Parameter failingAt: Where the commit that begins a time of writing is made to fail.
    init(url: URL, readOnly: Bool, commitInterval: TimeInterval?, failingAt commitFault: CommitStep?) throws {
        self.url = url
        self.commitFault = commitFault
        isReadOnly = readOnly
        descriptor = open(url.path, readOnly ? O_RDONLY : O_RDWR)
        guard descriptor >= 0 else { throw DiskError.io(errno) }
        var entries: UnsafeMutablePointer<Entry>?
        do {
            let superblock = try Self.newestSuperblock(in: descriptor)
            capacity = superblock.capacity
            generation = superblock.generation
            pageCount = Int(superblock.pageCount)
            clusterCount = Self.clusterCount(forCapacity: superblock.capacity)
            guard pageCount == Self.pageCount(forCapacity: superblock.capacity) else {
                throw DiskError.corrupted("its map doesn't fit its size")
            }
            tableExtent = BlockAllocator.Run(block: Int(superblock.tableBlock), count: Int(superblock.tableBlockCount))
            table = try Self.readTable(superblock, from: descriptor)
            let map = UnsafeMutablePointer<Entry>.allocate(capacity: max(pageCount, 1) * Self.entriesPerPage)
            map.initialize(repeating: Entry(), count: max(pageCount, 1) * Self.entriesPerPage)
            entries = map
            for (index, page) in table.enumerated() where page.block != 0 {
                let target = UnsafeMutableRawPointer(map + index * Self.entriesPerPage)
                try Self.read(target, Self.blockSize, from: descriptor, at: Int64(page.block) * Int64(Self.blockSize))
                guard Self.checksum(target, Self.blockSize) == page.checksum else {
                    throw DiskError.corrupted("a page of its map doesn't match its checksum")
                }
            }
            self.entries = map
        } catch {
            entries?.deallocate()
            Darwin.close(descriptor)
            throw error
        }
        stripes = (0..<1024).map { _ in OSAllocatedUnfairLock() }
        commitLock = .allocate(capacity: 1)
        pthread_rwlock_init(commitLock, nil)
        journal = Journal(base: generation)

        // From here on a failure is cleaned up by deinit, which runs once every property is set.
        // The header block that was just read may have been written by a commit that never got to
        // wait for it. It is the one everything goes by from here on, so it has to be on the disk
        // before a block that an older one still needs is used for something else.
        if !readOnly { try Self.synchronize(descriptor) }
        let replay = replayJournal()
        replayedChanges = replay.changes
        // Nothing remembers across a close which free blocks still hold storage, so all of them are
        // looked at again when the disk is quiet.
        try buildAllocator(keeping: replay.superseded, markingFreeStale: !readOnly)
        if !readOnly {
            journal.dirtyPages = replay.pages
            try foldJournal(freeing: replay.superseded)
        }
        self.commitFault = nil

        if !readOnly, let commitInterval {
            let timer = DispatchSource.makeTimerSource(queue: commitQueue)
            timer.schedule(deadline: .now() + commitInterval, repeating: commitInterval)
            timer.setEventHandler { [weak self] in
                // A commit that fails stays pending and is tried again at the next tick. A tick with
                // nothing to commit is a quiet moment, which is when small leftovers are given back.
                if let self, (try? self.commit(force: false)) == false { self.reclaim(limit: 4096, smallest: 1) }
            }
            timer.resume()
            self.timer = timer
        }
    }

    deinit {
        timer?.cancel()
        // Left open, the disk is as it would be after a crash of the app: the journal has the rest.
        if !isClosed { Darwin.close(descriptor) }
        entries.deallocate()
        pthread_rwlock_destroy(commitLock)
        commitLock.deallocate()
    }

    /// Commits what is outstanding, gives freed space back to the Mac and closes the file.
    public func close() throws {
        guard !isClosed else { return }
        timer?.cancel()
        timer = nil
        defer {
            isClosed = true
            Darwin.close(descriptor)
        }
        guard !isReadOnly else { return }
        try commitQueue.sync {
            try commit(force: false)
            // Not everything at any price: the app waits for this. What is left is looked at again
            // the next time the disk is open and quiet.
            reclaim(limit: 1 << 15, smallest: 1, within: .milliseconds(50))
        }
    }

    /// Lets go of the file as a crash of the app would: nothing is committed.
    func abandon() {
        guard !isClosed else { return }
        timer?.cancel()
        timer = nil
        commitQueue.sync {}
        isClosed = true
        Darwin.close(descriptor)
    }

    // MARK: Reading and writing

    public func read(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws {
        guard let base = buffer.baseAddress, buffer.count > 0 else { return }
        try check(offset, UInt64(buffer.count))
        let scratch = takeScratch()
        defer { giveBack(scratch) }
        try forEachPiece(of: offset, buffer.count) { cluster, within, count, done in
            let target = base + done
            let stripe = stripes[cluster % stripes.count]
            stripe.lock()
            defer { stripe.unlock() }
            let entry = entries[cluster]
            switch entry.kind {
            case Kind.hole:
                memset(target, 0, count)
            case Kind.raw:
                try read(target, count, at: entry.offset + Int64(within))
            default:
                try read(scratch.packed, entry.length, at: entry.offset)
                if count == Self.clusterSize {
                    try expand(entry, from: scratch.packed, into: target, scratch)
                } else {
                    try expand(entry, from: scratch.packed, into: scratch.plain, scratch)
                    memcpy(target, scratch.plain + within, count)
                }
            }
        }
    }

    public func write(at offset: UInt64, from buffer: UnsafeRawBufferPointer) throws {
        guard let base = buffer.baseAddress, buffer.count > 0 else { return }
        try change(offset, UInt64(buffer.count)) { within, count, done, plain in
            memcpy(plain + within, base + done, count)
        } whole: { done in
            base + done
        }
    }

    /// Fills a part of the disk with zeros. Whole clusters stop taking up space.
    public func zero(at offset: UInt64, length: UInt64) throws {
        try change(offset, length) { within, count, _, plain in
            memset(plain + within, 0, count)
        } whole: { _ in
            nil
        }
    }

    /// Lets go of a part of the disk that the guest no longer needs. Only whole clusters are let go:
    /// a guest is promised nothing about what it reads from a part it has discarded.
    public func discard(at offset: UInt64, length: UInt64) throws {
        try check(offset, length)
        let size = UInt64(Self.clusterSize)
        let first = (offset + size - 1) / size
        let end = (offset + length) / size
        guard end > first else { return }
        try zero(at: first * size, length: (end - first) * size)
    }

    /// Commits now, and returns once the commit is safely in the file.
    public func flush() throws {
        try checkWritable()
        try commitQueue.sync { _ = try commit(force: false) }
    }

    /// Makes the disk larger. Nothing may be reading or writing it meanwhile.
    public func grow(to newCapacity: UInt64) throws {
        try checkWritable()
        guard newCapacity >= capacity else { throw DiskError.cannotShrink }
        try commitQueue.sync {
            let newPageCount = Self.pageCount(forCapacity: newCapacity)
            if newPageCount > pageCount {
                let grown = UnsafeMutablePointer<Entry>.allocate(capacity: newPageCount * Self.entriesPerPage)
                grown.initialize(repeating: Entry(), count: newPageCount * Self.entriesPerPage)
                grown.update(from: entries, count: pageCount * Self.entriesPerPage)
                entries.deallocate()
                entries = grown
                table.append(contentsOf: repeatElement(TableEntry(), count: newPageCount - pageCount))
                pageCount = newPageCount
            }
            capacity = newCapacity
            clusterCount = Self.clusterCount(forCapacity: newCapacity)
            try commit(force: true)
        }
    }

    /// The parts of the disk that hold something, in order, as offsets and lengths in bytes.
    public func storedRanges() -> [Range<UInt64>] {
        var ranges: [Range<UInt64>] = []
        var start: Int?
        for cluster in 0...clusterCount {
            let stored = cluster < clusterCount && !entries[cluster].isHole
            if stored, start == nil { start = cluster }
            if !stored, let first = start {
                ranges.append(UInt64(first) * UInt64(Self.clusterSize)..<min(UInt64(cluster) * UInt64(Self.clusterSize), capacity))
                start = nil
            }
        }
        return ranges
    }

    /// Where in the file a cluster's data is, for tests that damage it.
    func placement(ofCluster cluster: Int) -> (offset: Int64, length: Int)? {
        entries[cluster].isHole ? nil : (entries[cluster].offset, entries[cluster].length)
    }

    // MARK: Changing clusters

    private func check(_ offset: UInt64, _ length: UInt64) throws {
        guard !isClosed else { throw DiskError.closed }
        guard offset <= capacity, length <= capacity - offset else { throw DiskError.outOfRange }
    }

    private func checkWritable() throws {
        guard !isClosed else { throw DiskError.closed }
        guard !isReadOnly else { throw DiskError.readOnly }
    }

    /// Calls `body` for each cluster that `offset` and `length` reach into: the cluster, where the
    /// piece starts in it, how long the piece is, and how far into the whole it begins.
    private func forEachPiece(of offset: UInt64, _ length: Int, _ body: (Int, Int, Int, Int) throws -> Void) rethrows {
        var done = 0
        while done < length {
            let position = offset + UInt64(done)
            let cluster = Int(position / UInt64(Self.clusterSize))
            let within = Int(position % UInt64(Self.clusterSize))
            let count = min(Self.clusterSize - within, length - done)
            try body(cluster, within, count, done)
            done += count
        }
    }

    /// Changes a part of the disk, cluster by cluster.
    ///
    /// - Parameters:
    ///   - patch: Changes a piece of a cluster in a copy of it: where the piece starts, how long it is,
    ///     how far into the whole it begins, and the copy.
    ///   - whole: The new contents of a cluster that is replaced as a whole, or `nil` for zeros.
    private func change(
        _ offset: UInt64, _ length: UInt64, patch: (Int, Int, Int, UnsafeMutableRawPointer) -> Void,
        whole: (Int) -> UnsafeRawPointer?
    ) throws {
        try checkWritable()
        try check(offset, length)
        guard length > 0 else { return }
        let scratch = takeScratch()
        defer { giveBack(scratch) }
        try forEachPiece(of: offset, Int(length)) { cluster, within, count, done in
            // A trim can reach over more clusters than the journal has room for past its limit.
            if done % (1024 * Self.clusterSize) < Self.clusterSize { waitForJournal() }
            let stripe = stripes[cluster % stripes.count]
            if within == 0, count == Self.clusterSize {
                let stored = try whole(done).map { try store($0, scratch) } ?? (Entry(), 0)
                stripe.lock()
                defer { stripe.unlock() }
                try publish(cluster, stored.0, checksum: stored.1)
                return
            }
            // Read, change and write as one: another write to this cluster must see this one's result.
            stripe.lock()
            defer { stripe.unlock() }
            try load(entries[cluster], into: scratch.plain, scratch)
            patch(within, count, done, scratch.plain)
            let stored = try store(scratch.plain, scratch)
            try publish(cluster, stored.0, checksum: stored.1)
        }
    }

    private func load(_ entry: Entry, into plain: UnsafeMutableRawPointer, _ scratch: Scratch) throws {
        switch entry.kind {
        case Kind.hole:
            memset(plain, 0, Self.clusterSize)
        case Kind.raw:
            try read(plain, Self.clusterSize, at: entry.offset)
        default:
            try read(scratch.packed, entry.length, at: entry.offset)
            try expand(entry, from: scratch.packed, into: plain, scratch)
        }
    }

    /// Writes a cluster's contents to free space and says where they went. Nothing points there yet.
    private func store(_ plain: UnsafeRawPointer, _ scratch: Scratch) throws -> (Entry, UInt32) {
        if Self.isZero(plain, Self.clusterSize) { return (Entry(), 0) }
        // Compressed, a cluster has to save at least a block, or reading it back costs time for nothing.
        let packed = compression_encode_buffer(
            scratch.packed.assumingMemoryBound(to: UInt8.self), Self.clusterSize - Self.blockSize,
            plain.assumingMemoryBound(to: UInt8.self), Self.clusterSize, scratch.codec, COMPRESSION_LZ4_RAW
        )
        let bytes = packed > 0 ? UnsafeRawPointer(scratch.packed) : plain
        let length = packed > 0 ? packed : Self.clusterSize
        let blocks = (length + Self.blockSize - 1) / Self.blockSize
        let block = allocator.withLockUnchecked { $0.allocate(blocks) }
        let entry = Entry(block: block, length: length, kind: packed > 0 ? Kind.lz4 : Kind.raw)
        do {
            // Whole blocks, so that the file never ends inside one: such a block can't be given back.
            if packed > 0 { memset(scratch.packed + length, 0, blocks * Self.blockSize - length) }
            try write(bytes, blocks * Self.blockSize, at: entry.offset)
        } catch {
            allocator.withLockUnchecked { $0.release(block, blocks) }
            throw error
        }
        return (entry, Self.checksum(bytes, length))
    }

    private func expand(_ entry: Entry, from packed: UnsafeRawPointer, into plain: UnsafeMutableRawPointer, _ scratch: Scratch) throws {
        let algorithm: compression_algorithm
        switch entry.kind {
        case Kind.lz4: algorithm = COMPRESSION_LZ4_RAW
        case Kind.lzbitmap: algorithm = COMPRESSION_LZBITMAP
        default: throw DiskError.corrupted("a cluster is stored in a way this version doesn't know")
        }
        let size = compression_decode_buffer(
            plain.assumingMemoryBound(to: UInt8.self), Self.clusterSize,
            packed.assumingMemoryBound(to: UInt8.self), entry.length, scratch.codec, algorithm
        )
        guard size == Self.clusterSize else { throw DiskError.corrupted("a cluster doesn't unpack to its size") }
    }

    /// Makes the map point to a cluster's new place, and returns once the journal's line about it is in
    /// the file. The caller holds the cluster's lock.
    private func publish(_ cluster: Int, _ entry: Entry, checksum: UInt32) throws {
        pthread_rwlock_rdlock(commitLock)
        defer { pthread_rwlock_unlock(commitLock) }
        journalLock.lock()
        defer { journalLock.unlock() }
        let old = entries[cluster]
        // Nothing where nothing was: not worth a line in the journal.
        if old.isHole, entry.isHole { return }
        // Writes wait at the hard limit, and what is left past it holds more lines than are on their
        // way at once. A journal with a gap takes no more lines at all.
        guard journal.brokenAt == nil, journal.tail + 2 * Self.recordSize <= Self.journalBytes else {
            if !entry.isHole { allocator.withLockUnchecked { $0.release(Int(entry.block), entry.blockCount) } }
            throw DiskError.io(journal.brokenAt == nil ? ENOSPC : EIO)
        }
        let record = Record(base: journal.base, cluster: cluster, entry: entry, checksum: checksum, sequence: journal.tail / Self.recordSize)
        journal.waiting.append(contentsOf: record.encoded())
        journal.tail += Self.recordSize
        let mine = journal.tail
        entries[cluster] = entry
        journal.dirtyPages.insert(cluster / Self.entriesPerPage)
        if !old.isHole {
            journal.pendingFree.append(BlockAllocator.Run(block: Int(old.block), count: old.blockCount))
        }

        // Whoever comes first writes every line that waits, in one go, and the others wait for theirs
        // to be in the file. With many writers at once that is one trip to the file for all of them.
        while journal.written < mine {
            if journal.isBeingWritten {
                journalLock.wait()
                continue
            }
            let lines = journal.waiting
            let start = journal.waitingStart
            let offset = Self.journalOffset(base: journal.base) + Int64(start)
            journal.waiting.removeAll(keepingCapacity: true)
            journal.waitingStart += lines.count
            journal.isBeingWritten = true
            journalLock.unlock()
            let fails = journalFault
            let outcome = Result {
                if fails { throw DiskError.io(EIO) }
                try Self.write(lines, to: descriptor, at: offset)
            }
            journalLock.lock()
            journal.isBeingWritten = false
            journal.written = start + lines.count
            journalLock.broadcast()
            if case .failure = outcome {
                // A commit needs no journal, and starts it anew.
                journal.brokenAt = min(journal.brokenAt ?? start, start)
                commitQueue.async { _ = try? self.commit(force: false) }
            }
        }
        // The map has changed and the data is in the file, but the guest is told that the write
        // failed: an app that went down now would bring the disk back without it.
        if let gap = journal.brokenAt, mine > gap { throw DiskError.io(EIO) }
    }

    // MARK: Journal

    private static func journalOffset(base: UInt64) -> Int64 {
        Int64(2 + Int(base % 2) * journalBlocks) * Int64(blockSize)
    }

    /// A line of the journal: a cluster's new place, and what its data adds up to.
    private struct Record {
        /// The commit this change comes after.
        var base: UInt64
        var cluster: Int
        var entry: Entry
        var checksum: UInt32
        /// Which line of its half of the journal this is.
        var sequence: Int

        func encoded() -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: CompressedDisk.recordSize)
            bytes.withUnsafeMutableBytes { raw in
                raw.storeBytes(of: base.littleEndian, toByteOffset: 0, as: UInt64.self)
                raw.storeBytes(of: UInt32(cluster).littleEndian, toByteOffset: 8, as: UInt32.self)
                raw.storeBytes(of: entry.block.littleEndian, toByteOffset: 12, as: UInt32.self)
                raw.storeBytes(of: entry.info.littleEndian, toByteOffset: 16, as: UInt32.self)
                raw.storeBytes(of: checksum.littleEndian, toByteOffset: 20, as: UInt32.self)
                raw.storeBytes(of: UInt32(sequence).littleEndian, toByteOffset: 24, as: UInt32.self)
                raw.storeBytes(of: CompressedDisk.checksum(raw.baseAddress!, 28).littleEndian, toByteOffset: 28, as: UInt32.self)
            }
            return bytes
        }

        /// The line in `bytes`, or `nil` when it isn't whole.
        init?(_ bytes: [UInt8]) {
            let whole = bytes.withUnsafeBytes { raw in
                UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 28, as: UInt32.self)) == CompressedDisk.checksum(raw.baseAddress!, 28)
            }
            guard whole else { return nil }
            (base, cluster, entry, checksum, sequence) = bytes.withUnsafeBytes { raw in
                var entry = Entry()
                entry.block = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
                entry.info = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 16, as: UInt32.self))
                return (
                    UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: 0, as: UInt64.self)),
                    Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self))),
                    entry,
                    UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 20, as: UInt32.self)),
                    Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 24, as: UInt32.self)))
                )
            }
        }

        init(base: UInt64, cluster: Int, entry: Entry, checksum: UInt32, sequence: Int) {
            self.base = base
            self.cluster = cluster
            self.entry = entry
            self.checksum = checksum
            self.sequence = sequence
        }
    }

    /// Holds a write back while the journal is nearly full, until a commit has started it anew.
    private func waitForJournal() {
        let tail = journalLock.withLock { journal.tail }
        if tail > Self.journalHardLimit {
            commitQueue.sync { _ = try? commit(force: false) }
        } else if tail > Self.journalSoftLimit {
            commitQueue.async { _ = try? self.commit(force: false) }
        }
    }

    private struct Replay {
        /// Whether the journal held anything at all: then the disk wasn't closed.
        var found = false
        var changes = 0
        var pages: Set<Int> = []
        /// What the lines that were followed replaced: of the last commit, or of a line before them.
        /// The file falls back on all of it if this open doesn't get as far as its own commit.
        var superseded: [BlockAllocator.Run] = []
    }

    /// Follows the journal from the last commit, and stops at the first line that isn't whole or whose
    /// data isn't in the file: what was written before that line is all there, so the disk is as it was
    /// at one moment.
    private func replayJournal() -> Replay {
        var replay = Replay()
        var base = generation
        var position = 0
        var bytes = [UInt8](repeating: 0, count: Self.recordSize)
        let data = UnsafeMutableRawPointer.allocate(byteCount: Self.clusterSize, alignment: 16384)
        defer { data.deallocate() }

        while position + Self.recordSize <= Self.journalBytes {
            let got = bytes.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, Self.recordSize, Self.journalOffset(base: base) + Int64(position)) }
            guard got == Self.recordSize, let record = Record(bytes), record.base == base, record.sequence == position / Self.recordSize else { break }
            replay.found = true
            let entry = record.entry
            if entry.kind == Kind.endOfEpoch {
                // Only one commit can have been under way.
                guard base == generation else { break }
                base += 1
                position = 0
                continue
            }
            guard record.cluster < clusterCount else { break }
            switch entry.kind {
            case Kind.hole:
                break
            case Kind.raw, Kind.lz4, Kind.lzbitmap:
                guard Int(entry.block) >= Self.firstFreeBlock, entry.length > 0, entry.length <= Self.clusterSize,
                      entry.kind != Kind.raw || entry.length == Self.clusterSize,
                      pread(descriptor, data, entry.length, entry.offset) == entry.length,
                      Self.checksum(data, entry.length) == record.checksum
                else { return replay }
            default:
                return replay
            }
            let old = entries[record.cluster]
            if !old.isHole, Int(old.block) >= Self.firstFreeBlock, old.length <= Self.clusterSize {
                replay.superseded.append(BlockAllocator.Run(block: Int(old.block), count: old.blockCount))
            }
            entries[record.cluster] = entry
            replay.changes += 1
            replay.pages.insert(record.cluster / Self.entriesPerPage)
            position += Self.recordSize
        }
        return replay
    }

    /// Begins a time of writing with a commit of the disk as it was opened, with what the journal
    /// brought back.
    ///
    /// The commit skips two numbers. A line of the journal is told from an older one by the number of
    /// the commit it comes after, and lines of the last commit and of one that never finished can be
    /// in the journal still: after a crash of the Mac also behind lines that are missing, where nothing
    /// finds them now. Under a number none of them carries, no line written from here on can be taken
    /// to go on into them. Three ahead rather than two, so that the two blocks that point to the map
    /// still take turns.
    private func foldJournal(freeing superseded: [BlockAllocator.Run]) throws {
        let next = generation + 3
        let pages = journal.dirtyPages
        journal.dirtyPages = []
        pending = PendingCommit(generation: next, pages: pages.sorted().map { ($0, pageBytes($0)) }, frees: superseded)
        let frees = try finishPendingCommit()
        journal = Journal(base: next)
        // Tidying only, and not everywhere possible: nothing in the journal is needed any more.
        var hole = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: Self.journalOffset(base: 0), fp_length: off_t(2 * Self.journalBytes))
        _ = fcntl(descriptor, F_PUNCHHOLE, &hole)
        release(frees)
    }

    // MARK: Committing

    private func pageBytes(_ index: Int) -> [UInt8] {
        Array(UnsafeRawBufferPointer(start: entries + index * Self.entriesPerPage, count: Self.blockSize))
    }

    /// Makes the file hold the disk as it is now, and says whether there was anything to do. On the
    /// commit queue.
    @discardableResult
    private func commit(force: Bool) throws -> Bool {
        guard !isClosed, !isReadOnly else { return false }
        // A commit that failed earlier is owed first: what was written since comes after it.
        if pending != nil { release(try finishPendingCommit()) }
        do {
            let next = generation + 1
            pthread_rwlock_wrlock(commitLock)
            defer { pthread_rwlock_unlock(commitLock) }
            // Nobody is changing the map now, so every line of this half is in the file.
            pending = try journalLock.withLock { () -> PendingCommit? in
                guard force || journal.tail > 0 || !journal.dirtyPages.isEmpty else { return nil }
                // A half with a gap is never followed to its end, and may not take another line.
                if journal.brokenAt == nil {
                    let end = Record(
                        base: journal.base, cluster: 0, entry: Entry(block: 0, length: 0, kind: Kind.endOfEpoch), checksum: 0,
                        sequence: journal.tail / Self.recordSize
                    )
                    try Self.write(end.encoded(), to: descriptor, at: Self.journalOffset(base: journal.base) + Int64(journal.tail))
                }
                let commit = PendingCommit(
                    generation: next, pages: journal.dirtyPages.sorted().map { ($0, pageBytes($0)) }, frees: journal.pendingFree
                )
                let hadGap = journal.brokenAt != nil
                journal = Journal(base: next)
                // Following the journal from the last commit ends at the gap, and never gets to the
                // lines of this half. It takes none until this commit is in the file.
                if hadGap { journal.brokenAt = 0 }
                return commit
            }
        }
        guard pending != nil else { return false }
        release(try finishPendingCommit())
        // The half of the journal that the next commit moves to holds nothing that is still needed.
        var hole = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: Self.journalOffset(base: generation + 1), fp_length: off_t(Self.journalBytes))
        _ = fcntl(descriptor, F_PUNCHHOLE, &hole)
        // Only what a discard or a large rewrite has freed. A block that a small write let go of is
        // likely to be written again in a moment, and writing into a hole costs a multiple of
        // writing over what is there.
        reclaim(limit: 4096, smallest: Self.largeRun)
        return true
    }

    /// Writes the frozen map and the block that points to it, and returns what is free from then on.
    private func finishPendingCommit() throws -> [BlockAllocator.Run] {
        guard var commit = pending else { return [] }
        // What a try that failed left behind is let go of with the rest, so `pending` keeps up.
        defer { if pending != nil { pending = commit } }

        for page in commit.pages {
            let old = table[page.index]
            // Noted before the page is written: a try that fails here leaves the next one to free it.
            if old.block != 0 { commit.frees.append(BlockAllocator.Run(block: Int(old.block), count: 1)) }
            if page.bytes.allSatisfy({ $0 == 0 }) {
                table[page.index] = TableEntry()
            } else {
                let block = allocator.withLockUnchecked { $0.allocate(1) }
                table[page.index] = TableEntry(block: UInt32(block), checksum: page.bytes.withUnsafeBytes { Self.checksum($0.baseAddress!, $0.count) })
                try Self.write(page.bytes, to: descriptor, at: Int64(block) * Int64(Self.blockSize))
            }
        }
        commit.pages = []

        var encoded = [UInt8](repeating: 0, count: (table.count * 8 + Self.blockSize - 1) / Self.blockSize * Self.blockSize)
        encoded.withUnsafeMutableBytes { raw in
            for (index, entry) in table.enumerated() {
                raw.storeBytes(of: entry.block.littleEndian, toByteOffset: index * 8, as: UInt32.self)
                raw.storeBytes(of: entry.checksum.littleEndian, toByteOffset: index * 8 + 4, as: UInt32.self)
            }
        }
        let oldTable = tableExtent
        var newTable = BlockAllocator.Run(block: 0, count: encoded.count / Self.blockSize)
        if newTable.count > 0 {
            newTable.block = allocator.withLockUnchecked { $0.allocate(newTable.count) }
        }
        // Noted before it is written: a try that fails here leaves blocks behind that the next try frees.
        tableExtent = newTable
        if oldTable.count > 0 { commit.frees.append(oldTable) }
        if newTable.count > 0 {
            try Self.write(encoded, to: descriptor, at: Int64(newTable.block) * Int64(Self.blockSize))
        }
        if commitFault == .mapWritten { throw DiskError.io(EIO) }

        // Everything the new block will point to has to reach the disk before the block does. That
        // takes a barrier, not the wait for all of it to be there: the wait comes once, at the end.
        if fcntl(descriptor, F_BARRIERFSYNC) != 0 { try Self.synchronize(descriptor) }
        if commitFault == .mapSynchronized { throw DiskError.io(EIO) }
        let superblock = Superblock(
            capacity: capacity, generation: commit.generation, tableBlock: UInt32(newTable.block), tableBlockCount: UInt32(newTable.count),
            tableChecksum: encoded.withUnsafeBytes { Self.checksum($0.baseAddress!, $0.count) }, pageCount: UInt32(pageCount)
        )
        // The two blocks take turns, so the one being written is never the one a crash falls back on.
        try Self.write(Self.encode(superblock), to: descriptor, at: Int64(commit.generation % 2) * Int64(Self.blockSize))
        if commitFault == .superblockWritten { throw DiskError.io(EIO) }
        try Self.synchronize(descriptor)

        generation = commit.generation
        pending = nil
        // The journal leads on from this commit now, whatever came before it.
        journalLock.withLock { if journal.brokenAt == 0, journal.tail == 0 { journal.brokenAt = nil } }
        return commit.frees
    }

    private func release(_ runs: [BlockAllocator.Run]) {
        guard !runs.isEmpty else { return }
        allocator.withLockUnchecked { allocator in
            for run in runs { allocator.release(run.block, run.count) }
        }
    }

    /// Free blocks in a row that are given back to the Mac at once: a megabyte.
    private static let largeRun = 256

    /// Gives the Mac back the storage of blocks that nothing uses any more: of at most `limit` runs of
    /// at least `smallest` blocks, for no longer than `duration`.
    private func reclaim(limit: Int, smallest: Int, within duration: Duration? = nil) {
        let deadline = duration.map { ContinuousClock.now + $0 }
        // Free blocks at the end are cut off, not punched: a hole there wouldn't last. With the lock
        // held, so that nobody is handed a block behind the new end before the file is that short.
        allocator.withLockUnchecked { allocator in
            if let end = allocator.trimEnd() {
                _ = ftruncate(descriptor, off_t(end) * off_t(Self.blockSize))
            }
        }
        var size = stat()
        guard fstat(descriptor, &size) == 0 else { return }
        // Blocks past the end of the file were handed out and never written. They hold no storage, and
        // a hole that reaches past the end is refused as a whole.
        let fileBlocks = Int(size.st_size) / Self.blockSize
        var position = Self.firstFreeBlock
        var done = 0
        while done < limit, deadline.map({ ContinuousClock.now < $0 }) ?? true,
              let run = allocator.withLockUnchecked({ $0.takeStaleRun(from: position, minimum: smallest) }) {
            let count = min(run.count, fileBlocks - run.block)
            if count > 0 {
                var hole = fpunchhole_t(
                    fp_flags: 0, reserved: 0, fp_offset: off_t(run.block) * off_t(Self.blockSize), fp_length: off_t(count) * off_t(Self.blockSize)
                )
                _ = fcntl(descriptor, F_PUNCHHOLE, &hole)
            }
            allocator.withLockUnchecked { $0.finishReclaiming(run) }
            position = run.block + run.count
            done += 1
        }
    }

    private func buildAllocator(keeping superseded: [BlockAllocator.Run], markingFreeStale: Bool) throws {
        var size = stat()
        guard fstat(descriptor, &size) == 0 else { throw DiskError.io(errno) }
        try allocator.withLockUnchecked { allocator in
            allocator.markUsed(tableExtent.block, tableExtent.count)
            for page in table where page.block != 0 { allocator.markUsed(Int(page.block), 1) }
            for cluster in 0..<clusterCount where !entries[cluster].isHole {
                let entry = entries[cluster]
                guard Int(entry.block) >= Self.firstFreeBlock, entry.length > 0, entry.length <= Self.clusterSize else {
                    throw DiskError.corrupted("its map points outside of it")
                }
                allocator.markUsed(Int(entry.block), entry.blockCount)
            }
            for run in superseded { allocator.markUsed(run.block, run.count) }
            // What lies past the last block in use is left from writes that never made it into the map.
            let fileBlocks = (Int(size.st_size) + Self.blockSize - 1) / Self.blockSize
            if !isReadOnly, fileBlocks > allocator.end {
                guard ftruncate(descriptor, off_t(allocator.end) * off_t(Self.blockSize)) == 0 else { throw DiskError.io(errno) }
            }
            if markingFreeStale { allocator.markAllFreeStale() }
        }
    }

    // MARK: Scratch space

    private func takeScratch() -> Scratch {
        scratchPool.withLockUnchecked { $0.popLast() } ?? Scratch()
    }

    private func giveBack(_ scratch: Scratch) {
        scratchPool.withLockUnchecked { $0.append(scratch) }
    }

    // MARK: The file

    private static func clusterCount(forCapacity capacity: UInt64) -> Int {
        Int((capacity + UInt64(clusterSize) - 1) / UInt64(clusterSize))
    }

    private static func pageCount(forCapacity capacity: UInt64) -> Int {
        (clusterCount(forCapacity: capacity) + entriesPerPage - 1) / entriesPerPage
    }

    /// Waits until everything written is on the disk. A file system that doesn't know how is asked
    /// the ordinary way.
    private static func synchronize(_ descriptor: Int32) throws {
        guard fcntl(descriptor, F_FULLFSYNC) == 0 || fsync(descriptor) == 0 else { throw DiskError.io(errno) }
    }

    static func checksum(_ bytes: UnsafeRawPointer, _ count: Int) -> UInt32 {
        UInt32(truncatingIfNeeded: crc32(0, bytes.assumingMemoryBound(to: UInt8.self), UInt32(count)))
    }

    private static func isZero(_ bytes: UnsafeRawPointer, _ count: Int) -> Bool {
        var any: UInt64 = 0
        for offset in stride(from: 0, to: count, by: 8) { any |= bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }
        return any == 0
    }

    private static func encode(_ superblock: Superblock) -> [UInt8] {
        var block = [UInt8](repeating: 0, count: blockSize)
        block.replaceSubrange(0..<magic.count, with: magic)
        block.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: version.littleEndian, toByteOffset: 8, as: UInt32.self)
            raw.storeBytes(of: UInt32(clusterSize).littleEndian, toByteOffset: 12, as: UInt32.self)
            raw.storeBytes(of: superblock.capacity.littleEndian, toByteOffset: 16, as: UInt64.self)
            raw.storeBytes(of: superblock.generation.littleEndian, toByteOffset: 24, as: UInt64.self)
            raw.storeBytes(of: superblock.tableBlock.littleEndian, toByteOffset: 32, as: UInt32.self)
            raw.storeBytes(of: superblock.tableBlockCount.littleEndian, toByteOffset: 36, as: UInt32.self)
            raw.storeBytes(of: superblock.tableChecksum.littleEndian, toByteOffset: 40, as: UInt32.self)
            raw.storeBytes(of: superblock.pageCount.littleEndian, toByteOffset: 44, as: UInt32.self)
            raw.storeBytes(of: UInt32(journalBlocks).littleEndian, toByteOffset: 48, as: UInt32.self)
            raw.storeBytes(of: checksum(raw.baseAddress!, blockSize - 4).littleEndian, toByteOffset: blockSize - 4, as: UInt32.self)
        }
        return block
    }

    /// The newer of the two blocks that point to the map, of those that are whole.
    private static func newestSuperblock(in descriptor: Int32) throws -> Superblock {
        var newest: Superblock?
        var sawMagic = false
        var block = [UInt8](repeating: 0, count: blockSize)
        for slot in 0..<2 {
            let got = block.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, blockSize, Int64(slot * blockSize)) }
            guard got == blockSize, Array(block[0..<magic.count]) == magic else { continue }
            sawMagic = true
            try block.withUnsafeBytes { raw in
                guard UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: blockSize - 4, as: UInt32.self)) == checksum(raw.baseAddress!, blockSize - 4) else { return }
                let found = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
                guard found == version else { throw DiskError.unsupportedVersion(found) }
                guard UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 12, as: UInt32.self)) == UInt32(clusterSize),
                      UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 48, as: UInt32.self)) == UInt32(journalBlocks)
                else { throw DiskError.corrupted("it is laid out in a way this version doesn't know") }
                let superblock = Superblock(
                    capacity: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: 16, as: UInt64.self)),
                    generation: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: 24, as: UInt64.self)),
                    tableBlock: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 32, as: UInt32.self)),
                    tableBlockCount: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 36, as: UInt32.self)),
                    tableChecksum: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 40, as: UInt32.self)),
                    pageCount: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 44, as: UInt32.self))
                )
                if newest == nil || superblock.generation > newest!.generation { newest = superblock }
            }
        }
        guard let newest else { throw sawMagic ? DiskError.corrupted("neither copy of its header is whole") : DiskError.notACompressedDisk }
        return newest
    }

    private static func readTable(_ superblock: Superblock, from descriptor: Int32) throws -> [TableEntry] {
        var table = [TableEntry](repeating: TableEntry(), count: Int(superblock.pageCount))
        guard superblock.tableBlockCount > 0 else { return table }
        let count = Int(superblock.tableBlockCount) * blockSize
        guard count >= table.count * 8 else { throw DiskError.corrupted("its map is cut short") }
        var encoded = [UInt8](repeating: 0, count: count)
        try encoded.withUnsafeMutableBytes { raw in
            try read(raw.baseAddress!, count, from: descriptor, at: Int64(superblock.tableBlock) * Int64(blockSize))
            guard checksum(raw.baseAddress!, count) == superblock.tableChecksum else {
                throw DiskError.corrupted("its map doesn't match its checksum")
            }
            for index in table.indices {
                table[index].block = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: index * 8, as: UInt32.self))
                table[index].checksum = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: index * 8 + 4, as: UInt32.self))
            }
        }
        return table
    }

    private func read(_ buffer: UnsafeMutableRawPointer, _ count: Int, at offset: Int64) throws {
        try Self.read(buffer, count, from: descriptor, at: offset)
    }

    private func write(_ buffer: UnsafeRawPointer, _ count: Int, at offset: Int64) throws {
        try Self.write(buffer, count, to: descriptor, at: offset)
    }

    private static func read(_ buffer: UnsafeMutableRawPointer, _ count: Int, from descriptor: Int32, at offset: Int64) throws {
        var done = 0
        while done < count {
            let got = pread(descriptor, buffer + done, count - done, offset + Int64(done))
            if got < 0 {
                if errno == EINTR { continue }
                throw DiskError.io(errno)
            }
            guard got > 0 else { throw DiskError.corrupted("it is cut short") }
            done += got
        }
    }

    private static func write(_ bytes: [UInt8], to descriptor: Int32, at offset: Int64) throws {
        try bytes.withUnsafeBytes { try write($0.baseAddress!, $0.count, to: descriptor, at: offset) }
    }

    private static func write(_ buffer: UnsafeRawPointer, _ count: Int, to descriptor: Int32, at offset: Int64) throws {
        var done = 0
        while done < count {
            let put = pwrite(descriptor, buffer + done, count - done, offset + Int64(done))
            if put < 0 {
                if errno == EINTR { continue }
                throw DiskError.io(errno)
            }
            done += put
        }
    }
}
