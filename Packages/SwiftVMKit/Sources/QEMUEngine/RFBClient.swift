import CoreGraphics
import Foundation
import GuestChannel
import IOSurface

/// The app's end of QEMU's VNC server: what the machine's display shows, and its keyboard and mouse.
///
/// QEMU listens nowhere. The app hands it one end of a socket pair over its machine protocol
/// (`add_client`) and speaks the remote framebuffer protocol (RFB, RFC 6143) over the other, so no other
/// program on the Mac can look at the screen.
///
/// The picture is kept in an `IOSurface` that the protocol's updates are written straight into, and a
/// layer shows the surface as it is: whatever shows the display, all of it or one window's part of it,
/// shows the same surface. Keys go by where they are on a PC keyboard (QEMU's extended key event), so
/// that what they type is up to the guest's own keyboard layout.
public final class RFBClient: @unchecked Sendable {
    /// The picture, and what it is the picture of.
    public struct Picture: @unchecked Sendable {
        public var surface: IOSurface
        public var width: Int
        public var height: Int
    }

    /// The pointer as the guest draws it, when the guest has one of its own that it hands over rather
    /// than drawing it into the picture.
    public struct Cursor: @unchecked Sendable {
        public var image: CGImage
        public var hotSpot: CGPoint
    }

    /// Called on the client's thread when part of the picture has changed, with that part, in pixels
    /// from the top left corner.
    public var onUpdate: (@Sendable (CGRect) -> Void)? {
        get { lock.withLock { updateHandler } }
        set { lock.withLock { updateHandler = newValue } }
    }

    /// Called on the client's thread when the display has a new size, and so a new picture.
    public var onResize: (@Sendable (Picture) -> Void)? {
        get { lock.withLock { resizeHandler } }
        set { lock.withLock { resizeHandler = newValue } }
    }

    /// Called on the client's thread when the guest has a new pointer to show.
    public var onCursor: (@Sendable (Cursor?) -> Void)? {
        get { lock.withLock { cursorHandler } }
        set { lock.withLock { cursorHandler = newValue } }
    }

    /// Called once on the client's thread when the line is gone.
    public var onClose: (@Sendable () -> Void)? {
        get { lock.withLock { closeHandler } }
        set { lock.withLock { closeHandler = newValue } }
    }

    private let descriptor: Int32
    private let lock = NSLock()
    /// Writes go out one at a time, and never on the thread that reads.
    private let writer = DispatchQueue(label: "app.swiftvm.rfb.write", qos: .userInteractive)
    private var updateHandler: (@Sendable (CGRect) -> Void)?
    private var resizeHandler: (@Sendable (Picture) -> Void)?
    private var cursorHandler: (@Sendable (Cursor?) -> Void)?
    private var closeHandler: (@Sendable () -> Void)?
    private var currentPicture: Picture?
    private var isClosed = false
    /// A thread reads from the server, and closes the descriptor once it is done.
    private var isReading = false
    /// The server takes requests for a size of the display: the guest's driver can change it.
    private var takesSizeRequests = false
    private var screenID: UInt32 = 0
    /// The latest window size, including one requested before the server advertised resizing.
    private var requestedSize: (width: UInt16, height: UInt16)?
    private var buttons: UInt8 = 0
    /// Reused by the reader thread. Socket reads must finish before locking the displayed surface.
    private var rectanglePixels = [UInt8]()

    /// Takes over `descriptor`, one end of a connected socket pair whose other end QEMU has.
    public init(descriptor: Int32) {
        self.descriptor = descriptor
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
    }

    deinit {
        close()
    }

    /// The picture as it is now, `nil` before the first one.
    public var picture: Picture? { lock.withLock { currentPicture } }

    /// Whether the display can be asked to change its size, which takes a guest with a driver for it.
    public var canRequestSize: Bool { lock.withLock { takesSizeRequests } }

    /// Says hello the way the protocol has it, and starts reading on a thread of its own. It waits for
    /// the server's side of the hello, which QEMU sends at once: call it where waiting is no harm.
    public func open() throws {
        let reader = Reader(descriptor: descriptor)
        let (width, height) = try handshake(reader)
        try makePicture(width: width, height: height)
        lock.withLock { isReading = true }
        let thread = Thread { [self] in readLoop(reader) }
        thread.name = "app.swiftvm.rfb"
        thread.qualityOfService = .userInteractive
        thread.start()
        requestUpdate(incremental: false)
    }

