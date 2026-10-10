import AppKit

/// Downloads GIF media into memory only. Nothing is written to disk (GIPHY asks partners not to
/// cache media, and the user's searches should leave no trace), and everything is dropped when
/// the panel closes. Concurrent requests for the same URL share one download.
@MainActor
final class GIFImageLoader {
    private let session: URLSession
    private let images = NSCache<NSURL, NSImage>()
    private let data = NSCache<NSURL, NSData>()
    private var inFlight: [URL: Task<Data, Error>] = [:]

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
        images.countLimit = 150
        data.totalCostLimit = 96 * 1024 * 1024
    }

    /// Already-decoded image, if any (lets cells render synchronously on reappear).
    func cachedImage(for url: URL) -> NSImage? {
        images.object(forKey: url as NSURL)
    }

    /// The animated image at `url`, or nil when it could not be loaded.
    func image(for url: URL) async -> NSImage? {
        if let image = cachedImage(for: url) { return image }
        guard let bytes = try? await self.data(for: url), !Task.isCancelled,
              let image = NSImage(data: bytes) else { return nil }
        images.setObject(image, forKey: url as NSURL)
        return image
    }

    /// Raw bytes at `url` (shared download, memory cached).
    func data(for url: URL) async throws -> Data {
        if let cached = data.object(forKey: url as NSURL) { return cached as Data }
        let task: Task<Data, Error>
        if let existing = inFlight[url] {
            task = existing
        } else {
            let session = session
            task = Task.detached(priority: .userInitiated) {
                let (bytes, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      !bytes.isEmpty else { throw URLError(.badServerResponse) }
                return bytes
            }
            inFlight[url] = task
        }
        do {
            let bytes = try await task.value
            inFlight[url] = nil
            data.setObject(bytes as NSData, forKey: url as NSURL, cost: bytes.count)
            return bytes
        } catch {
            if inFlight[url] == task { inFlight[url] = nil }
            throw error
        }
    }

    /// Cancels downloads for URLs that are no longer on screen.
    func cancel(except keep: Set<URL>) {
        for (url, task) in inFlight where !keep.contains(url) {
            task.cancel()
            inFlight[url] = nil
        }
    }

    /// Drops every download and cached byte.
    func purge() {
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        images.removeAllObjects()
        data.removeAllObjects()
    }
}
