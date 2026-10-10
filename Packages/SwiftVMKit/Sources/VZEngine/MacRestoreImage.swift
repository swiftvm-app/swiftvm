import Foundation
import VMCore
import Virtualization

/// What a macOS restore image (an IPSW file) installs and what it needs from the machine.
public struct MacRestoreImage: Sendable, Hashable {
    /// What a machine must provide to run the macOS version in an image.
    public struct Requirements: Sendable, Hashable {
        /// Opaque description of the virtual Mac model the image is installed for.
        public var hardwareModel: Data
        public var minimumCPUCount: Int
        /// In bytes.
        public var minimumMemorySize: UInt64
    }

    public enum ImageError: Error, LocalizedError {
        case notAFile(URL)

        public var errorDescription: String? {
            switch self {
            case .notAFile(let url):
                "“\(url.lastPathComponent)” isn't a file on this Mac."
            }
        }
    }

    /// A local file, or the address Apple serves the image from.
    public var url: URL
    public var majorVersion: Int
    public var minorVersion: Int
    public var patchVersion: Int
    /// Build identifier, e.g. `26A434`.
    public var buildVersion: String
    /// `nil` when this Mac can't run the macOS version in the image.
    public var requirements: Requirements?

    public init(url: URL, majorVersion: Int, minorVersion: Int, patchVersion: Int, buildVersion: String, requirements: Requirements?) {
        self.url = url
        self.majorVersion = majorVersion
        self.minorVersion = minorVersion
        self.patchVersion = patchVersion
        self.buildVersion = buildVersion
        self.requirements = requirements
    }

    /// `27.0.1`, or `27.0` when there is no patch number.
    public var versionString: String {
        patchVersion == 0 ? "\(majorVersion).\(minorVersion)" : "\(majorVersion).\(minorVersion).\(patchVersion)"
    }

    /// `macOS 27.0.1`
    public var productName: String { "macOS \(versionString)" }

    public var guestOS: GuestOS {
        GuestOS(family: .macOS, productName: productName, build: buildVersion)
    }

    /// Whether the image still has to be downloaded before it can be installed.
    public var isRemote: Bool { !url.isFileURL }

    /// Whether the installed system creates the user account by itself on first boot.
    public var supportsProvisioning: Bool {
        majorVersion >= GuestProvisioning.minimumMacOSMajorVersion
    }

    // MARK: Loading

    /// Asks Apple for the newest macOS this Mac can run as a guest. Needs a network connection.
    public static func latestSupported() async throws -> MacRestoreImage {
        try await withCheckedThrowingContinuation { continuation in
            VZMacOSRestoreImage.fetchLatestSupported { result in
                continuation.resume(with: result.map(MacRestoreImage.init))
            }
        }
    }

    /// Reads the description of a restore image file.
    public static func load(from fileURL: URL) async throws -> MacRestoreImage {
        // The framework raises an exception rather than an error for anything that isn't a local file.
        var isDirectory: ObjCBool = false
        guard fileURL.isFileURL, FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw ImageError.notAFile(fileURL)
        }
        return try await withCheckedThrowingContinuation { continuation in
            VZMacOSRestoreImage.load(from: fileURL) { result in
                continuation.resume(with: result.map(MacRestoreImage.init))
            }
        }
    }

    private init(_ image: VZMacOSRestoreImage) {
        let version = image.operatingSystemVersion
        var requirements: Requirements?
        if image.isSupported, let configuration = image.mostFeaturefulSupportedConfiguration, configuration.hardwareModel.isSupported {
            requirements = Requirements(
                hardwareModel: configuration.hardwareModel.dataRepresentation,
                minimumCPUCount: configuration.minimumSupportedCPUCount,
                minimumMemorySize: configuration.minimumSupportedMemorySize
            )
        }
        self.init(
            url: image.url,
            majorVersion: version.majorVersion,
            minorVersion: version.minorVersion,
            patchVersion: version.patchVersion,
            buildVersion: image.buildVersion,
            requirements: requirements
        )
    }
}
