import Foundation
import Testing
@testable import GuestChannel

@Suite struct ChannelFrameTests {
    @Test func cutsBytesIntoFramesWhereverTheyAreSplit() {
        let frames = [ChannelFrame.hello, .open(7, port: 718), ChannelFrame(.data, connection: 7, payload: Data("hello".utf8)), ChannelFrame(.end, connection: 7)]
        let bytes = frames.reduce(Data()) { $0 + $1.encoded }
        var reader = ChannelFrame.Reader()
        var read: [ChannelFrame] = []
        for byte in bytes {
            read += reader.receive(Data([byte]))
        }
        #expect(read == frames)
        #expect(read[1].port == 718)
    }

    @Test func findsItsWayBackAtTheNextHello() {
        var reader = ChannelFrame.Reader()
        // What an agent that stopped half way through a frame left unsaid, and then a new agent.
        let garbage = Data([9, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        let fresh = ChannelFrame.hello.encoded + ChannelFrame(.data, connection: 1, payload: Data("x".utf8)).encoded
        let frames = reader.receive(garbage + fresh)
        #expect(frames == [.hello, ChannelFrame(.data, connection: 1, payload: Data("x".utf8))])
        #expect(!reader.isLost)
    }

    @Test func aNewAgentIsHeardAfterTheLastStoppedInTheMiddleOfAFrame() {
        var reader = ChannelFrame.Reader()
        // A frame whose header came through, and which says more is on its way than ever comes.
        let cutShort = ChannelFrame(.data, connection: 3, payload: Data(count: 100)).encoded.prefix(20)
        #expect(reader.receive(cutShort).isEmpty)
        // Its agent leaves, and the next one starts with a hello.
        reader.reset()
        #expect(reader.receive(ChannelFrame.hello.encoded) == [.hello])
    }
}
