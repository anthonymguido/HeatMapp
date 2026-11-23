import CoreLocation
import Foundation
import Network
import NetworkExtension

struct ProbeSettings {
    static let latencyURLKey = "latencyURL"
    static let downloadURLKey = "downloadURL"
    static let pingCountKey = "pingCount"
    static let routerAddressKey = "routerAddress"
    static let routerPingCountKey = "routerPingCount"
    static let downloadSecondsKey = "downloadSeconds"

    static let defaultLatencyURL = "https://www.apple.com/library/test/success.html"
    static let defaultDownloadURL = "https://speed.cloudflare.com/__down?bytes=25000000"
    static let defaultPingCount = 8
    static let defaultRouterPingCount = 30
    static let defaultDownloadSeconds = 6
    static let downloadStreams = 4

    var latencyURL: URL?
    var downloadURL: URL?
    var pingCount: Int
    /// nil = detect the router automatically.
    var routerAddress: String?
    var routerPingCount: Int
    var downloadSeconds: Int

    static func current() -> ProbeSettings {
        let d = UserDefaults.standard
        func positive(_ key: String, _ fallback: Int) -> Int {
            let v = d.integer(forKey: key)
            return v > 0 ? v : fallback
        }
        let router = (d.string(forKey: routerAddressKey) ?? "").trimmingCharacters(in: .whitespaces)
        return ProbeSettings(
            latencyURL: URL(string: (d.string(forKey: latencyURLKey) ?? defaultLatencyURL).trimmingCharacters(in: .whitespaces)),
            downloadURL: URL(string: (d.string(forKey: downloadURLKey) ?? defaultDownloadURL).trimmingCharacters(in: .whitespaces)),
            pingCount: positive(pingCountKey, defaultPingCount),
            routerAddress: router.isEmpty ? nil : router,
            routerPingCount: positive(routerPingCountKey, defaultRouterPingCount),
            downloadSeconds: positive(downloadSecondsKey, defaultDownloadSeconds))
    }
}

struct ProbeResult {
    var onWiFi: Bool
    var ssid: String?
    var bssid: String?
    var routerAddress: String?
    var routerLatencyMs: Double?
    var routerJitterMs: Double?
    var packetLossPct: Double?
    var latencyMs: Double?
    var jitterMs: Double?
    var downloadMbps: Double?
    var errors: [String] = []

    var hasAnyMeasurement: Bool { routerLatencyMs != nil || latencyMs != nil || downloadMbps != nil }
}

@MainActor
enum NetworkProbe {
    /// Runs the tests one after another, so they don't disturb each other:
    /// router ping (Wi-Fi link) → internet latency → download speed.
    static func run(settings: ProbeSettings = .current(), progress: (String) -> Void) async -> ProbeResult {
        progress("Checking connection…")
        let wifi = await wifiStatus()
        let network = await currentNetwork()
        var result = ProbeResult(onWiFi: wifi.onWiFi, ssid: network?.ssid, bssid: network?.bssid)
        guard wifi.onWiFi else { return result }

        // 1. Router: latency, jitter and packet loss over the Wi-Fi link only.
        if let router = settings.routerAddress ?? wifi.gateway {
            progress("Pinging your router…")
            do {
                let stats = try await ping(router, count: settings.routerPingCount)
                result.routerAddress = router
                result.routerLatencyMs = stats.median
                result.routerJitterMs = stats.jitter
                result.packetLossPct = stats.lossPct
            } catch {
                result.errors.append("Router: \(error.localizedDescription)")
            }
        } else {
            result.errors.append("Router: couldn't find its address. You can enter it in Settings.")
        }

        // 2. Internet latency.
        if let url = settings.latencyURL {
            progress("Measuring internet latency…")
            let session = makeSession()
            defer { session.invalidateAndCancel() }
            do {
                let (median, jitter) = try await measureLatency(url: url, count: settings.pingCount, session: session)
                result.latencyMs = median
                result.jitterMs = jitter
            } catch {
                result.errors.append("Latency: \(error.localizedDescription)")
            }
        }

        // 3. Download speed.
        if let url = settings.downloadURL {
            progress("Measuring download speed…")
            do {
                result.downloadMbps = try await measureDownload(url: url,
                                                                seconds: Double(settings.downloadSeconds),
                                                                streams: ProbeSettings.downloadStreams,
                                                                progress: progress)
            } catch {
                result.errors.append("Download: \(error.localizedDescription)")
            }
        }
        return result
    }

    /// Pings the router once at launch, so iOS asks for Local Network access before the first measurement.
    static func primeLocalNetworkAccess() async {
        let wifi = await wifiStatus()
        guard let router = ProbeSettings.current().routerAddress ?? wifi.gateway else { return }
        _ = try? await ping(router, count: 1)
    }

    // MARK: - Measurements

