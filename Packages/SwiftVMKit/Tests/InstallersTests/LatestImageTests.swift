import CryptoKit
import Foundation
import Testing
@testable import Installers

@Suite(.timeLimit(.minutes(1))) struct LatestImageTests {
    @Test func skipsAppDraftAndIncompatibleReleasesAcrossPagesAndAdoptsARefresh() async throws {
        let fixture = try ImageFeedFixture()
        defer { fixture.close() }
        let old = fixture.image("old")
        let new = fixture.image("new")
        let oldRelease = try fixture.release(old)
        var draft = try fixture.release(new)
        draft["draft"] = true
        var incompatible = try fixture.release(new)
        incompatible["assets"] = []
        var app = oldRelease
        app["tag_name"] = "v9.0.0"
        let page = [draft, incompatible] + Array(repeating: app, count: 98)
        fixture.respond(fixture.page(1), json: page)
        fixture.respond(fixture.page(2), json: [oldRelease])

        let resolved = try await fixture.downloader.resolve(fixture.source)
        #expect(resolved == old)
        // A new release must win even when the previous image has already been downloaded.
        try Data("old".utf8).write(to: fixture.downloader.cachedURL(for: old))
        fixture.respond(fixture.page(1), json: [try fixture.release(new), oldRelease])
        let refreshed = try await fixture.downloader.resolve(fixture.source)
        #expect(refreshed == new)
        #expect(!fixture.downloader.isCached(refreshed))
        // An already-resolved creation is pinned; fetch must not ask the feed again.
        fixture.respond(fixture.page(1), status: 503)
        #expect(try await fixture.downloader.fetch(resolved) { _ in } == fixture.downloader.cachedURL(for: old))
        try Data("new".utf8).write(to: fixture.downloader.cachedURL(for: new))
        fixture.respond(fixture.page(1), json: [try fixture.release(new)])
        #expect(try await fixture.downloader.fetch(fixture.source) { _ in } == fixture.downloader.cachedURL(for: new))
    }

    @Test func offlineFallbackRequiresACompletedImageAndSurvivesRestart() async throws {
        let fixture = try ImageFeedFixture()
        defer { fixture.close() }
        let image = fixture.image("downloaded")
        fixture.respond(fixture.page(1), json: [try fixture.release(image)])
        _ = try await fixture.downloader.resolve(fixture.source)
        fixture.fail(fixture.page(1), code: .notConnectedToInternet)
        await #expect(throws: URLError.self) { try await fixture.downloader.resolve(fixture.source) }
        try Data("downloaded".utf8).write(to: fixture.downloader.cachedURL(for: image))
        var restarted = ImageDownloader(cacheDirectory: fixture.cache)
        restarted.metadataSession = fixture.session
        #expect(try await restarted.resolve(fixture.source) == image)
        fixture.respond(fixture.page(1), status: 429)
        #expect(try await restarted.resolve(fixture.source) == image)
        fixture.fail(fixture.page(1), code: .cancelled)
        await #expect(throws: URLError.self) { try await restarted.resolve(fixture.source) }
        for code in [URLError.Code.cannotDecodeRawData, .cannotDecodeContentData, .cannotParseResponse] {
            fixture.fail(fixture.page(1), code: code)
            await #expect(throws: URLError.self) { try await restarted.resolve(fixture.source) }
        }
        fixture.respond(fixture.page(1), data: Data("not JSON".utf8))
        await #expect(throws: ImageDownloader.DownloadError.self) { try await restarted.resolve(fixture.source) }
    }

    @Test(arguments: ["format", "recursive", "missingChecksum", "partChecksum", "foreignPart", "http", "size", "empty", "name", "digest", "oversized"])
    func rejectsUntrustedOrIncompatibleMetadata(problem: String) async throws {
        let fixture = try ImageFeedFixture()
        defer { fixture.close() }
        var image = fixture.image("payload")
        let good = try fixture.release(image)
        fixture.respond(fixture.page(1), json: [good])
        _ = try await fixture.downloader.resolve(fixture.source)
        try Data("payload".utf8).write(to: fixture.downloader.cachedURL(for: image))
        var format = 1
        switch problem {
        case "format": format = 2
        case "recursive": image.latestRelease = fixture.source.latestRelease
        case "missingChecksum": image.sha256 = nil
        case "partChecksum": image.parts![0].sha256 = "unverified"
        case "foreignPart": image.parts![0].url = URL(string: "https://example.org/foreign.qcow2.000")!
        case "http": image.parts![0].url = URL(string: image.parts![0].url.absoluteString.replacingOccurrences(of: "https:", with: "http:"))!
        case "size": image.parts![0].bytes = Int64.max
        case "empty": image.parts = []
        case "name": image.url.deleteLastPathComponent(); image.url.append(path: "current.qcow2")
        default: break
        }
        let tag = fixture.tag(fixture.image("payload"))
        var release = try fixture.release(image, tag: tag, format: format)
        if problem == "digest" {
            var assets = release["assets"] as! [[String: Any]]
            assets[0]["digest"] = "sha256:" + String(repeating: "0", count: 64)
            release["assets"] = assets
        }
        if problem == "oversized" {
            // The declared size is small: the streaming bound must also stop an oversized body.
            fixture.respond(fixture.manifestURL(tag), data: Data(repeating: 32, count: 70 << 10))
        }
        fixture.respond(fixture.page(1), json: [release])
        await #expect(throws: ImageDownloader.DownloadError.self) { try await fixture.downloader.resolve(fixture.source) }
    }

    @Test func doesNotTreatAnAppReleaseAsAnImageWhenNoCompatibleImageExists() async throws {
        let fixture = try ImageFeedFixture()
        defer { fixture.close() }
        var app = try fixture.release(fixture.image("app"))
        app["tag_name"] = "v1.0.0"
        fixture.respond(fixture.page(1), json: [app])
        await #expect(throws: ImageDownloader.DownloadError.self) { try await fixture.downloader.resolve(fixture.source) }
        #expect(!fixture.downloader.isCached(fixture.source))
    }
}