    public func close() {
        let (shouldClose, isReading) = lock.withLock { () -> (Bool, Bool) in
            guard !isClosed else { return (false, false) }
            isClosed = true
            return (true, self.isReading)
        }
        guard shouldClose else { return }
        shutdown(descriptor, SHUT_RDWR)
        // Without a thread that reads, nothing else closes it.
        if !isReading {
            closeAfterWrites()
        }
    }

    /// Closes the descriptor after what is being written: on the queue that writes, so that no write
    /// uses its number once it may be another's.
    private func closeAfterWrites() {
        writer.async { [descriptor] in Darwin.close(descriptor) }
    }

    // MARK: Input

    /// Presses or lets go of the key at `scancode`, as a PC keyboard numbers its keys: the second byte
    /// of those that come after 0xE0, with the high bit set.
    public func key(_ scancode: UInt16, down: Bool) {
        var message = Data([255, 0])
        message.append(bigEndian: UInt16(down ? 1 : 0))
        // No character: QEMU goes by the key.
        message.append(bigEndian: UInt32(0))
        message.append(bigEndian: UInt32(scancode))
        send(message)
    }

    /// The mouse's buttons and wheel, as RFB numbers them: one bit each.
    public struct Buttons: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let left = Buttons(rawValue: 1)
        public static let middle = Buttons(rawValue: 2)
        public static let right = Buttons(rawValue: 4)
        public static let wheelUp = Buttons(rawValue: 8)
        public static let wheelDown = Buttons(rawValue: 16)
        public static let wheelLeft = Buttons(rawValue: 32)
        public static let wheelRight = Buttons(rawValue: 64)
    }

    /// Puts the pointer at a pixel of the display with these buttons held.
    public func pointer(x: Int, y: Int, buttons: Buttons) {
        guard let picture else { return }
        let x = UInt16(clamping: min(max(x, 0), picture.width - 1))
        let y = UInt16(clamping: min(max(y, 0), picture.height - 1))
        var message = Data([5, buttons.rawValue])
        message.append(bigEndian: x)
        message.append(bigEndian: y)
        send(message)
    }

    /// Asks for the display to be this size. A guest without a driver that can change it stays as it is.
    public func requestSize(width: Int, height: Int) {
        guard width >= 320, height >= 240 else { return }
        lock.withLock { requestedSize = (UInt16(clamping: width), UInt16(clamping: height)) }
        sendRequestedSize()
    }

    private func sendRequestedSize() {
        writer.async { [self] in
            // Read the latest size on the writer, so negotiation and a window resize racing each
            // other cannot send an older size after the newer one.
            let request = lock.withLock { () -> (UInt32, UInt16, UInt16)? in
                guard !isClosed, takesSizeRequests, let requestedSize else { return nil }
                return (screenID, requestedSize.width, requestedSize.height)
            }
            guard let (screen, width, height) = request else { return }
            var message = Data([251, 0])
            message.append(bigEndian: width)
            message.append(bigEndian: height)
            message.append(contentsOf: [1, 0])
            message.append(bigEndian: screen)
            message.append(bigEndian: UInt16(0))
            message.append(bigEndian: UInt16(0))
            message.append(bigEndian: width)
            message.append(bigEndian: height)
            message.append(bigEndian: UInt32(0))
            _ = ByteRelay.writeAll(ArraySlice(message), to: descriptor)
        }
    }

    private func send(_ message: Data) {
        writer.async { [self] in
            guard !lock.withLock({ isClosed }) else { return }
            _ = ByteRelay.writeAll(ArraySlice(message), to: descriptor)
        }
    }

    private func requestUpdate(incremental: Bool) {
        guard let picture else { return }
        var message = Data([3, incremental ? 1 : 0])
        message.append(bigEndian: UInt16(0))
        message.append(bigEndian: UInt16(0))
        message.append(bigEndian: UInt16(clamping: picture.width))
        message.append(bigEndian: UInt16(clamping: picture.height))
        send(message)
    }

    // MARK: Starting

    /// The kinds of rectangles this client reads, in the order it would rather have them.
    enum Encoding: Int32 {
        case raw = 0
        case copyRect = 1
        case desktopSize = -223
        case lastRect = -224
        case cursor = -239
        case qemuExtendedKey = -258
        case extendedDesktopSize = -308
        case alphaCursor = -314
    }

    private func handshake(_ reader: Reader) throws -> (Int, Int) {
        // Version: QEMU speaks 3.8, and so does this.
        let version = try reader.bytes(12)
        guard version.starts(with: Data("RFB 003.".utf8)) else { throw RFBError.notRFB }
        try write(Data("RFB 003.008\n".utf8))
        // Security: nobody else has this line, so it takes none.
        let count = Int(try reader.byte())
        guard count > 0 else {
            let reason = try reader.string(Int(try reader.uint32()))
            throw RFBError.refused(reason)
        }
        let types = try reader.bytes(count)
        guard types.contains(1) else { throw RFBError.refused("The VNC server wants a password.") }
        try write(Data([1]))
        guard try reader.uint32() == 0 else {
            let reason = (try? reader.string(Int(reader.uint32()))) ?? ""
            throw RFBError.refused(reason)
        }
        // Shared: a second client, if there ever is one, doesn't put this one off.
        try write(Data([1]))
        let width = Int(try reader.uint16())
        let height = Int(try reader.uint16())
        _ = try reader.bytes(16)
        _ = try reader.string(Int(try reader.uint32()))

        // Pixels as the surface keeps them: four bytes, blue first, and one that says nothing.
        var format = Data([0, 0, 0, 0, 32, 24, 0, 1])
        format.append(bigEndian: UInt16(255))
        format.append(bigEndian: UInt16(255))
        format.append(bigEndian: UInt16(255))
        format.append(contentsOf: [16, 8, 0, 0, 0, 0])
        try write(format)
        let encodings: [Encoding] = [.copyRect, .raw, .extendedDesktopSize, .desktopSize, .lastRect, .alphaCursor, .cursor, .qemuExtendedKey]
        var setEncodings = Data([2, 0])
        setEncodings.append(bigEndian: UInt16(encodings.count))
        for encoding in encodings {
            setEncodings.append(bigEndian: UInt32(bitPattern: encoding.rawValue))
        }
        try write(setEncodings)
        return (width, height)
    }

    private func write(_ data: Data) throws {
        guard ByteRelay.writeAll(ArraySlice(data), to: descriptor) else { throw RFBError.disconnected }
    }

    private func makePicture(width: Int, height: Int) throws {
        guard width > 0, height > 0 else { throw RFBError.malformed }
        let properties: [IOSurfacePropertyKey: any Sendable] = [
            .width: width, .height: height, .bytesPerElement: 4, .pixelFormat: Self.pixelFormat,
        ]
        guard let surface = IOSurface(properties: properties) else { throw RFBError.malformed }
        let picture = Picture(surface: surface, width: width, height: height)
        let handler = lock.withLock { () -> (@Sendable (Picture) -> Void)? in
            currentPicture = picture
            return resizeHandler
        }
        handler?(picture)
    }

    /// `BGRA`, as the pixel format above lays the bytes out.
    static let pixelFormat: OSType = 0x4247_5241

    // MARK: Reading

    private func readLoop(_ reader: Reader) {
        do {
            while true {
                switch try reader.byte() {
                case 0:
                    try readUpdate(reader)
                case 1:
                    // Colours of a palette, which a true-colour client never asked for.
                    _ = try reader.bytes(3)
                    let count = Int(try reader.uint16())
                    _ = try reader.bytes(count * 6)
                case 2:
                    break
                case 3:
                    // Text the server cut. The guest tools share the clipboard instead.
                    _ = try reader.bytes(3)
                    let length = Int(Int32(bitPattern: try reader.uint32()))
                    guard length >= 0, length < 16 << 20 else { throw RFBError.malformed }
                    _ = try reader.bytes(length)
                default:
                    throw RFBError.malformed
                }
            }
        } catch {}
        close()
        closeAfterWrites()
        let handler = lock.withLock { closeHandler }
        handler?()
    }

    private func readUpdate(_ reader: Reader) throws {
        _ = try reader.byte()
        let count = Int(try reader.uint16())
        let previousPicture = picture
        // Keep one update ahead while this one is received. Waiting until its pixels are copied can
        // miss QEMU's next refresh and make it back off even while the guest is drawing continuously.
        requestUpdate(incremental: true)
        var changed = CGRect.null
        rectangles: for _ in 0..<count {
            let x = Int(try reader.uint16())
            let y = Int(try reader.uint16())
            let width = Int(try reader.uint16())
            let height = Int(try reader.uint16())
            let encoding = Int32(bitPattern: try reader.uint32())
            switch Encoding(rawValue: encoding) {
            case .raw:
                try readRaw(reader, x: x, y: y, width: width, height: height)
                changed = changed.union(CGRect(x: x, y: y, width: width, height: height))
            case .copyRect:
                let sourceX = Int(try reader.uint16())
                let sourceY = Int(try reader.uint16())
                copy(fromX: sourceX, fromY: sourceY, toX: x, toY: y, width: width, height: height)
                changed = changed.union(CGRect(x: x, y: y, width: width, height: height))
            case .desktopSize:
                try makePicture(width: width, height: height)
                changed = .null
            case .extendedDesktopSize:
                let screens = Int(try reader.byte())
                _ = try reader.bytes(3)
                var firstScreen: UInt32?
                for _ in 0..<screens {
                    let id = try reader.uint32()
                    _ = try reader.bytes(12)
                    firstScreen = firstScreen ?? id
                }
                // The server says it takes requests for a size by sending one of these at all.
                let firstSize = lock.withLock {
                    let firstSize = !takesSizeRequests
                    takesSizeRequests = true
                    screenID = firstScreen ?? 0
                    return firstSize
                }
                if firstSize { sendRequestedSize() }
                // Also the answer to a request that changed nothing comes as one, with the size as it is.
                if width > 0, height > 0, width != picture?.width || height != picture?.height {
                    try makePicture(width: width, height: height)
                    changed = .null
                }
            case .cursor:
                try readCursor(reader, width: width, height: height, hotSpot: CGPoint(x: x, y: y))
            case .alphaCursor:
                try readAlphaCursor(reader, width: width, height: height, hotSpot: CGPoint(x: x, y: y))
            case .lastRect:
                break rectangles
            case .qemuExtendedKey:
                // The server says that it takes keys by their place. It always does, being QEMU.
                break
            case nil:
                // A kind that wasn't asked for. Its length is unknown, so nothing after it can be read.
                throw RFBError.malformed
            }
        }
        if !changed.isNull {
            let handler = lock.withLock { updateHandler }
            handler?(changed)
        }
        if let picture, picture.width != previousPicture?.width || picture.height != previousPicture?.height {
            // The request above used the old bounds. Fetch the whole new display, including any part
            // outside them; QEMU coalesces this with the pending incremental request.
            requestUpdate(incremental: false)
        }
    }

    private func readRaw(_ reader: Reader, x: Int, y: Int, width: Int, height: Int) throws {
        let rowLength = width * 4
        let byteCount = rowLength * height
        guard let picture, x + width <= picture.width, y + height <= picture.height else {
            // A rectangle off the picture, as one that was on its way while the size changed may be.
            try reader.skip(byteCount)
            return
        }
        guard byteCount > 0 else { return }
        if rectanglePixels.count < byteCount {
            rectanglePixels = [UInt8](repeating: 0, count: byteCount)
        }
        try rectanglePixels.withUnsafeMutableBytes { buffer in
            try reader.read(into: UnsafeMutableRawBufferPointer(rebasing: buffer[..<byteCount]))
        }
        let surface = picture.surface
        let stride = surface.bytesPerRow
        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        let destination = surface.baseAddress + y * stride + x * 4
        // Lock once for the rectangle, not once per scanline. Apart from the syscall overhead, each
        // lock can wait for the compositor that is showing this same surface.
        rectanglePixels.withUnsafeBytes { pixels in
            if stride == rowLength {
                destination.copyMemory(from: pixels.baseAddress!, byteCount: byteCount)
            } else {
                for line in 0..<height {
                    (destination + line * stride).copyMemory(from: pixels.baseAddress! + line * rowLength, byteCount: rowLength)
                }
            }
        }
    }

    private func copy(fromX: Int, fromY: Int, toX: Int, toY: Int, width: Int, height: Int) {
        guard let picture, fromX + width <= picture.width, fromY + height <= picture.height,
              toX + width <= picture.width, toY + height <= picture.height
        else { return }
        let surface = picture.surface
        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        // Rows go from the bottom up when the rectangle moves down, so that none is overwritten
        // before it is copied.
        let rows = toY > fromY ? Array((0..<height).reversed()) : Array(0..<height)
        for line in rows {
            let source = surface.baseAddress + (fromY + line) * surface.bytesPerRow + fromX * 4
            let destination = surface.baseAddress + (toY + line) * surface.bytesPerRow + toX * 4
            memmove(destination, source, width * 4)
        }
    }

    /// A pointer in the client's pixel format, with a bit mask for which of its pixels are there.
    private func readCursor(_ reader: Reader, width: Int, height: Int, hotSpot: CGPoint) throws {
        let pixels = try reader.bytes(width * height * 4)
        let mask = try reader.bytes((width + 7) / 8 * height)
        guard width > 0, height > 0 else {
            report(cursor: nil)
            return
        }
        // Into premultiplied BGRA: a pixel that isn't there is clear.
        var image = [UInt8](pixels)
        let maskRow = (width + 7) / 8
        for y in 0..<height {
            for x in 0..<width {
                let isThere = mask[mask.startIndex + y * maskRow + x / 8] & (0x80 >> (x % 8)) != 0
                let index = (y * width + x) * 4
                if isThere {
                    image[index + 3] = 255
                } else {
                    image[index] = 0
                    image[index + 1] = 0
                    image[index + 2] = 0
                    image[index + 3] = 0
                }
            }
        }
        report(cursor: Self.cursor(bgra: image, width: width, height: height, hotSpot: hotSpot))
    }

    /// A pointer with an alpha channel: RGBA, whatever the pixel format.
    private func readAlphaCursor(_ reader: Reader, width: Int, height: Int, hotSpot: CGPoint) throws {
        let encoding = Int32(bitPattern: try reader.uint32())
        guard encoding == Encoding.raw.rawValue else { throw RFBError.malformed }
        let pixels = [UInt8](try reader.bytes(width * height * 4))
        guard width > 0, height > 0 else {
            report(cursor: nil)
            return
        }
        // Premultiplied, blue first.
        var image = pixels
        for index in stride(from: 0, to: image.count, by: 4) {
            let alpha = UInt16(pixels[index + 3])
            image[index] = UInt8(UInt16(pixels[index + 2]) * alpha / 255)
            image[index + 1] = UInt8(UInt16(pixels[index + 1]) * alpha / 255)
            image[index + 2] = UInt8(UInt16(pixels[index]) * alpha / 255)
        }
        report(cursor: Self.cursor(bgra: image, width: width, height: height, hotSpot: hotSpot))
    }

    private static func cursor(bgra: [UInt8], width: Int, height: Int, hotSpot: CGPoint) -> Cursor? {
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bgra) as CFData),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              )
        else { return nil }
        return Cursor(image: image, hotSpot: hotSpot)
    }

    private func report(cursor: Cursor?) {
        let handler = lock.withLock { cursorHandler }
        handler?(cursor)
    }
}

