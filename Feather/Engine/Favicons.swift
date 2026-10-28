import AppKit
import ImageIO
import WebKit

/// Site icons, fetched once per host and kept as small 32 pt PNGs on disk so
/// sleeping and restored tabs show icons without loading the page.
@Observable @MainActor
final class Favicons {
    static let shared = Favicons()

    private let memory = NSCache<NSString, NSImage>()
    private let diskMisses = NSCache<NSString, NSNumber>()
    private let directory: URL
    private let session: URLSession
    @ObservationIgnored private var inFlight: [String: Task<NSImage?, Never>] = [:]
    @ObservationIgnored private var diskLoads: [String: Task<NSImage?, Never>] = [:]
    @ObservationIgnored private var retryPolicy = FaviconRetryPolicy()
    /// A bounded invalidation token lets visible icon views pick up a later
    /// network result without per-host observer registries or UI-thread I/O.
    private var cacheRevision: UInt = 0

    private static let linkScript = """
        return JSON.stringify([...document.querySelectorAll('link[rel~="icon"], link[rel="apple-touch-icon"]')]
          .map(l => ({href: l.href, sizes: (l.sizes && l.sizes.value) || '', rel: l.rel})))
        """

    init() {
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Feather/Favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.countLimit = 300
        memory.totalCostLimit = 8 * 1_024 * 1_024
        diskMisses.countLimit = 1_000
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        session = URLSession(configuration: configuration)
    }

    func cached(host: String) -> NSImage? {
        _ = cacheRevision
        return memory.object(forKey: host as NSString)
    }

    /// Disk I/O and bitmap decoding must not stall session restore or SwiftUI's
    /// body evaluation. Concurrent views requesting one host share the same read.
    func loadCached(host: String) async -> NSImage? {
        if let image = cached(host: host) { return image }
        guard diskMisses.object(forKey: host as NSString) == nil else { return nil }
        if let pending = diskLoads[host] { return await pending.value }
        let source = file(for: host)
        let task = Task { () -> NSImage? in
            defer { diskLoads.removeValue(forKey: host) }
            let bitmap = await Task.detached(priority: .utility) { Self.readBitmap(from: source) }.value
            guard let bitmap else {
                diskMisses.setObject(true, forKey: host as NSString)
                return nil
            }
            let image = NSImage(cgImage: bitmap, size: NSSize(width: 32, height: 32))
            memory.setObject(image, forKey: host as NSString, cost: bitmap.bytesPerRow * bitmap.height)
            cacheRevision &+= 1
            return image
        }
        diskLoads[host] = task
        return await task.value
    }

    private nonisolated static func readBitmap(from url: URL) -> CGImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }

    func update(_ tab: Tab, from webView: WKWebView) async {
        guard let pageURL = webView.url, let host = pageURL.host() else { return }
        if let image = await loadCached(host: host) {
            if tab.url?.host() == host { tab.favicon = image }
            return
        }

        guard webView.url?.host() == host else { return }
        // Every tab waiting for this host receives the result of the same request.
        let task: Task<NSImage?, Never>
        if let pending = inFlight[host] {
            task = pending
        } else {
            guard retryPolicy.shouldAttempt(host, now: ProcessInfo.processInfo.systemUptime) else { return }
            let destination = file(for: host)
            task = Task { [weak webView] in
                defer { inFlight.removeValue(forKey: host) }
                guard let webView, webView.url?.host() == host else { return nil }
                let json = (try? await webView.callAsyncJavaScript(Self.linkScript, contentWorld: .defaultClient)) as? String
                // Navigation may have changed documents while WebKit evaluated the script.
                guard webView.url?.host() == host else { return nil }
                let iconURL = Self.bestIcon(in: json) ?? URL(string: "/favicon.ico", relativeTo: pageURL)?.absoluteURL
                guard let iconURL else { return nil }
                let requestSession = session
                let png = await Task.detached(priority: .utility) {
                    await Self.fetchPNG(from: iconURL, session: requestSession, destination: destination)
                }.value
                guard let png, let image = NSImage(data: png) else {
                    retryPolicy.failed(host, now: ProcessInfo.processInfo.systemUptime)
                    return nil
                }
                image.size = NSSize(width: 32, height: 32)
                memory.setObject(image, forKey: host as NSString, cost: 64 * 64 * 4)
                cacheRevision &+= 1
                diskMisses.removeObject(forKey: host as NSString)
                retryPolicy.succeeded(host)
                return image
            }
            inFlight[host] = task
        }
        if let image = await task.value, tab.url?.host() == host { tab.favicon = image }
    }

    private func file(for host: String) -> URL {
        directory.appendingPathComponent(host.replacingOccurrences(of: "/", with: "_") + ".png")
    }

    /// Prefers an icon of at least 32 px, then any declared icon.
    private static func bestIcon(in json: String?) -> URL? {
        guard let data = json?.data(using: .utf8),
              let links = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return nil }
        func size(_ link: [String: String]) -> Int {
            Int(link["sizes"]?.split(separator: "x").first ?? "") ?? (link["rel"]?.contains("apple") == true ? 180 : 16)
        }
        let ranked = links.sorted { abs(size($0) - 64) < abs(size($1) - 64) }
        return ranked.compactMap { $0["href"].flatMap(URL.init(string:)) }.first
    }

    /// Decode directly to an icon-sized bitmap; large touch icons never become full-sized AppKit images.
    private nonisolated static func fetchPNG(from url: URL, session: URLSession, destination: URL) async -> Data? {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 64,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let pixels = 64
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let scale = min(CGFloat(pixels) / CGFloat(thumbnail.width), CGFloat(pixels) / CGFloat(thumbnail.height))
        let width = CGFloat(thumbnail.width) * scale
        let height = CGFloat(thumbnail.height) * scale
        context.interpolationQuality = .high
        context.draw(thumbnail, in: CGRect(x: (CGFloat(pixels) - width) / 2, y: (CGFloat(pixels) - height) / 2,
                                          width: width, height: height))
        let png = NSMutableData()
        guard let image = context.makeImage(),
              let output = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(output, image, nil)
        guard CGImageDestinationFinalize(output) else { return nil }
        let result = png as Data
        try? result.write(to: destination, options: .atomic)
        return result
    }
}
