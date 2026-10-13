import Foundation
import Testing
@testable import GuestChannel

@Suite struct GuestJobTests {
    private func text(_ job: GuestJob) -> String {
        String(decoding: GuestMessageCoding.line(for: job), as: UTF8.self)
    }

    /// A connected pair of sockets, for the two ends of a job's connection.
    private func makeLine() -> (near: Int32, far: Int32) {
        var descriptors: [Int32] = [0, 0]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        for descriptor in descriptors {
            _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        }
        return (descriptors[0], descriptors[1])
    }

    @Test func jobsAreOneJSONObjectPerLine() {
        // These are what the agents in a guest parse; changing one changes the protocol.
        #expect(text(.exec(.init(arguments: ["ls", "-l"], user: "root", directory: "/tmp", environment: ["A": "b"])))
            == #"{"arguments":["ls","-l"],"directory":"/tmp","environment":{"A":"b"},"type":"exec","user":"root"}"# + "\n")
        #expect(text(.exec(.init(arguments: ["true"]))) == #"{"arguments":["true"],"type":"exec"}"# + "\n")
        #expect(text(.screenshot) == #"{"type":"screenshot"}"# + "\n")
        #expect(text(.pointer(.init(action: .click, x: 10, y: 20, button: .right, count: 2)))
            == #"{"action":"click","button":"right","count":2,"type":"pointer","x":10,"y":20}"# + "\n")
        #expect(text(.pointer(.init(action: .drag, x: 1, y: 2, toX: 3, toY: 4)))
            == #"{"action":"drag","toX":3,"toY":4,"type":"pointer","x":1,"y":2}"# + "\n")
        #expect(text(.pointer(.init(action: .scroll, x: 1, y: 2, deltaX: 0, deltaY: -3)))
            == #"{"action":"scroll","deltaX":0,"deltaY":-3,"type":"pointer","x":1,"y":2}"# + "\n")
        #expect(text(.keys(.init(text: "hi"))) == #"{"text":"hi","type":"keys"}"# + "\n")
        #expect(text(.keys(.init(keys: ["ctrl+c", "Return"]))) == #"{"keys":["ctrl+c","Return"],"type":"keys"}"# + "\n")
        #expect(text(.tree(.init(application: "Files", depth: 3, all: true)))
            == #"{"all":true,"application":"Files","depth":3,"type":"tree"}"# + "\n")
        #expect(text(.element(.init(action: .set, element: "12/0/3", text: "hello")))
            == #"{"action":"set","element":"12/0/3","text":"hello","type":"element"}"# + "\n")
        #expect(text(.element(.init(action: .press, element: "12/0", actionName: "showMenu")))
            == #"{"action":"press","actionName":"showMenu","element":"12/0","type":"element"}"# + "\n")
        #expect(text(.permission(.init(action: .ask))) == #"{"action":"ask","type":"permission"}"# + "\n")
    }

