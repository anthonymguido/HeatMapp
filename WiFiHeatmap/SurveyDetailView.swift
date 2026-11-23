import SwiftUI

struct SurveyDetailView: View {
    @EnvironmentObject private var store: SurveyStore
    let surveyID: UUID

    @State private var metric: Metric = .download
    @State private var showHeatmap = true
    @State private var opacity = 0.7
    @State private var placing: CGPoint?          // normalized, pending measurement
    @State private var measuring = false
    @State private var status = ""
    @State private var warning: String?
    @State private var editing: SamplePoint?
    @State private var shareItems: [Any] = []
    @State private var showShare = false
    @State private var floorPlan: UIImage?
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var pinchStart: (zoom: CGFloat, pan: CGSize)?
    @State private var dragStartPan: CGSize?

    private var survey: Survey? { store.survey(surveyID) }

    private var aspect: Double {
        guard let floorPlan, floorPlan.size.height > 0 else { return 4.0 / 3.0 }
        return floorPlan.size.width / floorPlan.size.height
    }

    var body: some View {
        if let survey {
            VStack(spacing: 0) {
                controls(survey)
                GeometryReader { geo in
                    canvas(survey, in: geo.size)
                }
                .background(Color(.secondarySystemBackground))
                bottomBar(survey)
            }
            .navigationTitle(survey.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { exportImage(survey) } label: { Label("Share heatmap image", systemImage: "photo") }
                        Button { exportCSV(survey) } label: { Label("Share data (CSV)", systemImage: "tablecells") }
                        Divider()
                        Button(role: .destructive) {
                            store.mutate(surveyID) { $0.points.removeAll() }
                        } label: { Label("Clear all points", systemImage: "trash") }
                    } label: { Image(systemName: "square.and.arrow.up") }
                    .disabled(survey.points.isEmpty)
                }
            }
            .task(id: survey.floorPlanFile) {
                floorPlan = store.floorPlanImage(for: survey)
                zoom = 1
                pan = .zero
            }
            .sheet(item: $editing) { point in
                PointEditorSheet(point: point,
                                 onSave: { updated in
                                     store.mutate(surveyID) { s in
                                         if let i = s.points.firstIndex(where: { $0.id == updated.id }) { s.points[i] = updated }
                                     }
                                 },
                                 onDelete: {
                                     store.mutate(surveyID) { $0.points.removeAll { $0.id == point.id } }
                                 })
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showShare) { ShareSheet(items: shareItems) }
            .alert("Heads up", isPresented: Binding(get: { warning != nil }, set: { if !$0 { warning = nil } })) {
                Button("OK") {}
            } message: { Text(warning ?? "") }
        } else {
            ContentUnavailableView("Survey not found", systemImage: "questionmark.folder")
        }
    }

    // MARK: - Pieces

    private func controls(_ survey: Survey) -> some View {
        VStack(spacing: 8) {
            Picker("Metric", selection: $metric) {
                ForEach(Metric.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(metric.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Toggle("Heatmap", isOn: $showHeatmap).fixedSize()
                Slider(value: $opacity, in: 0.2...1).disabled(!showHeatmap)
            }
            LegendBar(metric: metric, range: metric.range(for: survey.points))
        }
        .padding(.horizontal).padding(.vertical, 8)
    }

    @ViewBuilder
    private func canvas(_ survey: Survey, in available: CGSize) -> some View {
        let t = mapTransform(in: available)
        let range = metric.range(for: survey.points)

        ZStack(alignment: .topLeading) {
            // Floor plan and heatmap are scaled; dots stay finger-sized and just move apart.
            Group {
                if let floorPlan {
                    Image(uiImage: floorPlan).resizable()
                } else {
                    Color.white
                }
            }
            .frame(width: t.fit.width, height: t.fit.height)
            .scaleEffect(t.zoom, anchor: .topLeading)
            .offset(t.contentOffset)

            if showHeatmap, let range,
               let cg = HeatmapRenderer.render(points: survey.points, metric: metric, range: range, aspect: aspect) {
                Image(decorative: cg, scale: 1)
                    .resizable().interpolation(.high)
                    .frame(width: t.fit.width, height: t.fit.height)
                    .scaleEffect(t.zoom, anchor: .topLeading)
                    .offset(t.contentOffset)
                    .opacity(opacity)
                    .allowsHitTesting(false)
            }

            ForEach(survey.points) { p in
                PointMarker(point: p, metric: metric, range: range)
                    .position(t.screen(p.x, p.y))
                    .onTapGesture { editing = p }
            }

            if let placing {
                Circle().strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Circle().fill(Color.accentColor.opacity(0.25)))
                    .frame(width: 30, height: 30)
                    .position(t.screen(placing.x, placing.y))
                    .allowsHitTesting(false)
            }
        }
        .frame(width: available.width, height: available.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .clipped()
        .onTapGesture { location in
            guard !measuring, let spot = t.normalized(location) else { return }
            placing = spot
        }
        .gesture(zoomGesture(in: available))
        .overlay(alignment: .topTrailing) {
            if zoom > 1.01 { resetZoomButton }
        }
    }

    private var resetZoomButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                zoom = 1
                pan = .zero
            }
        } label: {
            Label(String(format: "%.1f×", zoom), systemImage: "arrow.down.right.and.arrow.up.left")
                .font(.footnote.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .background(.regularMaterial, in: Capsule())
        .padding(10)
    }

    private func mapTransform(in available: CGSize) -> MapTransform {
        let fit = fittedSize(aspect: aspect, in: available)
        let origin = CGPoint(x: (available.width - fit.width) / 2, y: (available.height - fit.height) / 2)
        let clamped = MapTransform.clamp(pan: pan, zoom: zoom, fit: fit, origin: origin, available: available)
        return MapTransform(fit: fit, origin: origin, zoom: zoom, pan: clamped)
    }

    /// Pinch to zoom around the fingers (1×–6×); drag with one finger to pan.
    private func zoomGesture(in available: CGSize) -> some Gesture {
        let magnify = MagnifyGesture()
            .onChanged { value in
                let t = mapTransform(in: available)
                if pinchStart == nil { pinchStart = (zoom, t.pan) }
                guard let start = pinchStart else { return }
                let anchor = CGPoint(x: value.startAnchor.x * available.width,
                                     y: value.startAnchor.y * available.height)
                // The plan point under the fingers when the pinch began stays under them.
                let cx = (anchor.x - t.origin.x - start.pan.width) / start.zoom
                let cy = (anchor.y - t.origin.y - start.pan.height) / start.zoom
                let z = min(max(start.zoom * value.magnification, 1), 6)
                zoom = z
                pan = CGSize(width: anchor.x - t.origin.x - cx * z,
                             height: anchor.y - t.origin.y - cy * z)
            }
            .onEnded { _ in
                pinchStart = nil
                dragStartPan = nil
                pan = mapTransform(in: available).pan
            }

        let drag = DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard pinchStart == nil else { return }
                if dragStartPan == nil { dragStartPan = mapTransform(in: available).pan }
                guard let start = dragStartPan else { return }
                pan = CGSize(width: start.width + value.translation.width,
                             height: start.height + value.translation.height)
            }
            .onEnded { _ in
                dragStartPan = nil
                pan = mapTransform(in: available).pan
            }

        return magnify.simultaneously(with: drag)
    }

    private func bottomBar(_ survey: Survey) -> some View {
        VStack(spacing: 6) {
            if measuring {
                HStack { ProgressView(); Text(status).font(.subheadline).monospacedDigit() }
                Text("Hold the phone still at chest height until it finishes.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if placing == nil {
                Text(survey.points.isEmpty ? "Tap the map where you're standing, then measure."
                                           : "Tap the map to place a point · tap a dot to edit it · pinch to zoom.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button {
                Task { await measure() }
            } label: {
                Label(measuring ? "Measuring…" : "Measure here", systemImage: "wifi")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(placing == nil || measuring)
        }
        .padding().background(.bar)
    }

    // MARK: - Actions

    private func measure() async {
        guard let spot = placing else { return }
        measuring = true
        defer { measuring = false; status = "" }

        let result = await NetworkProbe.run { status = $0 }

        guard result.onWiFi else {
            warning = "You don't appear to be connected over Wi-Fi, so this reading wasn't saved. Connect to the network you want to map and try again."
            return
        }
        guard result.hasAnyMeasurement else {
            warning = "Measurement failed.\n" + result.errors.joined(separator: "\n")
            return
        }

        let point = SamplePoint(x: spot.x, y: spot.y,
                                downloadMbps: result.downloadMbps,
                                latencyMs: result.latencyMs,
                                jitterMs: result.jitterMs,
                                routerLatencyMs: result.routerLatencyMs,
                                routerJitterMs: result.routerJitterMs,
                                packetLossPct: result.packetLossPct,
                                ssid: result.ssid, bssid: result.bssid,
                                routerAddress: result.routerAddress)
        store.mutate(surveyID) { $0.points.append(point) }
        placing = nil
        if !result.errors.isEmpty { warning = "Saved, but part of the test failed:\n" + result.errors.joined(separator: "\n") }
    }

    private func exportImage(_ survey: Survey) {
        guard let floorPlan else { return }
        let range = metric.range(for: survey.points)
        let cg = range.flatMap {
            HeatmapRenderer.render(points: survey.points, metric: metric, range: $0, aspect: aspect, width: 500)
        }
        let image = HeatmapExporter.composite(floorPlan: floorPlan, heatmap: showHeatmap ? cg : nil,
                                              opacity: opacity, points: survey.points,
                                              metric: metric, range: range)
        shareItems = [image]
        showShare = true
    }

    private func exportCSV(_ survey: Survey) {
        guard let url = HeatmapExporter.writeCSV(for: survey) else { return }
        shareItems = [url]
        showShare = true
    }

    private func fittedSize(aspect: Double, in size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        let byWidth = CGSize(width: size.width, height: size.width / aspect)
        return byWidth.height <= size.height ? byWidth : CGSize(width: size.height * aspect, height: size.height)
    }
}

// MARK: - Map zoom/pan maths

/// Maps between plan coordinates (0...1) and the canvas on screen at the current zoom/pan.
struct MapTransform {
    var fit: CGSize       // plan size at 1×
    var origin: CGPoint   // top-left of the plan at 1× (centred in the canvas)
    var zoom: CGFloat
    var pan: CGSize       // already clamped

    var contentOffset: CGSize {
        CGSize(width: origin.x + pan.width, height: origin.y + pan.height)
    }

    func screen(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: origin.x + CGFloat(x) * fit.width * zoom + pan.width,
                y: origin.y + CGFloat(y) * fit.height * zoom + pan.height)
    }

    /// nil if the point is outside the plan.
    func normalized(_ p: CGPoint) -> CGPoint? {
        guard fit.width > 0, fit.height > 0, zoom > 0 else { return nil }
        let x = (p.x - origin.x - pan.width) / zoom / fit.width
        let y = (p.y - origin.y - pan.height) / zoom / fit.height
        guard x >= 0, x <= 1, y >= 0, y <= 1 else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// Keeps the zoomed plan covering the canvas (or centred when it's smaller than the canvas).
    static func clamp(pan: CGSize, zoom: CGFloat, fit: CGSize, origin: CGPoint, available: CGSize) -> CGSize {
        func axis(_ p: CGFloat, _ size: CGFloat, _ o: CGFloat, _ avail: CGFloat) -> CGFloat {
            let w = size * zoom
            if w <= avail { return (avail - w) / 2 - o }
            return min(max(p, avail - w - o), -o)
        }
        return CGSize(width: axis(pan.width, fit.width, origin.x, available.width),
                      height: axis(pan.height, fit.height, origin.y, available.height))
    }
}

// MARK: - Subviews

struct PointMarker: View {
    let point: SamplePoint
    let metric: Metric
    let range: ClosedRange<Double>?

    var body: some View {
        let value = metric.value(point)
        let color: Color = {
            guard let value, let range else { return .gray }
            return ColorRamp.color(metric.normalized(value, in: range))
        }()
        VStack(spacing: 1) {
            Circle().fill(color)
                .overlay(Circle().stroke(.white, lineWidth: 2))
                .shadow(radius: 1.5)
                .frame(width: 16, height: 16)
            if let value {
                Text(metric.format(value))
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 3)
                    .background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(.black)
            }
        }
        .padding(8)               // bigger tap target
        .contentShape(Rectangle())
    }
}

struct LegendBar: View {
    let metric: Metric
    let range: ClosedRange<Double>?

    var body: some View {
        HStack(spacing: 6) {
            Text(label(low: true)).font(.caption2).monospacedDigit()
            LinearGradient(gradient: ColorRamp.gradient, startPoint: .leading, endPoint: .trailing)
                .frame(height: 8).clipShape(Capsule())
            Text(label(low: false)).font(.caption2).monospacedDigit()
        }
        .foregroundStyle(.secondary)
    }

    /// Left end of the bar is "worst" (red), right end is "best" (green).
    private func label(low: Bool) -> String {
        guard let range else { return low ? "worse" : "better" }
        let worstIsLow = metric.higherIsBetter
        let v = (low == worstIsLow) ? range.lowerBound : range.upperBound
        return metric.format(v)
    }
}

struct PointEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var point: SamplePoint
    var onSave: (SamplePoint) -> Void
    var onDelete: () -> Void
    @State private var rssiText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Measurements") {
                    row("Download", point.downloadMbps.map { Metric.download.format($0) })
                    row("Router ping", point.routerLatencyMs.map { Metric.router.format($0) })
                    row("Router jitter", point.routerJitterMs.map { String(format: "%.1f ms", $0) })
                    row("Packet loss", point.packetLossPct.map { String(format: "%.1f%%", $0) })
                    row("Internet ping", point.latencyMs.map { Metric.latency.format($0) })
                    row("Internet jitter", point.jitterMs.map { String(format: "%.1f ms", $0) })
                    row("Network", point.ssid)
                    row("Access point", point.bssid)
                    row("Router", point.routerAddress)
                    row("Time", point.date.formatted(date: .abbreviated, time: .shortened))
                }
                Section {
                    TextField("e.g. -62", text: $rssiText).keyboardType(.numbersAndPunctuation)
                } header: {
                    Text("Signal strength (dBm), optional")
                } footer: {
                    Text("iOS can't report this itself. Enter a reading from another device or tool if you want the RSSI map.")
                }
                Section { Button("Delete point", role: .destructive) { onDelete(); dismiss() } }
            }
            .navigationTitle("Point")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var updated = point
                        updated.rssi = Double(rssiText.replacingOccurrences(of: ",", with: "."))
                        onSave(updated)
                        dismiss()
                    }
                }
            }
            .onAppear { rssiText = point.rssi.map { String(format: "%.0f", $0) } ?? "" }
        }
    }

    private func row(_ title: String, _ value: String?) -> some View {
        LabeledContent(title) { Text(value ?? "—").foregroundStyle(.secondary).textSelection(.enabled) }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