    private static func ping(_ host: String, count: Int) async throws -> PingStats {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try Pinger.ping(host, count: count))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

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
    /// (it includes DNS + TCP + TLS setup). Each round trip is timed by the network stack itself
    /// (request sent → first response byte), which excludes app scheduling delays.
    private static func measureLatency(url: URL, count: Int, session: URLSession) async throws -> (Double, Double) {
        var samples: [Double] = []
        var lastError: Error?
        for i in 0...count {
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            let collector = TimingCollector()
            let start = ContinuousClock.now
            do {
                _ = try await session.data(for: request, delegate: collector)
                let ms = collector.roundTripMs ?? (ContinuousClock.now - start).milliseconds
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

    /// Like a speed test: several parallel connections download for a fixed time. The first part
    /// (connection setup, TCP ramp-up) is ignored, and the speed is taken over the steady part.
    private static func measureDownload(url: URL, seconds: Double, streams: Int,
                                        progress: (String) -> Void) async throws -> Double {
        let meter = ThroughputMeter(url: url, streams: streams)
        meter.start()
        defer { meter.stop() }

        let start = ContinuousClock.now
        var samples: [(t: Double, bytes: Int64)] = [(0, 0)]
        while true {
            try await Task.sleep(nanoseconds: 250_000_000)
            let t = (ContinuousClock.now - start).milliseconds / 1000
            let bytes = meter.bytesReceived
            samples.append((t, bytes))

            if bytes == 0, let error = meter.lastError, t > 1 { throw error }
            if let past = samples.last(where: { t - $0.t >= 1 }), t > past.t {
                let live = Double(bytes - past.bytes) * 8 / (t - past.t) / 1_000_000
                progress(String(format: "Measuring download speed… %.0f Mbps", live))
            }
            if t >= seconds { break }
        }

        guard let firstData = samples.first(where: { $0.bytes > 0 }), let last = samples.last else {
            throw meter.lastError ?? URLError(.timedOut)
        }
        let warmup = min(max(seconds * 0.25, 1), 2)
        let base = samples.first(where: { $0.t >= firstData.t + warmup && last.t - $0.t >= 1 }) ?? firstData
        let bytes = last.bytes - base.bytes
        let span = last.t - base.t
        guard bytes > 0, span > 0 else { throw meter.lastError ?? URLError(.zeroByteResource) }
        return Double(bytes) * 8 / span / 1_000_000
    }

    // MARK: - Network info

    private final class Once { var done = false }

    /// Whether the phone is on Wi-Fi, and the router's IPv4 address if iOS reports it.
    static func wifiStatus() async -> (onWiFi: Bool, gateway: String?) {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let once = Once()
            monitor.pathUpdateHandler = { path in
                guard !once.done else { return }
                once.done = true
                monitor.pathUpdateHandler = nil
                monitor.cancel()
                let onWiFi = path.status == .satisfied && path.usesInterfaceType(.wifi)
                var gateway: String?
                for endpoint in path.gateways {
                    if case .hostPort(let host, _) = endpoint, case .ipv4(let address) = host {
                        gateway = address.rawValue.map { String($0) }.joined(separator: ".")
                        break
                    }
                }
                continuation.resume(returning: (onWiFi, gateway))
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

/// Records the network stack's own timing for one request.
private final class TimingCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double?

    var roundTripMs: Double? {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let t = metrics.transactionMetrics.last,
              let sent = t.requestStartDate, let firstByte = t.responseStartDate else { return }
        lock.lock(); value = firstByte.timeIntervalSince(sent) * 1000; lock.unlock()
    }
}

/// Downloads `url` over several separate connections, re-fetching it whenever a copy finishes,
/// and counts the bytes as they arrive.
private final class ThroughputMeter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let streams: Int
    private let lock = NSLock()
    private var bytes: Int64 = 0
    private var stopped = false
    private var error: Error?
    private var sessions: [URLSession] = []
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        return q
    }()

    init(url: URL, streams: Int) {
        self.url = url
        self.streams = max(1, streams)
        super.init()
    }

    var bytesReceived: Int64 {
        lock.lock(); defer { lock.unlock() }
        return bytes
    }

    var lastError: Error? {
        lock.lock(); defer { lock.unlock() }
        return error
    }

    func start() {
        for _ in 0..<streams {
            // One session per stream, so each gets its own connection (HTTP/2 would otherwise share one).
            let config = URLSessionConfiguration.ephemeral
            config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            config.urlCache = nil
            config.allowsCellularAccess = false
            config.waitsForConnectivity = false
            config.timeoutIntervalForRequest = 10
            let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
            sessions.append(session)
            session.dataTask(with: url).resume()
        }
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        for session in sessions { session.invalidateAndCancel() }
        sessions.removeAll()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if let http = dataTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            lock.lock(); error = URLError(.badServerResponse); lock.unlock()
            dataTask.cancel()
            return
        }
        lock.lock(); bytes += Int64(data.count); lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        if let error {
            if (error as? URLError)?.code != .cancelled { self.error = error }
            return
        }
        // This copy finished before time ran out: fetch it again on the same connection.
        // (Done under the lock, so it can't race with stop() invalidating the session.)
        session.dataTask(with: url).resume()
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
