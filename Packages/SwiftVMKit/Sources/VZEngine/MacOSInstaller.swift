import Foundation
import VMCore
import Virtualization

/// Turns an empty machine bundle into an installed Mac.
@MainActor
public enum MacOSInstaller {
    public enum InstallError: Error, LocalizedError {
        case unsupportedImage(String)
        case imageNotDownloaded

        public var errorDescription: String? {
            switch self {
            case .unsupportedImage(let productName):
                "This Mac can't run \(productName) in a virtual machine."
            case .imageNotDownloaded:
                "The restore image has to be downloaded before it can be installed."
            }
        }
    }

    /// Writes the files that make the bundle a particular Mac: its hardware model, its identifier and the
    /// auxiliary storage the boot loader uses.
    public nonisolated static func prepare(_ bundle: VMBundle, for requirements: MacRestoreImage.Requirements) throws {
        guard let hardwareModel = VZMacHardwareModel(dataRepresentation: requirements.hardwareModel), hardwareModel.isSupported else {
            throw VZConfigurationBuilder.BuildError.unsupportedHardwareModel
        }
        try requirements.hardwareModel.write(to: bundle.hardwareModelURL, options: .atomic)
        try VZMacMachineIdentifier().dataRepresentation.write(to: bundle.machineIdentifierURL, options: .atomic)
        _ = try VZMacAuxiliaryStorage(creatingStorageAt: bundle.auxiliaryStorageURL, hardwareModel: hardwareModel, options: [.allowOverwrite])
    }

    /// Installs macOS from `image` onto the machine's disk. Takes several minutes.
    ///
    /// The bundle must have been prepared with ``prepare(_:for:)`` and hold the (empty) disks named in
    /// `configuration`. Cancelling the task stops the installation; the bundle is unusable afterwards.
    ///
    /// - Parameter progress: Called with the completed fraction, from 0 to 1.
    public static func install(
        _ image: MacRestoreImage,
        into bundle: VMBundle,
        configuration: VMConfiguration,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws {
        guard image.requirements != nil else { throw InstallError.unsupportedImage(image.productName) }
        guard !image.isRemote else { throw InstallError.imageNotDownloaded }

        // The installer needs no network, so the machine is built without attachments.
        let vzConfiguration = try VZConfigurationBuilder(bundle: bundle, configuration: configuration).build()
        let virtualMachine = VZVirtualMachine(configuration: vzConfiguration)
        let installer = VZMacOSInstaller(virtualMachine: virtualMachine, restoringFromImageAt: image.url)

        let observation = installer.progress.observe(\.fractionCompleted, options: [.initial, .new]) { installProgress, _ in
            let fraction = installProgress.fractionCompleted
            Task { @MainActor in progress(fraction) }
        }
        defer { observation.invalidate() }

        let cancellation = InstallCancellation(progress: installer.progress)
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    let didStart = cancellation.begin {
                        installer.install { continuation.resume(with: $0) }
                    }
                    if !didStart {
                        continuation.resume(throwing: CancellationError())
                    }
                }
            } onCancel: {
                cancellation.cancel()
            }
        } catch {
            // The framework reports a cancelled installation as its own kind of failure; callers expect
            // the same error as for any other cancelled step.
            try Task.checkCancellation()
            throw error
        }
        // A cancelled installation can still report success if it was about to finish.
        try Task.checkCancellation()
    }
}

extension GuestProvisioning {
    var macOptions: VZMacGuestProvisioningOptions {
        let options = VZMacGuestProvisioningOptions()
        options.fullName = fullName
        options.username = userName
        options.password = password
        options.logsInAutomatically = logsInAutomatically
        options.enablesRemoteLogin = enablesRemoteLogin
        return options
    }

    /// Throws if macOS wouldn't accept this account. Check before installing: the account is only handed
    /// over on the first start, when it is too late to change it.
    public func validateForMacOS() throws {
        try macOptions.validate()
    }
}

/// Cancels a running installation. The installer's progress object raises an exception when it is cancelled
/// before the installation has started, so a cancellation that arrives early is only remembered.
private final class InstallCancellation: @unchecked Sendable {
    private let progress: Progress
    private let lock = NSLock()
    private var hasBegun = false
    private var isCancelled = false

    init(progress: Progress) {
        self.progress = progress
    }

    /// Runs `start` unless the installation was cancelled before it could start, and says whether it ran.
    /// A cancellation arriving at the same moment waits until `start` has returned.
    func begin(_ start: () -> Void) -> Bool {
        lock.withLock {
            guard !isCancelled else { return false }
            start()
            hasBegun = true
            return true
        }
    }

    func cancel() {
        let shouldCancelProgress = lock.withLock {
            isCancelled = true
            return hasBegun
        }
        if shouldCancelProgress {
            progress.cancel()
        }
    }
}