private final class ImageFeedFixture {
    let cache = FileManager.default.temporaryDirectory.appending(path: "swiftvm-feed-\(UUID().uuidString)")
    let repository = "swiftvm-tests/\(UUID().uuidString)"
    let manifest = "omarchy-arm64-edge-v1.json"
    let session: URLSession
    var downloader: ImageDownloader

    var source: RemoteImage {
        RemoteImage(url: URL(string: "https://api.github.com/repos/\(repository)/releases")!,
                    latestRelease: .init(tagPrefix: "omarchy-image-", manifest: manifest))
    }

    init() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageFeedProtocol.self]
        session = URLSession(configuration: configuration)
        downloader = ImageDownloader(cacheDirectory: cache)
        downloader.metadataSession = session
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    }

    func close() {
        session.invalidateAndCancel()
        ImageFeedProtocol.replies.remove(repository: repository)
        try? FileManager.default.removeItem(at: cache)
    }

    func page(_ number: Int) -> URL { URL(string: source.url.absoluteString + "?per_page=100&page=\(number)")! }
    func tag(_ image: RemoteImage) -> String { "omarchy-image-2026.10.19-\(image.sha256!.prefix(12))" }
    func manifestURL(_ tag: String) -> URL {
        URL(string: "https://github.com/\(repository)/releases/download/\(tag)/\(manifest)")!
    }

    func image(_ text: String) -> RemoteImage {
        let data = Data(text.utf8)
        let digest = Self.digest(data)
        let name = "omarchy-edge-\(digest.prefix(12)).qcow2"
        let url = URL(string: "https://github.com/\(repository)/releases/download/omarchy-image-2026.10.19-\(digest.prefix(12))/\(name)")!
        return RemoteImage(url: url, sha256: digest, parts: [
            .init(url: URL(string: url.absoluteString + ".000")!, sha256: digest, bytes: Int64(data.count)),
        ])
    }

    func release(_ image: RemoteImage, tag: String? = nil, format: Int = 1) throws -> [String: Any] {
        let tag = tag ?? self.tag(image)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(image))
        let data = try JSONSerialization.data(withJSONObject: ["format": format, "image": object])
        respond(manifestURL(tag), data: data)
        return ["tag_name": tag, "draft": false, "published_at": "2026-10-19T00:00:00Z", "assets": [[
            "name": manifest, "browser_download_url": manifestURL(tag).absoluteString,
            "size": data.count, "digest": "sha256:" + Self.digest(data), "state": "uploaded",
        ]]]
    }

    func respond(_ url: URL, json: Any) { respond(url, data: try! JSONSerialization.data(withJSONObject: json)) }
    func respond(_ url: URL, data: Data = Data(), status: Int = 200) {
        ImageFeedProtocol.replies.set(url, reply: .init(data: data, status: status))
    }
    func fail(_ url: URL, code: URLError.Code) {
        ImageFeedProtocol.replies.set(url, reply: .init(error: URLError(code)))
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private final class ImageFeedProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var data = Data()
        var status = 200
        var error: URLError?
    }
    final class Replies: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [URL: Reply] = [:]
        func set(_ url: URL, reply: Reply) { lock.withLock { values[url] = reply } }
        func get(_ url: URL) -> Reply? { lock.withLock { values[url] } }
        func remove(repository: String) {
            lock.withLock { values = values.filter { !$0.key.path.contains(repository) } }
        }
    }
    static let replies = Replies()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        guard let reply = Self.replies.get(url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
