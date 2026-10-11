import Testing
@testable import SwiftVM

@MainActor
@Suite struct UpdateTests {
    @Test func aBetaGoesOnToBetasAndAReleaseDoesNot() {
        #expect(UpdateChannel.channels(forVersion: "0.2.0-beta.57") == ["beta"])
        #expect(UpdateChannel.channels(forVersion: "0.2.0").isEmpty)
        #expect(UpdateChannel.channels(forVersion: "").isEmpty)
    }

    /// A copy that was built by hand, or the development copy, has neither and must not go looking.
    @Test func onlyAnAppThatKnowsItsFeedAndItsKeyUpdates() {
        #expect(UpdateService.updates(from: ["SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": "key"]))
        #expect(!UpdateService.updates(from: ["SUFeedURL": "https://example.com/appcast.xml"]))
        #expect(!UpdateService.updates(from: ["SUPublicEDKey": "key"]))
        #expect(!UpdateService.updates(from: ["SUFeedURL": "", "SUPublicEDKey": ""]))
        #expect(!UpdateService.updates(from: ["SUEnableAutomaticChecks": true]))
    }
}