public enum RFBError: Error, LocalizedError, Equatable {
    case notRFB
    case refused(String)
    case malformed
    case disconnected

    public var errorDescription: String? {
        switch self {
        case .notRFB: "The machine's display doesn't speak VNC."
        case .refused(let reason): "The machine's display turned the app away: \(reason)"
        case .malformed: "The machine's display sent something that isn't VNC."
        case .disconnected: "The line to the machine's display is gone."
        }
    }
}

// MARK: - Reading and writing bytes

/// Buffers protocol headers and reads large pixel payloads directly into their destination.
private final class Reader: @unchecked Sendable {
    let descriptor: Int32
    private var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    private var position = 0
    private var available = 0

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func read(into destination: UnsafeMutableRawBufferPointer) throws {
        var offset = 0
        while offset < destination.count {
            if position < available {
                let count = min(available - position, destination.count - offset)
                buffer.withUnsafeBytes { bytes in
                    (destination.baseAddress! + offset).copyMemory(from: bytes.baseAddress! + position, byteCount: count)
                }
                position += count
                offset += count
            } else if destination.count - offset >= buffer.count {
                offset += try receive(into: destination.baseAddress! + offset, count: destination.count - offset)
            } else {
                try refill()
            }
        }
    }

    private func receive(into destination: UnsafeMutableRawPointer, count: Int) throws -> Int {
        while true {
            let received = Darwin.read(descriptor, destination, count)
            if received > 0 { return received }
            if received == 0 || errno != EINTR { throw RFBError.disconnected }
        }
    }

    private func refill() throws {
        available = try buffer.withUnsafeMutableBytes { try receive(into: $0.baseAddress!, count: $0.count) }
        position = 0
    }

    func skip(_ count: Int) throws {
        var remaining = count
        while remaining > 0 {
            if position == available { try refill() }
            let consumed = min(remaining, available - position)
            position += consumed
            remaining -= consumed
        }
    }

    func bytes(_ count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { try read(into: $0) }
        return data
    }

    func byte() throws -> UInt8 {
        if position == available { try refill() }
        let value = buffer[position]
        position += 1
        return value
    }

    func uint16() throws -> UInt16 {
        let high = try byte()
        return try UInt16(high) << 8 | UInt16(byte())
    }

    func uint32() throws -> UInt32 {
        let high = try uint16()
        return try UInt32(high) << 16 | UInt32(uint16())
    }

    func string(_ count: Int) throws -> String {
        guard count >= 0, count < 1 << 20 else { throw RFBError.malformed }
        return String(decoding: try bytes(count), as: UTF8.self)
    }
}

extension Data {
    mutating func append<Number: FixedWidthInteger>(bigEndian number: Number) {
        Swift.withUnsafeBytes(of: number.bigEndian) { append(contentsOf: $0) }
    }
}
