import CoreGraphics
import Foundation
import SwiftUI

enum ColorRamp {
    private static let stops: [(t: Double, r: Double, g: Double, b: Double)] = [
        (0.00, 0.86, 0.15, 0.15),  // red
        (0.35, 0.98, 0.45, 0.09),  // orange
        (0.60, 0.92, 0.70, 0.03),  // yellow
        (1.00, 0.09, 0.64, 0.29)   // green
    ]

    /// t: 0 = worst (red), 1 = best (green)
    static func rgb(_ t: Double) -> (r: Double, g: Double, b: Double) {
        let t = min(max(t, 0), 1)
        for i in 1..<stops.count where t <= stops[i].t {
            let a = stops[i - 1], b = stops[i]
            let f = (t - a.t) / (b.t - a.t)
            return (a.r + (b.r - a.r) * f, a.g + (b.g - a.g) * f, a.b + (b.b - a.b) * f)
        }
        let last = stops[stops.count - 1]
        return (last.r, last.g, last.b)
    }

    static func color(_ t: Double) -> Color {
        let c = rgb(t)
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    static var gradient: Gradient {
        Gradient(stops: stops.map { .init(color: Color(red: $0.r, green: $0.g, blue: $0.b), location: $0.t) })
    }
}

/// Builds a small heatmap bitmap with inverse-distance-weighting (IDW) interpolation.
/// The bitmap is low-resolution on purpose; it's drawn scaled-up with smoothing.
enum HeatmapRenderer {
    /// - Parameters:
    ///   - aspect: floor plan width / height
    ///   - reach: distance (as a fraction of the plan's width) around each sample that is fully
    ///            coloured; colour fades out over the same distance again beyond that.
    static func render(points: [SamplePoint],
                       metric: Metric,
                       range: ClosedRange<Double>,
                       aspect: Double,
                       width: Int = 220,
                       power: Double = 2,
                       reach: Double = 0.2) -> CGImage? {
        guard aspect > 0 else { return nil }
        // Work in "width units" so distances are the same horizontally and vertically.
        let samples: [(x: Double, y: Double, v: Double)] = points.compactMap { p in
            guard let v = metric.value(p) else { return nil }
            return (p.x, p.y / aspect, v)
        }
        guard !samples.isEmpty else { return nil }

        let w = max(width, 8)
        let h = max(Int((Double(w) / aspect).rounded()), 8)
        var buffer = [UInt8](repeating: 0, count: w * h * 4)

        for py in 0..<h {
            let Y = (Double(py) + 0.5) / Double(h) / aspect
            for px in 0..<w {
                let X = (Double(px) + 0.5) / Double(w)
                var num = 0.0, den = 0.0, minD2 = Double.infinity
                var exact: Double?
                for s in samples {
                    let dx = X - s.x, dy = Y - s.y
                    let d2 = dx * dx + dy * dy
                    if d2 < 1e-12 { exact = s.v; minD2 = 0; break }
                    let weight = 1 / pow(d2, power / 2)
                    num += weight * s.v
                    den += weight
                    if d2 < minD2 { minD2 = d2 }
                }
                let value = exact ?? (num / den)
                let d = minD2.squareRoot()
                let alpha = d <= reach ? 1.0 : max(0, 1 - (d - reach) / reach)
                if alpha <= 0 { continue }

                let c = ColorRamp.rgb(metric.normalized(value, in: range))
                let i = (py * w + px) * 4
                buffer[i]     = UInt8(c.r * alpha * 255)   // premultiplied
                buffer[i + 1] = UInt8(c.g * alpha * 255)
                buffer[i + 2] = UInt8(c.b * alpha * 255)
                buffer[i + 3] = UInt8(alpha * 255)
            }
        }

        guard let provider = CGDataProvider(data: Data(buffer) as CFData) else { return nil }
        return CGImage(width: w, height: h,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
