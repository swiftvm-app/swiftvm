import AppKit
import GuestDisplayBridge
import VMCore

/// Input is independent of how pixels reach the view. Existing saved sessions keep VNC; accelerated
/// guests keep one SPICE connection for their entire run, including while their window is closed.
protocol GuestScreenInput: AnyObject, Sendable {
    func key(_ scancode: UInt16, down: Bool)
    func pointer(x: Int, y: Int, buttons: RFBClient.Buttons)
    /// The guest's display is to be this large, in pixels, at `scale` pixels to a point.
    func requestSize(width: Int, height: Int, scale: Double)
}

extension RFBClient: GuestScreenInput {
    // Windows sets its own scale.
    func requestSize(width: Int, height: Int, scale: Double) {
        requestSize(width: width, height: height)
    }
}

final class SpiceClient: GuestScreenInput, @unchecked Sendable {
    @MainActor private let runtime: any SVMGuestDisplay
    @MainActor private var opening: CheckedContinuation<Void, any Error>?
    @MainActor private var closed = false
    @MainActor var size: CGSize = .zero
    @MainActor var onResize: ((CGSize) -> Void)?
    @MainActor var onDisconnect: ((String) -> Void)?
    /// A size was asked of the guest's display: in pixels, at so many pixels to a point.
    @MainActor var onSizeRequest: ((_ width: Int, _ height: Int, _ scale: Double) -> Void)?

    let directory: URL
    var socket: URL { directory.appending(path: "display.sock") }
    @MainActor var view: NSView { runtime.view }

    @MainActor init(library: URL) throws {
        // Unix socket names are limited to 104 bytes. A private directory under /tmp leaves enough
        // room even when the user's system temporary directory has a long name.
        var template = Array("/tmp/swiftvm-gpu-XXXXXX".utf8CString)
        guard let path = mkdtemp(&template) else { throw QEMUError.didNotStart(String(cString: strerror(errno))) }
        directory = URL(fileURLWithPath: String(cString: path), isDirectory: true)
        do {
            var error: NSError?
            guard let display = SVMGuestDisplayLoad(library, directory.appending(path: "display.sock"), &error) else {
                throw error ?? QEMUError.didNotStart("The display library that comes with QEMU couldn't be loaded.") as NSError
            }
            runtime = display
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        runtime.connected = { [weak self] error in
            MainActor.assumeIsolated {
                guard let self, let opening = self.opening else { return }
                self.opening = nil
                if let error { opening.resume(throwing: error) } else { opening.resume() }
            }
        }
        runtime.resized = { [weak self] size in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                self.size = size
                self.onResize?(size)
            }
        }
        runtime.disconnected = { [weak self] reason in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                self.opening?.resume(throwing: QEMUError.didNotStart(reason))
                self.opening = nil
                self.onDisconnect?(reason)
            }
        }
    }

    @MainActor func open() async throws {
        try await withCheckedThrowingContinuation { continuation in
            opening = continuation
            runtime.connect()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard let self, let opening = self.opening else { return }
                self.opening = nil
                opening.resume(throwing: QEMUError.didNotStart("The Windows display didn't connect."))
            }
        }
    }

    @MainActor func close() {
        guard !closed else { return }
        closed = true
        opening?.resume(throwing: QEMUError.disconnected)
        opening = nil
        runtime.close()
        try? FileManager.default.removeItem(at: directory)
    }

    func key(_ scancode: UInt16, down: Bool) {
        DispatchQueue.main.async { [self] in
            guard !closed else { return }
            runtime.key(scancode, down: down)
        }
    }

    func pointer(x: Int, y: Int, buttons: RFBClient.Buttons) {
        DispatchQueue.main.async { [self] in
            guard !closed, size.width > 0, size.height > 0 else { return }
            let point = CGPoint(x: min(max(x, 0), Int(size.width) - 1), y: min(max(y, 0), Int(size.height) - 1))
            runtime.pointer(at: point, buttons: buttons.rawValue)
        }
    }

    func requestSize(width: Int, height: Int, scale: Double) {
        DispatchQueue.main.async { [self] in
            guard !closed, (320...16384).contains(width), (200...16384).contains(height) else { return }
            runtime.requestSize(CGSize(width: width, height: height))
            onSizeRequest?(width, height, scale)
        }
    }

    @MainActor func screenshot() async throws -> Data {
        guard !closed else { throw QEMUError.disconnected }
        return try await withCheckedThrowingContinuation { continuation in
            runtime.screenshot { png in
                if let png { continuation.resume(returning: png) }
                else { continuation.resume(throwing: MachineDeskError.nothingShown) }
            }
        }
    }
}
