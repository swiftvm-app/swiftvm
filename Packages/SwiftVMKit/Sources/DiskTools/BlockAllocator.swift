/// Keeps track of which 4 KiB blocks of a compressed disk's file are in use.
///
/// Nothing of this is stored: it is worked out from the map when the disk is opened.
struct BlockAllocator {
    struct Run: Equatable {
        var block: Int
        var count: Int
    }

    /// The first block that can be handed out. What lies before it has a fixed purpose.
    let start: Int
    /// One past the last block that was ever handed out.
    private(set) var end: Int
    private var used: [UInt64] = []
    /// Free blocks that the file system may still hold storage for.
    private var stale: [UInt64] = []
    private var cursor: Int

    init(start: Int) {
        self.start = start
        end = start
        cursor = start
    }

    private func isSet(_ bits: [UInt64], _ index: Int) -> Bool {
        bits[index >> 6] & (1 << UInt64(index & 63)) != 0
    }

    private mutating func reserve(through block: Int) {
        let words = (block >> 6) + 1
        if words > used.count {
            used.append(contentsOf: repeatElement(0, count: words - used.count))
            stale.append(contentsOf: repeatElement(0, count: words - stale.count))
        }
    }

    /// Takes blocks that are known to be in use, while the disk is being opened.
    mutating func markUsed(_ block: Int, _ count: Int) {
        guard count > 0 else { return }
        reserve(through: block + count - 1)
        for index in block..<(block + count) {
            used[index >> 6] |= 1 << UInt64(index & 63)
            stale[index >> 6] &= ~(1 << UInt64(index & 63))
        }
        end = max(end, block + count)
    }

    /// Hands out `count` blocks in a row: the first gap that fits, or new blocks at the end of the file.
    mutating func allocate(_ count: Int) -> Int {
        var index = cursor
        while index + count <= end {
            if index & 63 == 0, used[index >> 6] == .max {
                index += 64
                continue
            }
            if isSet(used, index) {
                index += 1
                continue
            }
            var run = 1
            while run < count, !isSet(used, index + run) { run += 1 }
            if run == count {
                markUsed(index, count)
                cursor = index + count
                return index
            }
            index += run + 1
        }
        let block = end
        markUsed(block, count)
        cursor = end
        return block
    }

    /// Gives blocks back. They can be handed out again right away, so this is only called once nothing
    /// that could still be read after a crash points to them.
    mutating func release(_ block: Int, _ count: Int) {
        for index in block..<(block + count) {
            used[index >> 6] &= ~(1 << UInt64(index & 63))
            stale[index >> 6] |= 1 << UInt64(index & 63)
        }
        cursor = min(cursor, block)
    }

    /// Lets go of the free blocks at the end, and says where the end is now if it has moved. The file
    /// is cut off there: nothing may be handed out again before it is.
    mutating func trimEnd() -> Int? {
        var last = end
        while last > start {
            if last & 63 == 0, used[(last - 1) >> 6] == 0 {
                last = max(last - 64, start)
            } else if !isSet(used, last - 1) {
                last -= 1
            } else {
                break
            }
        }
        guard last < end else { return nil }
        for index in last..<end { stale[index >> 6] &= ~(1 << UInt64(index & 63)) }
        end = last
        cursor = min(cursor, end)
        return end
    }

    /// Calls every free block stale: after a crash nothing says which of them still take up space.
    mutating func markAllFreeStale() {
        guard end > start else { return }
        for index in start..<end where !isSet(used, index) {
            stale[index >> 6] |= 1 << UInt64(index & 63)
        }
    }

    /// The next run of at least `minimum` stale blocks from `position` on, taken out of circulation
    /// until ``finishReclaiming(_:)`` so that nobody is handed a block while its storage is being given
    /// back. Shorter runs stay stale, to be handed out again or asked for later.
    mutating func takeStaleRun(from position: Int, minimum: Int = 1, limit: Int = 1 << 16) -> Run? {
        var index = max(position, start)
        while index < end {
            if index & 63 == 0, stale[index >> 6] == 0 {
                index += 64
                continue
            }
            if !isSet(stale, index) {
                index += 1
                continue
            }
            var count = 1
            while count < limit, index + count < end, isSet(stale, index + count) { count += 1 }
            if count < minimum {
                index += count
                continue
            }
            markUsed(index, count)
            return Run(block: index, count: count)
        }
        return nil
    }

    mutating func finishReclaiming(_ run: Run) {
        for index in run.block..<(run.block + run.count) {
            used[index >> 6] &= ~(1 << UInt64(index & 63))
        }
        cursor = min(cursor, run.block)
    }
}
