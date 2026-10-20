import Foundation

/// A downloadable disk image or installer.
public struct RemoteImage: Codable, Sendable, Hashable {
    public enum ChecksumAlgorithm: String, Codable, Sendable, Hashable {
        case sha256
        case sha512
    }

    /// A verified piece of an image too large for its publisher to serve as one file.
    public struct Part: Codable, Sendable, Hashable {
        public var url: URL
        public var sha256: String
        public var bytes: Int64

        public init(url: URL, sha256: String, bytes: Int64) {
            self.url = url
            self.sha256 = sha256
            self.bytes = bytes
        }
    }

    /// Selects the first published image release with a compatible manifest, in GitHub's release order.
    public struct LatestRelease: Codable, Sendable, Hashable {
        public var tagPrefix: String
        public var manifest: String

        public init(tagPrefix: String, manifest: String) {
            self.tagPrefix = tagPrefix
            self.manifest = manifest
        }
    }

    public var url: URL
    /// When present, `url` is a GitHub releases API endpoint, not an image to download. Resolution
    /// replaces it with one immutable image before checking the cache or starting a download.
    public var latestRelease: LatestRelease?
    /// A `SHA256SUMS`-style file listing the expected digest of `url`'s file name.
    public var checksumsURL: URL?
    public var checksumAlgorithm: ChecksumAlgorithm?
    /// The SHA-256 digest of the file, where its publisher lists none to check it against and the app
    /// knows the one it expects.
    public var sha256: String?
    /// Download these in order instead of `url`, which names the assembled image. Each piece and the
    /// complete image must have a SHA-256 digest; interrupted pieces resume like any other download.
    public var parts: [Part]?

    public init(
        url: URL, checksumsURL: URL? = nil, checksumAlgorithm: ChecksumAlgorithm? = nil,
        sha256: String? = nil, parts: [Part]? = nil, latestRelease: LatestRelease? = nil
    ) {
        self.url = url
        self.latestRelease = latestRelease
        self.checksumsURL = checksumsURL
        self.checksumAlgorithm = checksumAlgorithm
        self.sha256 = sha256
        self.parts = parts
    }

    public var fileName: String { url.lastPathComponent }
}

/// A Linux distribution release the app knows how to set up.
public struct LinuxDistribution: Codable, Sendable, Hashable, Identifiable {
    public struct Installer: Codable, Sendable, Hashable, Identifiable {
        public var name: String
        public var url: URL
        public var checksumsURL: URL?
        public var checksumAlgorithm: RemoteImage.ChecksumAlgorithm?
        /// The SHA-256 digest of the disc, where its publisher lists none in a form the app reads.
        public var sha256: String?

        public var id: URL { url }
        public var image: RemoteImage {
            RemoteImage(url: url, checksumsURL: checksumsURL, checksumAlgorithm: checksumAlgorithm, sha256: sha256)
        }
    }

    public var id: String
    /// Distribution family identifier, e.g. `ubuntu`.
    public var distribution: String
    /// Display name including the version, e.g. `Ubuntu 26.04 LTS`.
    public var name: String
    public var summary: String
    /// Pre-installed image configured on first boot by cloud-init (Quick Create).
    public var cloudImage: RemoteImage?
    /// Ready-made images for built-in setups, keyed by script ID. A user's script with the same name
    /// still starts from the distribution's plain image.
    public var setupImages: [String: RemoteImage]?
    /// Installer ISOs for a manual installation.
    public var installers: [Installer]

    public func preparedImage(for scripts: [SetupScript]) -> RemoteImage? {
        scripts.lazy.filter { $0.origin == .builtIn }.compactMap { setupImages?[$0.id] }.first
    }

    public func image(for scripts: [SetupScript]) -> RemoteImage? {
        preparedImage(for: scripts) ?? cloudImage
    }
}

/// The built-in list of Linux distributions.
public enum DistributionCatalog {
    private struct File: Codable {
        var distributions: [LinuxDistribution]
    }

    /// Distributions bundled with the app.
    public static let builtIn: [LinuxDistribution] = {
        guard let url = Bundle.module.url(forResource: "distributions", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else { return [] }
        return file.distributions
    }()

    /// Distributions that can be created without running an installer.
    public static var quickCreate: [LinuxDistribution] {
        builtIn.filter { $0.cloudImage != nil }
    }
}
