import Foundation
import GuestChannel

/// The screen, the mouse and the keyboard of whoever is logged in, as far as the agent has to do with
/// them. Places are in the pixels of a screenshot, from its top left corner.
protocol AgentDesktop: Sendable {
    /// What is on the screen right now, as a PNG.
    func screenshot() throws -> Data
    func pointer(_ request: GuestJob.Pointer) throws
    func keys(_ request: GuestJob.Keys) throws
    /// What is on the screen as a tree of its parts, in JSON.
    func tree(_ request: GuestJob.Tree) throws -> Data
    /// Does something to one part of that tree, and says to which, in JSON.
    func act(on request: GuestJob.Element) throws -> Data
    /// Says whether the system lets the agent read the screen as a tree, asks it to, or puts away what
    /// asking opened: a ``GuestPermissionState`` in JSON.
    func permission(_ request: GuestJob.Permission) throws -> Data
}

/// A job that the agent's half in a user's session does: one with the screen, the mouse or the keyboard,
/// or with what the system lets this half do with them.
///
/// The half that runs as root says that there is one, and under which name. This half connects for it,
/// and from there on it is the one that answers the Mac: what it sends is passed on as it is.
enum SessionJob {
    /// How long the job itself may take to arrive once it was asked for.
    static let requestTimeout: TimeInterval = 5

    /// Asks the half that runs as root for the job it announced under `token`, does it, and hangs up.
    /// Waits for as long as the job takes: call it where that is no harm.
    static func run(token: String, desktop: any AgentDesktop, connect: () -> Int32?) {
        guard let descriptor = connect() else { return }
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        if ByteRelay.writeAll(ArraySlice(GuestMessageCoding.line(for: SessionJobNotice(token: token))), to: descriptor) {
            serve(on: descriptor, desktop: desktop)
        }
        GuestJobLine.hangUp(descriptor)
    }

    /// Reads a job from a connection, takes it on, and does it: what the job is for goes back in
    /// frames, and the last one says how it ended.
    static func serve(on descriptor: Int32, desktop: any AgentDesktop) {
        guard let line = GuestJobLine.read(from: descriptor, timeout: requestTimeout),
              let job = GuestMessageCoding.message(GuestJob.self, from: line)
        else { return }
        switch job {
        case .screenshot, .pointer, .keys, .tree, .element, .permission:
            break
        case .exec, .unknown:
            GuestJobLine.answer(.refusal("That isn't a job for a user's session."), on: descriptor)
            return
        }
        // The yes comes at once: the Mac doesn't wait long for it, and some of this takes its time.
        // What goes wrong from here on is how the job ends.
        guard GuestJobLine.answer(GuestJobAnswer(ok: true), on: descriptor) else { return }
        do {
            let output: Data?
            switch job {
            case .screenshot:
                output = try desktop.screenshot()
            case .pointer(let request):
                try desktop.pointer(request)
                output = nil
            case .keys(let request):
                try desktop.keys(request)
                output = nil
            case .tree(let request):
                output = try desktop.tree(request)
            case .element(let request):
                output = try desktop.act(on: request)
            case .permission(let request):
                output = try desktop.permission(request)
            case .exec, .unknown:
                output = nil
            }
            if let output, !output.isEmpty {
                guard JobFrame.write(.output, output, to: descriptor) else { return }
            }
            JobFrame.write(.end, JobFrame.end(.success).payload, to: descriptor)
        } catch {
            let reason = (error as? AgentFailure)?.message ?? error.localizedDescription
            JobFrame.write(.end, JobFrame.end(.failure(reason)).payload, to: descriptor)
        }
    }
}