    @Test func anAgentSaysWhereItsSystemAsksToBeAllowed() throws {
        // What the agent for macOS puts out for a permission job, as the app reads it.
        let said = Data(#"{"isAllowed":false,"scale":2,"settings":[774,202,1480,1250],"sheet":[1020,408,520,696]}"#.utf8)
        let state = try JSONDecoder().decode(GuestPermissionState.self, from: said)
        #expect(state == GuestPermissionState(isAllowed: false, scale: 2, settings: [774, 202, 1480, 1250], sheet: [1020, 408, 520, 696]))
        #expect(GuestJob.permission(.init(action: .check)).feature == GuestFeature.permission)
        // It is no kind of job that a machine's owner is told about.
        #expect(!GuestFeature.jobs.contains(GuestFeature.permission))
    }

    @Test func aJobFromALaterAppIsKnownForWhatItIs() throws {
        let later = try #require(GuestMessageCoding.message(GuestJob.self, from: Data(#"{"type":"record-screen","seconds":5}"#.utf8)))
        #expect(later == .unknown(type: "record-screen"))
        // Nothing is asked of an agent on its behalf.
        #expect(later.feature == nil)
        #expect(GuestJob.exec(.init(arguments: ["true"])).feature == GuestFeature.exec)
        #expect(GuestJob.screenshot.feature == GuestFeature.screen)
        #expect(GuestJob.keys(.init(text: "x")).feature == GuestFeature.input)
        #expect(GuestJob.tree(.init()).feature == GuestFeature.accessibility)
    }

    @Test func framesArriveAsTheyWereSent() throws {
        let (near, far) = makeLine()
        defer { close(near) }
        // What is longer than a frame may be goes in several, and nothing gets lost on the way.
        let long = Data((0..<(JobFrame.maximumPayloadLength * 2 + 100)).map { UInt8(truncatingIfNeeded: $0) })
        let sender = Thread {
            JobFrame.write(.output, long, to: far)
            JobFrame.write(.input, to: far)
            // A kind of frame from a later version is passed over.
            _ = ByteRelay.writeAll(ArraySlice([UInt8(200), 0, 0, 0, 2, 7, 7]), to: far)
            JobFrame.write(.errorOutput, Data("oops".utf8), to: far)
            JobFrame.write(.end, JobFrame.end(JobEnd(status: 3)).payload, to: far)
            close(far)
        }
        sender.start()

        var received = Data()
        var frames: [JobFrame] = []
        while let frame = try JobFrame.read(from: near, timeout: 5) {
            if frame.kind == .output {
                #expect(frame.payload.count <= JobFrame.maximumPayloadLength)
                received.append(frame.payload)
            } else {
                frames.append(frame)
            }
        }
        #expect(received == long)
        #expect(frames.map(\.kind) == [.input, .errorOutput, .end])
        #expect(frames[0].payload.isEmpty)
        #expect(frames[2].end == JobEnd(status: 3))
    }

    @Test func aLineThatBreaksInsideAFrameIsNotTakenForItsEnd() {
        let (near, far) = makeLine()
        defer { close(near) }
        // Says ten bytes are coming, and hangs up after three.
        _ = ByteRelay.writeAll(ArraySlice([JobFrame.Kind.output.rawValue, 0, 0, 0, 10, 1, 2, 3]), to: far)
        close(far)
        #expect(throws: JobFrame.Malformed.self) { try JobFrame.read(from: near) }

        // What claims to be longer than any frame isn't one.
        let (other, sender) = makeLine()
        defer {
            close(other)
            close(sender)
        }
        _ = ByteRelay.writeAll(ArraySlice([JobFrame.Kind.output.rawValue, 0x7F, 0xFF, 0xFF, 0xFF]), to: sender)
        #expect(throws: JobFrame.Malformed.self) { try JobFrame.read(from: other) }
    }

    @Test(arguments: [
        Data(), Data([1]), Data([1, 0, 0, 0, 3]), Data([1, 0, 0, 0, 3, 7]), Data([200, 0, 0, 0, 0, 1]),
    ])
    func aFrameThatStopsArrivingTimesOut(prefix: Data) {
        let (near, far) = makeLine()
        defer {
            close(near)
            close(far)
        }
        _ = ByteRelay.writeAll(ArraySlice(prefix), to: far)
        // A broken timeout must fail the test, not hold the test process for good.
        let watchdog = DispatchWorkItem { shutdown(far, SHUT_RDWR) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
        defer { watchdog.cancel() }
        #expect(throws: JobFrame.TimedOut.self) { try JobFrame.read(from: near, timeout: 0.1) }
    }

    /// What a thread that plays the agent's end hands back to the test.
    private final class Handed<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var held: Value?

        var value: Value? {
            get { lock.withLock { held } }
            set { lock.withLock { held = newValue } }
        }
    }

    @Test func aJobIsOpenedWithOneLineEachWay() throws {
        let (near, far) = makeLine()
        defer { close(near) }
        // The agent's end: reads the job, says yes, and sends a frame right behind its answer.
        let received = Handed<GuestJob>()
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            if let line = GuestJobLine.read(from: far, timeout: 5) {
                received.value = GuestMessageCoding.message(GuestJob.self, from: line)
                GuestJobLine.answer(GuestJobAnswer(ok: true), on: far)
                JobFrame.write(.output, Data("first".utf8), to: far)
            }
            close(far)
            finished.signal()
        }
        let job = GuestJob.exec(.init(arguments: ["uname", "-a"]))
        #expect(GuestJobLine.open(job, over: near, timeout: 5) == GuestJobAnswer(ok: true))
        // The answer was read up to its line break and no further: the frame is still there to read.
        #expect(try JobFrame.read(from: near) == JobFrame(.output, Data("first".utf8)))
        finished.wait()
        #expect(received.value == job)
    }

    @Test func whatAGuestSaysWentWrongIsMadeFitToShow() {
        // A guest can say anything. What reaches the terminal is one line, without what moves the cursor.
        let end = JobEnd.failure("no such file\u{1B}[2J\nrm -rf ~\u{202E}")
        #expect(end.shownError == "no such file[2Jrm -rf ~")
        #expect(JobEnd.failure(String(repeating: "x", count: 5000)).shownError?.count == 500)
        #expect(JobEnd.success.shownError == nil)
    }

    @Test func anAgentThatSaysNothingIsNotWaitedForForever() {
        let (near, far) = makeLine()
        defer {
            close(near)
            close(far)
        }
        #expect(GuestJobLine.open(.screenshot, over: near, timeout: 0.1) == nil)
    }

    @Test func hangingUpLetsTheLastWordsArrive() throws {
        // The agent has said how the job ended while the app is still sending input. What the agent
        // said has to arrive all the same.
        let (near, far) = makeLine()
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            JobFrame.write(.end, JobFrame.end(.success).payload, to: far)
            GuestJobLine.hangUp(far, patience: 5)
            finished.signal()
        }
        JobFrame.write(.input, Data(repeating: 1, count: 1000), to: near)
        #expect(try JobFrame.read(from: near)?.end == .success)
        #expect(try JobFrame.read(from: near) == nil)
        close(near)
        finished.wait()
    }

    @Test func aGuestThatDoesNotHangUpIsHungUpOn() async {
        // The tool has gone, which calls a job off. An agent that keeps its end open all the same
        // doesn't keep the app's relay with it.
        let (tool, appsEndForTool) = makeLine()
        let (appsEndForGuest, guest) = makeLine()
        defer {
            close(appsEndForTool)
            close(appsEndForGuest)
            close(guest)
        }
        close(tool)
        // If the relay didn't give up, this would wait for good. Someone who does give up lets it go.
        let watchdog = DispatchWorkItem { shutdown(guest, SHUT_RDWR) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: watchdog)
        let started = ContinuousClock.now
        await ByteRelay.run(between: appsEndForTool, and: appsEndForGuest, patienceAfterFirstEnds: 0.2)
        watchdog.cancel()
        #expect(ContinuousClock.now - started < .seconds(20))
        // The guest is told, too: nothing more comes, and nothing more is taken.
        var byte: UInt8 = 0
        #expect(read(guest, &byte, 1) == 0)
    }
}
