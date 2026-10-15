import Foundation
import Sparkle
import Testing
@testable import SwiftVM

@MainActor
@Suite(.serialized) struct UpdateTests {
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

    @Test(arguments: [false, true])
    func scheduledUpdatesWaitInThePanelEvenJustAfterLaunch(immediateFocus: Bool) throws {
        let service = UpdateService.shared
        defer { service.standardUserDriverWillFinishUpdateSession() }
        let update = try makeUpdate()
        let handlesShowing = service.standardUserDriverShouldHandleShowingScheduledUpdate(update, andInImmediateFocus: immediateFocus)

        #expect(!handlesShowing)
        service.standardUserDriverWillHandleShowingUpdate(handlesShowing, forUpdate: update, state: try makeState(userInitiated: false))
        #expect(service.waitingVersion == "0.2.0-beta.58")
    }

    /// Automatic downloads don't go through the user driver until Sparkle decides to remind the user.
    @Test func anUpdateIsAnnouncedWithoutWaitingForAScheduledReminder() throws {
        let service = UpdateService.shared
        defer { service.standardUserDriverWillFinishUpdateSession() }
        let controller = makeController()

        service.updater(controller.updater, didFindValidUpdate: try makeUpdate())

        #expect(service.waitingVersion == "0.2.0-beta.58")
    }

    @Test func aManualCheckLeavesTheUpdateInSparklesDialog() throws {
        let service = UpdateService.shared
        defer { service.standardUserDriverWillFinishUpdateSession() }
        let controller = makeController()
        let update = try makeUpdate()
        service.updater(controller.updater, didFindValidUpdate: update)
        try #require(service.waitingVersion != nil)

        service.standardUserDriverWillHandleShowingUpdate(true, forUpdate: update, state: try makeState(userInitiated: true))

        #expect(service.waitingVersion == nil)
    }

    @Test func aFailedUpdateDoesNotLeaveAnOfferInThePanel() throws {
        let service = UpdateService.shared
        defer { service.standardUserDriverWillFinishUpdateSession() }
        let controller = makeController()
        service.updater(controller.updater, didFindValidUpdate: try makeUpdate())
        try #require(service.waitingVersion != nil)

        service.updater(controller.updater, didAbortWithError: URLError(.notConnectedToInternet))

        #expect(service.waitingVersion == nil)
    }

    @Test func anUpdateThatHasBeenSeenOrDismissedDoesNotLeaveAnOfferInThePanel() throws {
        let service = UpdateService.shared
        defer { service.standardUserDriverWillFinishUpdateSession() }
        let controller = makeController()
        let update = try makeUpdate()
        service.updater(controller.updater, didFindValidUpdate: update)
        try #require(service.waitingVersion != nil)

        service.standardUserDriverDidReceiveUserAttention(forUpdate: update)
        #expect(service.waitingVersion == nil)

        service.updater(controller.updater, didFindValidUpdate: update)
        try #require(service.waitingVersion != nil)
        service.standardUserDriverWillFinishUpdateSession()
        #expect(service.waitingVersion == nil)
    }

    private func makeController() -> SPUStandardUpdaterController {
        SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    }

    /// Sparkle exposes these values through secure coding, but has no non-deprecated public initializer
    /// for making an appcast item. No feed is fetched and no update is downloaded by these tests.
    private func makeUpdate() throws -> SUAppcastItem {
        let archive = NSKeyedArchiver(requiringSecureCoding: true)
        archive.encode("58", forKey: "versionString")
        archive.encode("0.2.0-beta.58", forKey: "displayVersionString")
        archive.encode(URL(string: "https://example.com/SwiftVM.dmg")! as NSURL, forKey: "fileURL")
        archive.encode("application", forKey: "SUAppcastItemInstallationType")
        archive.encode([:] as NSDictionary, forKey: "propertiesDictionary")
        let decoder = try NSKeyedUnarchiver(forReadingFrom: archive.encodedData)
        defer { decoder.finishDecoding() }
        return try #require(SUAppcastItem(coder: decoder))
    }

    private func makeState(userInitiated: Bool) throws -> SPUUserUpdateState {
        let archive = NSKeyedArchiver(requiringSecureCoding: true)
        archive.encode(SPUUserUpdateStage.notDownloaded.rawValue, forKey: "SPUUserUpdateStateStage")
        archive.encode(userInitiated, forKey: "SPUUserUpdateStateUserInitiated")
        let decoder = try NSKeyedUnarchiver(forReadingFrom: archive.encodedData)
        defer { decoder.finishDecoding() }
        return try #require(SPUUserUpdateState(coder: decoder))
    }
}
