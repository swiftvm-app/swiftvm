import CryptoKit
import Foundation

/// Downloads images into a cache directory and verifies them against published checksums.
public struct ImageDownloader: Sendable {
    public enum DownloadError: Error, LocalizedError {
        case badResponse(Int)
        case checksumMismatch(fileName: String)
        case checksumUnavailable(fileName: String)

        public var errorDescription: String? {
            switch self {
            case .badResponse(let status):
                "The download server answered with HTTP status \(status)."
            case .checksumMismatch(let fileName):
                "\(fileName) is damaged: its checksum doesn't match the published one. Try the download again."
            case .checksumUnavailable(let fileName):
                "Couldn't find a published checksum for \(fileName)."
            }
        }
    }

    public struct Progress: Sendable {
        public var bytesReceived: Int64
        /// Total size, or `nil` if the server didn't say.
        public var bytesExpected: Int64?

        public var fraction: Double? {
            guard let bytesExpected, bytesExpected > 0 else { return nil }
            return min(Double(bytesReceived) / Double(bytesExpected), 1)
        }
    }

    /// Where downloads are kept. Changing it leaves what is there already where it is.
    public var cacheDirectory: URL
    /// Pause before an interrupted download is picked up again.
    var resumeDelay: Duration = .seconds(2)
    /// The downloads under way. Shared by copies of this value.
    private let activity = DownloadActivity()

    public init(cacheDirectory: URL = ImageDownloader.defaultCacheDirectory) {
        self.cacheDirectory = cacheDirectory
    }

    public static var defaultCacheDirectory: URL {
        URL.cachesDirectory.appending(path: "SwiftVM/Downloads", directoryHint: .isDirectory)
    }

    /// Where the verified copy of `image` lives once downloaded.
    public func cachedURL(for image: RemoteImage) -> URL {
        cacheDirectory.appending(path: image.fileName)
    }

    /// Whether a verified copy of `image` is already in the cache.
    public func isCached(_ image: RemoteImage) -> Bool {
        FileManager.default.fileExists(atPath: cachedURL(for: image).path)
    }

    /// Where an unfinished download of `image` leaves what is needed to carry on with it later.
    func unfinishedDownloadURL(for image: RemoteImage) -> URL {
        cacheDirectory.appending(path: image.fileName + ".resume")
    }

    /// Waits until every download that was cancelled has put away what it had received, which is what
    /// lets it carry on after the app is opened again. For the app to call on its way out, after it has
    /// cancelled whatever was downloading. Blocks the calling thread, `timeout` seconds at most.
    ///
    /// - Returns: `false` if downloads were still under way when the time was up.
    @discardableResult
    public func waitForDownloadsToWindUp(timeout: TimeInterval) -> Bool {
        activity.waitUntilIdle(timeout: timeout)
    }

    /// Asks the server how large `image` is, without downloading it. `nil` if the server doesn't say.
    public func remoteSize(of image: RemoteImage) async -> Int64? {
        var request = URLRequest(url: image.url)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.expectedContentLength > 0
        else { return nil }
        return http.expectedContentLength
    }

    /// Returns the local file for `image`, downloading and verifying it if it isn't cached yet.
    public func fetch(_ image: RemoteImage, progress: @escaping @Sendable (Progress) -> Void) async throws -> URL {
        let destination = cachedURL(for: image)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            return destination
        }
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        let partial = cacheDirectory.appending(path: image.fileName + ".partial")
        try? fileManager.removeItem(at: partial)
        try await download(image.url, to: partial, unfinishedAt: unfinishedDownloadURL(for: image), progress: progress)

