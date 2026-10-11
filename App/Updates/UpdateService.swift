import AppKit
import Combine
import Sparkle
import VMCore

/// Which updates a copy of the app is offered.
enum UpdateChannel {
    /// The channels a copy with the version `version` follows, beyond the releases themselves. A beta
    /// (`0.2.0-beta.57`) goes on to the betas that come after it; a release only ever goes to a release.
    static func channels(forVersion version: String) -> Set<String> {
        version.contains("-beta.") ? ["beta"] : []
    }
}

/// Updates of the app itself, through Sparkle.
///
/// Only a released copy updates: one whose `Info.plist` says where its updates are listed and which key
/// they are signed with, which `scripts/build-release.sh` writes there. The development copy and an app
/// built by hand say neither, and for them nothing here does anything.
@Observable
final class UpdateService: NSObject {
    static let shared = UpdateService()

    /// Whether this copy of the app updates itself.
    let isAvailable: Bool
    /// What the copy calls its version: `0.2.0`, or `0.2.0-beta.57`.
    let version: String

    private(set) var canCheckForUpdates = false
    private(set) var automaticallyDownloadsUpdates = false
    /// The version of an update that was found while nobody was looking at the app, and that is waiting
    /// to be shown. The menu bar panel says so; an app without a Dock icon has no other place to.
    private(set) var waitingVersion: String?

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations = Set<AnyCancellable>()

    override private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        version = info["CFBundleShortVersionString"] as? String ?? ""
        isAvailable = Self.updates(from: info)
        super.init()
    }

    /// Whether an app with this `Info.plist` knows where to find updates and how to check them.
    static func updates(from info: [String: Any]) -> Bool {
        let feed = info["SUFeedURL"] as? String ?? ""
        let key = info["SUPublicEDKey"] as? String ?? ""
        return !feed.isEmpty && !key.isEmpty
    }

    /// Starts looking for updates, now and every so often. Call once, when the app has launched.
    func start() {
        guard isAvailable, controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &observations)
        updater.publisher(for: \.automaticallyDownloadsUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.automaticallyDownloadsUpdates = $0 }
            .store(in: &observations)
        do {
            try updater.start()
        } catch {
            AppModel.shared.generalError = VMErrorInfo(title: "Updates aren't available", message: error.localizedDescription)
        }
    }

    /// Looks for an update because someone asked, and shows what comes of it. Also the way to an update
    /// that is waiting: Sparkle shows that one.
    func checkForUpdates() {
        guard let controller else { return }
        // Sparkle's windows are windows of the app like any other, and the app isn't in front by itself.
        DockPresence.shared.windowWillOpen()
        AppModel.shared.windows.bringAppForward()
        controller.checkForUpdates(nil)
    }

    func setAutomaticallyDownloadsUpdates(_ isOn: Bool) {
        controller?.updater.automaticallyDownloadsUpdates = isOn
    }
}

extension UpdateService: SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UpdateChannel.channels(forVersion: version)
    }
}

/// An update that is found while the app is in the background isn't put on the screen: the app has no
/// Dock icon to bounce, and a window that comes up over what someone is doing in another app, or behind
/// it where nobody looks, helps nobody. The panel says that there is one, and shows it when asked.
extension UpdateService: SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        // In the first moment after a launch, with the app in front, Sparkle shows it as it is.
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        waitingVersion = update.displayVersionString
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        waitingVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        waitingVersion = nil
    }
}
