import Foundation
import Testing
@testable import GuestChannel

@Suite struct GuestProtocolTests {
    private func text(_ message: HostMessage) -> String {
        String(decoding: GuestMessageCoding.line(for: message), as: UTF8.self)
    }

    private func decode(_ json: String) -> AgentMessage? {
        GuestMessageCoding.message(AgentMessage.self, from: Data(json.utf8))
    }

    @Test func theAppsMessagesAreOneJSONObjectPerLine() {
        // These are what the agent in a guest parses; changing one changes the protocol.
        #expect(text(.hello(protocol: 1)) == #"{"protocol":1,"type":"hello"}"# + "\n")
        #expect(text(.setClock(id: 7, nanoseconds: 1_790_000_000_123_456_789))
            == #"{"id":7,"nanoseconds":1790000000123456789,"type":"set-clock"}"# + "\n")
        #expect(text(.mountSharedFolders(id: 8, tag: "swiftvm", mountPoint: "/mnt/shared"))
            == #"{"id":8,"mountPoint":"/mnt/shared","tag":"swiftvm","type":"mount-shared-folders"}"# + "\n")
        #expect(text(.shutDown(id: 9)) == #"{"id":9,"type":"shut-down"}"# + "\n")
        #expect(text(.setTimeZone(id: 10, identifier: "Europe/Berlin"))
            == #"{"id":10,"identifier":"Europe/Berlin","type":"set-time-zone"}"# + "\n")
        #expect(text(.clipboard(text: "two\nlines")) == #"{"text":"two\nlines","type":"clipboard"}"# + "\n")
    }

    @Test func onlyRequestsCarryAnID() {
        #expect(HostMessage.setClock(id: 1, nanoseconds: 2).requestID == 1)
        #expect(HostMessage.mountSharedFolders(id: 2, tag: "swiftvm", mountPoint: "/mnt/shared").requestID == 2)
        #expect(HostMessage.shutDown(id: 3).requestID == 3)
        #expect(HostMessage.setTimeZone(id: 4, identifier: "UTC").requestID == 4)
        #expect(HostMessage.hello(protocol: 1).requestID == nil)
        #expect(HostMessage.clipboard(text: "x").requestID == nil)
        #expect(HostMessage.unknown(type: "later").requestID == nil)
    }

