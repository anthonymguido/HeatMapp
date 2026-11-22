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
            .task(id: survey.floorPlanFile) { floorPlan = store.floorPlanImage(for: survey) }
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
        let fit = fittedSize(aspect: aspect, in: available)
        let range = metric.range(for: survey.points)

        ZStack(alignment: .topLeading) {
            if let floorPlan {
                Image(uiImage: floorPlan).resizable().frame(width: fit.width, height: fit.height)
            } else {
                Color.white.frame(width: fit.width, height: fit.height)
            }

            if showHeatmap, let range,
               let cg = HeatmapRenderer.render(points: survey.points, metric: metric, range: range, aspect: aspect) {
                Image(decorative: cg, scale: 1)
                    .resizable().interpolation(.high)
                    .frame(width: fit.width, height: fit.height)
                    .opacity(opacity)
                    .allowsHitTesting(false)
            }

            ForEach(survey.points) { p in
                PointMarker(point: p, metric: metric, range: range)
                    .position(x: p.x * fit.width, y: p.y * fit.height)
                    .onTapGesture { editing = p }
            }

            if let placing {
                Circle().strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Circle().fill(Color.accentColor.opacity(0.25)))
                    .frame(width: 30, height: 30)
                    .position(x: placing.x * fit.width, y: placing.y * fit.height)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: fit.width, height: fit.height)
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { location in
            guard !measuring else { return }
            placing = CGPoint(x: min(max(location.x / fit.width, 0), 1),
                              y: min(max(location.y / fit.height, 0), 1))
        }
        .frame(width: available.width, height: available.height)
    }

    private func bottomBar(_ survey: Survey) -> some View {
        VStack(spacing: 6) {
            if measuring {
                HStack { ProgressView(); Text(status).font(.subheadline) }
            } else if placing == nil {
                Text(survey.points.isEmpty ? "Tap the map where you're standing, then measure."
                                           : "Tap the map to place a new point · tap a dot to edit it.")
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
        guard result.latencyMs != nil || result.downloadMbps != nil else {
            warning = "Measurement failed.\n" + result.errors.joined(separator: "\n")
            return
        }

        let point = SamplePoint(x: spot.x, y: spot.y,
                                downloadMbps: result.downloadMbps,
                                latencyMs: result.latencyMs,
                                jitterMs: result.jitterMs,
                                ssid: result.ssid, bssid: result.bssid)
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
                    row("Latency", point.latencyMs.map { Metric.latency.format($0) })
                    row("Jitter", point.jitterMs.map { String(format: "%.1f ms", $0) })
                    row("Network", point.ssid)
                    row("Access point", point.bssid)
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
