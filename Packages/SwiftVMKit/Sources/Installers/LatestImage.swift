import CryptoKit
import Foundation

extension ImageDownloader {
    /// Resolves a rolling catalog entry once. The returned image has immutable URLs and checksums;
    /// an update published while it downloads cannot change its pieces halfway through.
    public func resolve(_ source: RemoteImage) async throws -> RemoteImage {
        guard let latest = source.latestRelease else { return source }
        let components = source.url.pathComponents
        guard source.url.scheme == "https", source.url.host == "api.github.com",
              components.count == 5, components[1] == "repos", components[4] == "releases",
              source.url.query == nil, source.url.fragment == nil,
              Self.isReleaseName(latest.tagPrefix), Self.isReleaseName(latest.manifest)
        else { throw DownloadError.invalidManifest }
        let releases = URL(string: "https://github.com/\(components[2])/\(components[3])/releases/download/")!
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let key = SHA256.hash(data: try encoder.encode(source)).map { String(format: "%02x", $0) }.joined()
        let cache = cacheDirectory.appending(path: "Manifests/\(key).json")
        do {
            let saved = try await latestImage(source, releases: releases)
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(saved).write(to: cache, options: .atomic)
            return saved.image
        } catch {
            try Task.checkCancellation()
            // Being offline must not make a downloaded image unusable. A malformed or incompatible
            // new manifest is different: report it rather than silently installing an older image.
            guard Self.canUseCachedManifest(after: error),
                  let data = try? Data(contentsOf: cache),
                  let saved = try? JSONDecoder().decode(SavedImage.self, from: data),
                  (try? Self.validate(saved, source: source, releases: releases)) != nil,
                  isCached(saved.image)
            else { throw error }
            return saved.image
        }
    }

    private struct Release: Decodable {
        struct Asset: Decodable {
            var name: String
            var browser_download_url: URL
            var size: Int
            var digest: String?
            var state: String
        }
        var tag_name: String
        var draft: Bool
        var published_at: String?
        var assets: [Asset]
    }

    private struct Manifest: Decodable {
        var format: Int
        var image: RemoteImage
    }

    private struct SavedImage: Codable {
        var tag: String
        var image: RemoteImage
    }

    private func latestImage(_ source: RemoteImage, releases: URL) async throws -> SavedImage {
        let latest = source.latestRelease!
        // App releases may occupy several pages between monthly image refreshes. Bound the search
        // and each response instead of trusting a server to paginate or size its replies sensibly.
        for page in 1...20 {
            var url = URLComponents(url: source.url, resolvingAgainstBaseURL: false)!
            url.queryItems = [.init(name: "per_page", value: "100"), .init(name: "page", value: String(page))]
            let data = try await metadata(at: url.url!, limit: 4 << 20)
            guard let candidates = try? JSONDecoder().decode([Release].self, from: data) else {
                throw DownloadError.invalidManifest
            }
            for release in candidates where !release.draft && release.published_at != nil
                && release.tag_name.hasPrefix(latest.tagPrefix) {
                guard let asset = release.assets.first(where: { $0.name == latest.manifest && $0.state == "uploaded" }) else {
                    continue
                }
                guard Self.isReleaseName(release.tag_name), asset.size > 0, asset.size <= 64 << 10,
                      asset.browser_download_url == releases.appending(path: release.tag_name).appending(path: latest.manifest),
                      let digest = asset.digest, digest.hasPrefix("sha256:"), Self.isSHA256(String(digest.dropFirst(7)))
                else { throw DownloadError.invalidManifest }
                let data = try await metadata(at: asset.browser_download_url, limit: 64 << 10)
                let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard data.count == asset.size, "sha256:\(actual)" == digest,
                      let manifest = try? JSONDecoder().decode(Manifest.self, from: data), manifest.format == 1
                else { throw DownloadError.invalidManifest }
                let saved = SavedImage(tag: release.tag_name, image: manifest.image)
                try Self.validate(saved, source: source, releases: releases)
                return saved
            }
            if candidates.count < 100 { break }
        }
        throw DownloadError.noCompatibleImage
    }

    private func metadata(at url: URL, limit: Int) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        if url.host == "api.github.com" {
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        }
        let (bytes, response) = try await metadataSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw DownloadError.invalidManifest }
        guard http.statusCode == 200 else { throw DownloadError.badResponse(http.statusCode) }
        guard response.expectedContentLength <= limit else { throw DownloadError.invalidManifest }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw DownloadError.invalidManifest }
            data.append(byte)
        }
        return data
    }

    private static func validate(_ saved: SavedImage, source: RemoteImage, releases: URL) throws {
        let image = saved.image
        guard isReleaseName(saved.tag), saved.tag.hasPrefix(source.latestRelease!.tagPrefix),
              image.latestRelease == nil, image.checksumsURL == nil, image.checksumAlgorithm == nil,
              let digest = image.sha256, isSHA256(digest),
              isReleaseName(image.fileName), image.fileName.hasSuffix("-\(digest.prefix(12)).qcow2"),
              saved.tag.hasSuffix("-\(digest.prefix(12))"),
              image.url == releases.appending(path: saved.tag).appending(path: image.fileName),
              let parts = image.parts, parts.count <= 128, totalSize(of: parts) != nil
        else { throw DownloadError.invalidManifest }
        for (index, part) in parts.enumerated() {
            let name = image.fileName + String(format: ".%03d", index)
            guard isSHA256(part.sha256), part.bytes <= 1 << 30,
                  part.url == image.url.deletingLastPathComponent().appending(path: name)
            else { throw DownloadError.invalidManifest }
        }
    }

    private static func isReleaseName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func canUseCachedManifest(after error: any Error) -> Bool {
        if let error = error as? URLError {
            switch error.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                 .networkConnectionLost, .notConnectedToInternet, .internationalRoamingOff, .callIsActive, .dataNotAllowed:
                return true
            default:
                return false
            }
        }
        if case DownloadError.badResponse(let status) = error { return status == 403 || status == 429 || (500..<600).contains(status) }
        return false
    }
}
