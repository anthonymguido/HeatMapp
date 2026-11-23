import Foundation

/// One measurement taken at a spot on the floor plan.
struct SamplePoint: Identifiable, Codable, Hashable {
    var id = UUID()
    /// Position relative to the floor plan, 0...1 on each axis (0,0 = top-left).
    var x: Double
    var y: Double
    var date = Date()

    var downloadMbps: Double?
    /// Internet round-trip time (to the latency test server).
    var latencyMs: Double?
    var jitterMs: Double?
    /// Ping to the Wi-Fi router itself: the quality of the Wi-Fi link, without the internet involved.
    var routerLatencyMs: Double?
    var routerJitterMs: Double?
    /// Share of router pings that got no answer, 0...100.
    var packetLossPct: Double?
    /// Optional, entered by hand (iOS does not expose RSSI to apps).
    var rssi: Double?

    var ssid: String?
    /// The access point (radio) the phone was associated with — useful for mesh / multi-AP setups.
    var bssid: String?
    var routerAddress: String?
}

struct Survey: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var created = Date()
    var floorPlanFile: String?
    var points: [SamplePoint] = []
}

enum Metric: String, CaseIterable, Identifiable, Codable {
    case download, router, latency, loss, rssi

    var id: String { rawValue }

    /// Short name for the picker.
    var title: String {
        switch self {
        case .download: return "Download"
        case .router: return "Router"
        case .latency: return "Internet"
        case .loss: return "Loss"
        case .rssi: return "RSSI"
        }
    }

    /// One line under the picker explaining what's being mapped.
    var explanation: String {
        switch self {
        case .download: return "Download speed. Can be capped by your internet plan."
        case .router: return "Ping to your router. The purest measure of the Wi-Fi link."
        case .latency: return "Ping to a server on the internet (Wi-Fi + your provider)."
        case .loss: return "Router pings that got no answer. Anything above 0% hurts calls and games."
        case .rssi: return "Signal strength you typed in by hand."
        }
    }

    var higherIsBetter: Bool { self == .download || self == .rssi }

    /// nil = auto-scale to the data.
    var fixedRange: ClosedRange<Double>? {
        switch self {
        case .download: return nil
        case .router: return 2...50
        case .latency: return 5...120
        case .loss: return 0...10
        case .rssi: return -85 ... -40
        }
    }

    func value(_ p: SamplePoint) -> Double? {
        switch self {
        case .download: return p.downloadMbps
        case .router: return p.routerLatencyMs
        case .latency: return p.latencyMs
        case .loss: return p.packetLossPct
        case .rssi: return p.rssi
        }
    }

    func format(_ v: Double) -> String {
        switch self {
        case .download: return v < 10 ? String(format: "%.1f Mbps", v) : String(format: "%.0f Mbps", v)
        case .router: return v < 10 ? String(format: "%.1f ms", v) : String(format: "%.0f ms", v)
        case .latency: return String(format: "%.0f ms", v)
        case .loss: return String(format: "%.0f%%", v)
        case .rssi: return String(format: "%.0f dBm", v)
        }
    }

    func range(for points: [SamplePoint]) -> ClosedRange<Double>? {
        let values = points.compactMap { value($0) }
        guard let lo = values.min(), let hi = values.max() else { return nil }
        if let fixedRange { return fixedRange }
        if hi - lo < 0.001 { return (lo - 1)...(hi + 1) }
        return lo...hi
    }

    /// 0 = worst, 1 = best.
    func normalized(_ v: Double, in r: ClosedRange<Double>) -> Double {
        let span = r.upperBound - r.lowerBound
        guard span > 0 else { return 0.5 }
        let f = (v - r.lowerBound) / span
        return min(max(higherIsBetter ? f : 1 - f, 0), 1)
    }
}