    @Test func readsWhatAnAgentSends() {
        let hello = decode(#"{"type":"hello","protocol":1,"agent":"1.0","system":{"id":"ubuntu","name":"Ubuntu","version":"26.04","prettyName":"Ubuntu 26.04.1 LTS","kernel":"7.0.0-34-generic","architecture":"aarch64"},"hostName":"web"}"#)
        #expect(hello == .hello(AgentHello(
            protocol: 1, agent: "1.0",
            system: GuestSystem(
                id: "ubuntu", name: "Ubuntu", version: "26.04", prettyName: "Ubuntu 26.04.1 LTS",
                kernel: "7.0.0-34-generic", architecture: "aarch64"
            ),
            hostName: "web"
        )))

        let addresses = decode(#"{"type":"addresses","interfaces":[{"name":"enp0s1","mac":"02:1a:2b:3c:4d:5e","addresses":["192.168.232.11","fd00::1"]}]}"#)
        #expect(addresses == .addresses([
            GuestInterface(name: "enp0s1", mac: "02:1a:2b:3c:4d:5e", addresses: ["192.168.232.11", "fd00::1"]),
        ]))

        #expect(decode(#"{"type":"result","id":3,"ok":true}"#) == .result(GuestRequestResult(id: 3, ok: true)))
        #expect(decode(#"{"type":"result","id":4,"ok":false,"error":"mount: unknown filesystem type"}"#)
            == .result(GuestRequestResult(id: 4, ok: false, error: "mount: unknown filesystem type")))

        #expect(decode(#"{"type":"clipboard","text":"copied in the guest"}"#) == .clipboard(text: "copied in the guest"))
        #expect(decode(#"{"type":"clipboard-request"}"#) == .clipboardRequest)
        #expect(String(decoding: GuestMessageCoding.line(for: AgentMessage.clipboardRequest), as: UTF8.self) == #"{"type":"clipboard-request"}"# + "\n")
    }

    @Test func anAgentSaysWhatElseItCanDo() {
        let hello = decode(#"{"type":"hello","protocol":1,"agent":"1.0","system":{"id":"macos","name":"macOS","version":"27.0.1","prettyName":"macOS 27.0.1","build":"26A434","kernel":"27.0.0","architecture":"arm64"},"features":["clipboard","time-zone","something-later"]}"#)
        guard case .hello(let said) = hello else {
            Issue.record("not a hello")
            return
        }
        #expect(said.system.build == "26A434")
        #expect(said.system.displayName == "macOS 27.0.1")
        #expect(said.offers(GuestFeature.clipboard))
        #expect(said.offers(GuestFeature.timeZone))
        #expect(!said.offers("drag-and-drop"))
        // What this build doesn't know is kept, for whoever passes the hello on.
        #expect(said.features == ["clipboard", "time-zone", "something-later"])

        // An agent that says nothing about it offers nothing more, and its hello reads as it always did.
        let plain = AgentHello(agent: "1.0", system: GuestSystem(id: "ubuntu"))
        #expect(!plain.offers(GuestFeature.clipboard))
        let line = String(decoding: GuestMessageCoding.line(for: AgentMessage.hello(plain)), as: UTF8.self)
        #expect(line == #"{"agent":"1.0","protocol":1,"system":{"id":"ubuntu"},"type":"hello"}"# + "\n")
    }

    @Test func copiedTextThatIsTooLongForAMessageIsNotOne() throws {
        let fits = String(repeating: "a", count: 200_000)
        let line = try #require(GuestMessageCoding.clipboardLine(fits, as: HostMessage.clipboard(text:)))
        #expect(GuestMessageCoding.message(HostMessage.self, from: line.dropLast()) == .clipboard(text: fits))
        var framer = GuestMessageFramer()
        #expect(try framer.receive(line).count == 1)

        #expect(GuestMessageCoding.clipboardLine(String(repeating: "a", count: GuestProtocol.maximumLineLength), as: HostMessage.clipboard(text:)) == nil)
        // Line breaks take two bytes each when they are written down: short enough as text, too long as a line.
        let breaks = String(repeating: "\n", count: GuestProtocol.maximumLineLength / 2)
        #expect(GuestMessageCoding.clipboardLine(breaks, as: AgentMessage.clipboard(text:)) == nil)
        #expect(GuestMessageCoding.clipboardLine("", as: AgentMessage.clipboard(text:)) != nil)
    }

    @Test func aNewerAgentIsStillUnderstood() {
        // Kinds of message and fields that came later are passed over, not held against the agent.
        #expect(decode(#"{"type":"screen","width":1920}"#) == .unknown(type: "screen"))
        #expect(decode(#"{"type":"hello","protocol":3,"agent":"2.4","uptime":12,"system":{"name":"Fedora Linux","variant":"Server"}}"#)
            == .hello(AgentHello(protocol: 3, agent: "2.4", system: GuestSystem(name: "Fedora Linux"))))
        // A hello that says nothing about the system is one all the same.
        #expect(decode(#"{"type":"hello","protocol":1,"agent":"1.0"}"#) == .hello(AgentHello(agent: "1.0")))
    }

    @Test func whatIsNotAMessageIsNotRead() {
        #expect(decode("") == nil)
        #expect(decode("SSH-2.0-OpenSSH_10.2") == nil)
        #expect(decode(#"["type","hello"]"#) == nil)
        #expect(decode(#"{"protocol":1}"#) == nil)
        // A hello has to say which protocol it speaks.
        #expect(decode(#"{"type":"hello","agent":"1.0"}"#) == nil)
        #expect(decode(#"{"type":"result","ok":true}"#) == nil)
    }

    @Test func messagesSurviveARoundTrip() throws {
        let fromTheApp: [HostMessage] = [
            .hello(protocol: 1), .setClock(id: 1, nanoseconds: .max), .mountSharedFolders(id: 2, tag: "swiftvm", mountPoint: "/mnt/a b"),
            .shutDown(id: 3), .setTimeZone(id: 4, identifier: "America/Argentina/Buenos_Aires"),
            .clipboard(text: "Über “quotes”\n\ttab \u{1F642} \\ / \u{0}"), .unknown(type: "later"),
        ]
        for message in fromTheApp {
            #expect(GuestMessageCoding.message(HostMessage.self, from: GuestMessageCoding.line(for: message).dropLast()) == message)
        }
        let fromTheAgent: [AgentMessage] = [
            .hello(AgentHello(agent: "1.0", system: GuestSystem(id: "debian", prettyName: "Debian GNU/Linux 13 (trixie)"), hostName: "db")),
            .addresses([]), .addresses([GuestInterface(name: "eth0", mac: "02:00:00:00:00:01", addresses: ["10.0.0.2"])]),
            .hello(AgentHello(agent: "1.0", system: GuestSystem(id: "macos", build: "26A434"), features: [GuestFeature.clipboard])),
            .result(GuestRequestResult(id: 5, ok: false, error: "Line one\nline “two”")),
            .clipboard(text: "one\r\ntwo\u{2028}three"), .clipboardRequest, .unknown(type: "later"),
        ]
        for message in fromTheAgent {
            let line = GuestMessageCoding.line(for: message)
            // Whatever is in a message, it stays on one line.
            #expect(line.filter { $0 == UInt8(ascii: "\n") }.count == 1)
            #expect(GuestMessageCoding.message(AgentMessage.self, from: line.dropLast()) == message)
        }
    }

    @Test func aSystemIsShownByItsOwnName() {
        #expect(GuestSystem(name: "Ubuntu", version: "26.04", prettyName: "Ubuntu 26.04.1 LTS").displayName == "Ubuntu 26.04.1 LTS")
        #expect(GuestSystem(name: "Ubuntu", version: "26.04").displayName == "Ubuntu 26.04")
        #expect(GuestSystem(name: "Arch Linux", version: "").displayName == "Arch Linux")
        #expect(GuestSystem(prettyName: "", kernel: "6.12").displayName == nil)
    }

    @Test func theClockIsReadInNanoseconds() {
        let now = GuestProtocol.currentTimeInNanoseconds()
        #expect(abs(Double(now) / 1e9 - Date().timeIntervalSince1970) < 1)
    }
}

