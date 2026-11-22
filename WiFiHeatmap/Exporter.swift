import UIKit

enum HeatmapExporter {
    /// Floor plan + heatmap + labelled measurement dots, at the floor plan's full resolution.
    static func composite(floorPlan: UIImage,
                          heatmap: CGImage?,
                          opacity: Double,
                          points: [SamplePoint],
                          metric: Metric,
                          range: ClosedRange<Double>?) -> UIImage {
        let size = CGSize(width: floorPlan.size.width * floorPlan.scale,
                          height: floorPlan.size.height * floorPlan.scale)
        let rect = CGRect(origin: .zero, size: size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1

        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            floorPlan.draw(in: rect)
            if let heatmap {
                ctx.cgContext.interpolationQuality = .high
                UIImage(cgImage: heatmap).draw(in: rect, blendMode: .normal, alpha: opacity)
            }

            let radius = max(size.width, size.height) / 110
            let font = UIFont.systemFont(ofSize: radius * 1.6, weight: .semibold)
            for p in points {
                let center = CGPoint(x: p.x * size.width, y: p.y * size.height)
                let value = metric.value(p)
                let fill: UIColor
                if let value, let range {
                    let c = ColorRamp.rgb(metric.normalized(value, in: range))
                    fill = UIColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
                } else {
                    fill = .systemGray
                }
                let dot = UIBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                      width: radius * 2, height: radius * 2))
                fill.setFill(); dot.fill()
                UIColor.white.setStroke(); dot.lineWidth = radius * 0.35; dot.stroke()

                if let value {
                    let text = metric.format(value) as NSString
                    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
                    let textSize = text.size(withAttributes: attrs)
                    let origin = CGPoint(x: center.x - textSize.width / 2, y: center.y + radius * 1.4)
                    let bg = CGRect(origin: origin, size: textSize).insetBy(dx: -radius * 0.4, dy: -radius * 0.15)
                    UIColor.white.withAlphaComponent(0.85).setFill()
                    UIBezierPath(roundedRect: bg, cornerRadius: radius * 0.4).fill()
                    text.draw(at: origin, withAttributes: attrs)
                }
            }
        }
    }

    static func csv(for points: [SamplePoint]) -> String {
        let iso = ISO8601DateFormatter()
        func num(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "" }
        func quoted(_ s: String?) -> String {
            guard let s else { return "" }
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var lines = ["x,y,download_mbps,latency_ms,jitter_ms,rssi_dbm,ssid,bssid,timestamp"]
        for p in points {
            lines.append([String(format: "%.4f", p.x), String(format: "%.4f", p.y),
                          num(p.downloadMbps), num(p.latencyMs), num(p.jitterMs), num(p.rssi),
                          quoted(p.ssid), quoted(p.bssid), iso.string(from: p.date)].joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    static func writeCSV(for survey: Survey) -> URL? {
        let safeName = survey.name.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeName.isEmpty ? "survey" : safeName).csv")
        do {
            try csv(for: survey.points).write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