        do {
            try await verify(partial, against: image)
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }
        try fileManager.moveItem(at: partial, to: destination)
        return destination
    }

    // MARK: Download

    /// How many times in a row a download may be picked up again without getting any further.
    static let maximumStalledResumes = 4

    /// Downloads `url` to `destination`. Images run to tens of gigabytes, so what has arrived is never
    /// given up lightly:
    /// - When the connection drops partway, the download carries on from where it stopped instead of
    ///   starting over, as long as the server supports that.
    /// - When the download is cancelled, fails for good or is cut short by the app quitting, what is
    ///   needed to carry on is written to `unfinished`, and the next attempt starts from there.
    private func download(
        _ url: URL, to destination: URL, unfinishedAt unfinished: URL, progress: @escaping @Sendable (Progress) -> Void
    ) async throws {
        activity.begin()
        defer { activity.end() }
        let delegate = DownloadDelegate(destination: destination, progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        // What an earlier attempt left, in this run of the app or one before it. Taken off the disk here:
        // two downloads carrying on from the same point would write over each other.
        var leftover = UnfinishedDownload.take(from: unfinished, for: url)
        var resumeData = leftover
        var stalledResumes = 0
        var bytesAtLastFailure: Int64 = 0
        do {
            while true {
                try Task.checkCancellation()
                let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: url)
                let startsFromLeftover = resumeData != nil && resumeData == leftover
                do {
                    try await withTaskCancellationHandler {
                        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                            delegate.setContinuation(continuation)
                            task.resume()
                        }
                    } onCancel: {
                        // Unlike a plain `cancel()`, this keeps what has arrived. How to carry on from it
                        // comes with the error the task then ends with.
                        task.cancel(byProducingResumeData: { _ in })
                    }
                    return
                } catch let error as DownloadError {
                    // The server answered the request to carry on with something other than the rest of
                    // the file, and URLSession has put that answer in the place of what had arrived.
                    // Nothing is left to carry on from. Start from the beginning, once.
                    guard startsFromLeftover else { throw error }
                    leftover = nil
                    resumeData = nil
                } catch let error as URLError {
                    resumeData = error.downloadTaskResumeData
                    guard error.code != .cancelled else { throw error }
                    guard resumeData != nil else {
                        guard startsFromLeftover else { throw error }
                        // Nothing came of what was left over. Start from the beginning, once. Only when
                        // the system can't make sense of it is it thrown away for good; otherwise it is
                        // still there to fall back on if starting over gets nowhere either.
                        if error.code == .unsupportedURL {
                            leftover = nil
                        }
                        continue
                    }
                    let bytesReceived = delegate.bytesReceived
                    stalledResumes = bytesReceived > bytesAtLastFailure ? 0 : stalledResumes + 1
                    guard stalledResumes <= Self.maximumStalledResumes else { throw error }
                    bytesAtLastFailure = bytesReceived
                    // Give the network a moment to come back; longer each time nothing got through.
                    try await Task.sleep(for: resumeDelay * (stalledResumes + 1))
                }
            }
        } catch {
            // Kept for the next attempt, unless it was the server that said no: its answer has replaced
            // what had arrived. If this attempt got nowhere, what was left over before it is as good as
            // it was.
            if !(error is DownloadError), let data = resumeData ?? leftover {
                UnfinishedDownload(url: url, resumeData: data).save(to: unfinished)
            }
            throw error
        }
    }

    // MARK: Verification

    private func verify(_ file: URL, against image: RemoteImage) async throws {
        guard let checksumsURL = image.checksumsURL, let algorithm = image.checksumAlgorithm else { return }
        let (data, response) = try await URLSession.shared.data(from: checksumsURL)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw DownloadError.badResponse(http.statusCode)
        }
        let listing = String(decoding: data, as: UTF8.self)
        guard let expected = Self.expectedDigest(for: image.fileName, in: listing) else {
            throw DownloadError.checksumUnavailable(fileName: image.fileName)
        }
        let actual = try await Task.detached(priority: .userInitiated) {
            try Self.digest(of: file, algorithm: algorithm)
        }.value
        guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
            throw DownloadError.checksumMismatch(fileName: image.fileName)
        }
    }

    /// Finds the digest listed for `fileName` in a `SHA256SUMS`-style listing (`<hex>  <name>` or `<hex> *<name>`).
    static func expectedDigest(for fileName: String, in listing: String) -> String? {
        for line in listing.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            var name = parts[1].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") {
                name.removeFirst()
            }
            if name == fileName {
                return String(parts[0])
            }
        }
        return nil
    }

    static func digest(of file: URL, algorithm: RemoteImage.ChecksumAlgorithm) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let chunkSize = 4 << 20
        switch algorithm {
        case .sha256:
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        case .sha512:
            var hasher = SHA512()
            while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }
}

/// What is kept on disk to carry on with a download later: URLSession's resume data, and the address it is
/// for. The bytes that have arrived are in a temporary file of the system's, which the resume data names.
struct UnfinishedDownload: Codable {
    var url: URL
    var resumeData: Data

    /// Reads and removes the file at `file`. `nil` if there is none or it is for another address.
    static func take(from file: URL, for url: URL) -> Data? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        try? FileManager.default.removeItem(at: file)
        guard let saved = try? PropertyListDecoder().decode(UnfinishedDownload.self, from: data), saved.url == url else {
            return nil
        }
        return saved.resumeData
    }

    func save(to file: URL) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try? encoder.encode(self).write(to: file, options: .atomic)
    }
}

/// Counts the downloads under way, so that the app can wait for them on its way out.
private final class DownloadActivity: @unchecked Sendable {
    private let condition = NSCondition()
    private var count = 0

    func begin() {
        condition.withLock { count += 1 }
    }

    func end() {
        condition.withLock {
            count -= 1
            condition.broadcast()
        }
    }

    func waitUntilIdle(timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        return condition.withLock {
            while count > 0 {
                guard condition.wait(until: deadline) else { return false }
            }
            return true
        }
    }
}

/// Bridges URLSession's download callbacks to a continuation and a progress closure.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (ImageDownloader.Progress) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var moveError: (any Error)?
    private var totalBytesReceived: Int64 = 0

    /// Bytes received so far, across interruptions.
    var bytesReceived: Int64 {
        lock.withLock { totalBytesReceived }
    }

    init(destination: URL, progress: @escaping @Sendable (ImageDownloader.Progress) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    /// Called before each task is started.
    func setContinuation(_ continuation: CheckedContinuation<Void, any Error>) {
        lock.withLock {
            self.continuation = continuation
            moveError = nil
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        lock.withLock { totalBytesReceived = max(totalBytesReceived, totalBytesWritten) }
        progress(.init(
            bytesReceived: totalBytesWritten,
            bytesExpected: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        ))
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64
    ) {
        lock.withLock { totalBytesReceived = max(totalBytesReceived, fileOffset) }
        progress(.init(bytesReceived: fileOffset, bytesExpected: expectedTotalBytes > 0 ? expectedTotalBytes : nil))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this method returns, so move it now.
        do {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw ImageDownloader.DownloadError.badResponse(http.statusCode)
            }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            lock.withLock { moveError = error }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (continuation, failure) = lock.withLock {
            let pending = self.continuation
            self.continuation = nil
            return (pending, error ?? moveError)
        }
        if let failure {
            continuation?.resume(throwing: failure)
        } else {
            continuation?.resume()
        }
    }
}