@Suite struct GuestMessageFramerTests {
    @Test func cutsBytesIntoLinesHoweverTheyArrive() throws {
        var framer = GuestMessageFramer()
        #expect(try framer.receive(Data(#"{"type":"he"#.utf8)) == [])
        #expect(try framer.receive(Data("llo\"}\n{\"type\":\"a\"}\n\n{\"ty".utf8)) == [Data(#"{"type":"hello"}"#.utf8), Data(#"{"type":"a"}"#.utf8)])
        #expect(try framer.receive(Data()) == [])
        #expect(try framer.receive(Data("pe\":\"b\"}\n".utf8)) == [Data(#"{"type":"b"}"#.utf8)])
        #expect(try framer.receive(Data("\n\n".utf8)) == [])
    }

    @Test func givesUpOnALineThatNeverEnds() throws {
        var framer = GuestMessageFramer()
        let chunk = Data(repeating: UInt8(ascii: "x"), count: GuestProtocol.maximumLineLength / 2)
        #expect(try framer.receive(chunk) == [])
        #expect(throws: GuestMessageFramer.LineTooLong.self) { try framer.receive(chunk) }

        // Arriving in one piece with its line break doesn't make an oversized line any more welcome.
        var other = GuestMessageFramer()
        var line = Data(repeating: UInt8(ascii: "x"), count: GuestProtocol.maximumLineLength)
        line.append(UInt8(ascii: "\n"))
        #expect(throws: GuestMessageFramer.LineTooLong.self) { try other.receive(line) }
    }

    @Test func aLongLineWithinTheLimitComesThrough() throws {
        var framer = GuestMessageFramer()
        var line = Data(repeating: UInt8(ascii: "x"), count: GuestProtocol.maximumLineLength - 1)
        line.append(UInt8(ascii: "\n"))
        #expect(try framer.receive(line).map(\.count) == [GuestProtocol.maximumLineLength - 1])
    }
}
