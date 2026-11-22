import Foundation

/// One measurement taken at a spot on the floor plan.
struct SamplePoint: Identifiable, Codable, Hashable {
    var id = UUID()
    /// Position relative to the floor plan, 0...1 on each axis (0,0 = top-left).
    var x: Double
    var y: Double
    var date = Date()

    var downloadMbps: Double?
    var latencyMs: Double?
    var jitterMs: Double?
    /// Optional, entered by hand (iOS does not expose RSSI to apps).
    var rssi: Double?

    var ssid: String?
    /// The access point (radio) the phone was associated with — useful for mesh / multi-AP setups.
    var bssid: String?
}

struct Survey: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var created = Date()
    var floorPlanFile: String?
    var points: [SamplePoint] = []
}

enum Metric: String, CaseIterable, Identifiable, Codable {
    case download, latency, rssi

    var id: String { rawValue }

    var title: String {
        switch self {
        case .download: return "Download"
        case .latency: return "Latency"
        case .rssi: return "RSSI"
        }
    }

    var higherIsBetter: Bool { self != .latency }

    /// nil = auto-scale to the data.
    var fixedRange: ClosedRange<Double>? {
        switch self {
        case .download: return nil
        case .latency: return 5...120
        case .rssi: return -85 ... -40
        }
    }

    func value(_ p: SamplePoint) -> Double? {
        switch self {
        case .download: return p.downloadMbps
        case .latency: return p.latencyMs
        case .rssi: return p.rssi
        }
    }

    func format(_ v: Double) -> String {
        switch self {
        case .download: return v < 10 ? String(format: "%.1f Mbps", v) : String(format: "%.0f Mbps", v)
        case .latency: return String(format: "%.0f ms", v)
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
