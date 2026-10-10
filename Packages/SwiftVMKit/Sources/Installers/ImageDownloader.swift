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

    public let cacheDirectory: URL

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
        try await download(image.url, to: partial, progress: progress)

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

    private func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Progress) -> Void) async throws {
        let delegate = DownloadDelegate(destination: destination, progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                delegate.setContinuation(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
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

/// Bridges URLSession's download callbacks to a continuation and a progress closure.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (ImageDownloader.Progress) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var moveError: (any Error)?

    init(destination: URL, progress: @escaping @Sendable (ImageDownloader.Progress) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func setContinuation(_ continuation: CheckedContinuation<Void, any Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        progress(.init(
            bytesReceived: totalBytesWritten,
            bytesExpected: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        ))
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
