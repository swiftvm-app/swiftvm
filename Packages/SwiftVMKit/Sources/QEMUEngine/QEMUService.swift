import Foundation
import VMControl

/// `swiftvm serve`, which runs the app's QEMU machines: where it listens, and how to start it when nothing
/// does there.
public struct QEMUService: Sendable {
    public let socketURL: URL
    /// Starts the service when nothing answers on its socket: after it stopped because its program was
    /// replaced, or before the app started it.
    public let startService: @Sendable () -> Void

    public init(socketURL: URL, startService: @escaping @Sendable () -> Void) {
        self.socketURL = socketURL
        self.startService = startService
    }

    /// A connection that has said hello. When nothing answers, the service is started, and given a while.
    /// It blocks: call it away from the main thread.
    func connect() throws -> ServiceConnection {
        do {
            return try ServiceConnection(socketURL: socketURL)
        } catch ControlSocketError.appNotRunning {
            startService()
        }
        let deadline = Date().addingTimeInterval(10)
        while true {
            do {
                return try ServiceConnection(socketURL: socketURL)
            } catch ControlSocketError.appNotRunning where Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }

    /// Sends one request on a connection of its own and returns the answer. A failure is thrown.
    @discardableResult
    func call(_ request: QEMURequest) async throws -> QEMUAnswer {
        try await Task.detached {
            let connection = try connect()
            defer { connection.close() }
            return try connection.send(request)
        }.value
    }

    /// Ends the QEMU that is running for the machine in `bundle`, under the service or left behind by an
    /// app that stopped without stopping it, and waits until it is gone.
    public func endLeftover(bundle: URL) async {
        var request = QEMURequest(command: "qemu-stop")
        request.bundle = bundle.path
        request.force = true
        _ = try? await call(request)
    }
}
