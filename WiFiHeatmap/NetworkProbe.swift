import CoreLocation
import Foundation
import Network
import NetworkExtension

struct ProbeSettings {
    static let latencyURLKey = "latencyURL"
    static let downloadURLKey = "downloadURL"
    static let pingCountKey = "pingCount"

    static let defaultLatencyURL = "https://www.apple.com/library/test/success.html"
    static let defaultDownloadURL = "https://speed.cloudflare.com/__down?bytes=25000000"

    var latencyURL: URL?
    var downloadURL: URL?
    var pingCount: Int

    static func current() -> ProbeSettings {
        let d = UserDefaults.standard
        let count = d.integer(forKey: pingCountKey)
        return ProbeSettings(
            latencyURL: URL(string: (d.string(forKey: latencyURLKey) ?? defaultLatencyURL).trimmingCharacters(in: .whitespaces)),
            downloadURL: URL(string: (d.string(forKey: downloadURLKey) ?? defaultDownloadURL).trimmingCharacters(in: .whitespaces)),
            pingCount: count > 0 ? count : 8)
    }
}

struct ProbeResult {
    var onWiFi: Bool
    var ssid: String?
    var bssid: String?
    var latencyMs: Double?
    var jitterMs: Double?
    var downloadMbps: Double?
    var errors: [String] = []
}

@MainActor
enum NetworkProbe {
    static func run(settings: ProbeSettings = .current(), progress: (String) -> Void) async -> ProbeResult {
        progress("Checking connection…")
        let onWiFi = await isOnWiFi()
        let network = await currentNetwork()
        var result = ProbeResult(onWiFi: onWiFi, ssid: network?.ssid, bssid: network?.bssid)

        let session = makeSession()
        defer { session.invalidateAndCancel() }

        if let url = settings.latencyURL {
            progress("Measuring latency…")
            do {
                let (median, jitter) = try await measureLatency(url: url, count: settings.pingCount, session: session)
                result.latencyMs = median
                result.jitterMs = jitter
            } catch {
                result.errors.append("Latency: \(error.localizedDescription)")
            }
        }

        if let url = settings.downloadURL {
            progress("Measuring download speed…")
            do {
                result.downloadMbps = try await measureDownload(url: url, session: session)
            } catch {
                result.errors.append("Download: \(error.localizedDescription)")
            }
        }
        return result
    }

    // MARK: - Measurements

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.allowsCellularAccess = false   // never silently measure cellular
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }

    /// Sends `count + 1` HEAD requests over one kept-alive connection. The first is discarded
    /// (it includes DNS + TCP + TLS setup); returns the median and mean jitter of the rest.
    private static func measureLatency(url: URL, count: Int, session: URLSession) async throws -> (Double, Double) {
        var samples: [Double] = []
        var lastError: Error?
        for i in 0...count {
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            let start = ContinuousClock.now
            do {
                _ = try await session.data(for: request)
                let ms = (ContinuousClock.now - start).milliseconds
                if i > 0 { samples.append(ms) }
            } catch {
                lastError = error
            }
        }
        guard !samples.isEmpty else { throw lastError ?? URLError(.cannotConnectToHost) }

        let sorted = samples.sorted()
        let mid = sorted.count / 2
        let median = sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
        let jitter = samples.count > 1
            ? zip(samples, samples.dropFirst()).map { abs($0 - $1) }.reduce(0, +) / Double(samples.count - 1)
            : 0
        return (median, jitter)
    }

    private static func measureDownload(url: URL, session: URLSession) async throws -> Double {
        let start = ContinuousClock.now
        let (data, response) = try await session.data(from: url)
        let seconds = (ContinuousClock.now - start).milliseconds / 1000
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        guard seconds > 0, !data.isEmpty else { throw URLError(.zeroByteResource) }
        return Double(data.count) * 8 / seconds / 1_000_000
    }

    // MARK: - Network info

    private final class Once { var done = false }

    static func isOnWiFi() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let once = Once()
            monitor.pathUpdateHandler = { path in
                guard !once.done else { return }
                once.done = true
                monitor.pathUpdateHandler = nil
                monitor.cancel()
                continuation.resume(returning: path.status == .satisfied && path.usesInterfaceType(.wifi))
            }
            monitor.start(queue: .main)
        }
    }

    /// Needs the "Access WiFi Information" capability and location permission; returns nil otherwise.
    static func currentNetwork() async -> (ssid: String, bssid: String)? {
        guard let network = await NEHotspotNetwork.fetchCurrent() else { return nil }
        return (network.ssid, network.bssid)
    }
}

/// iOS only reveals the SSID/BSSID to apps that have location permission.
@MainActor
final class LocationPermission {
    static let shared = LocationPermission()
    private let manager = CLLocationManager()

    func requestIfNeeded() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }
}

extension Duration {
    var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}
