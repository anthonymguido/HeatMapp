import ARKit
import RoomPlan
import SwiftUI

/// Owns the RoomPlan scanner view and receives its results.
final class RoomScanController: NSObject, ObservableObject, RoomCaptureViewDelegate {
    enum Phase {
        case scanning
        case processing
        case review(CapturedRoom)
        case failed(String)
    }

    @Published var phase: Phase = .scanning
    /// Bumped to throw away the scanner view and start a fresh scan.
    @Published var generation = 0
    private weak var captureView: RoomCaptureView?

    override init() { super.init() }

    // RoomCaptureViewDelegate inherits NSCoding; this object is never archived.
    nonisolated init?(coder: NSCoder) { return nil }
    nonisolated func encode(with coder: NSCoder) {}

    @MainActor func makeView() -> RoomCaptureView {
        let view = RoomCaptureView(frame: .zero)
        view.delegate = self
        view.captureSession.run(configuration: RoomCaptureSession.Configuration())
        captureView = view
        return view
    }

    @MainActor var arSession: ARSession? { captureView?.captureSession.arSession }

    @MainActor func finish() {
        phase = .processing
        captureView?.captureSession.stop()
    }

    @MainActor func rescan() {
        captureView?.captureSession.stop()
        phase = .scanning
        generation += 1
    }

    @MainActor func cancel() {
        captureView?.captureSession.stop()
    }

    nonisolated func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        if let error {
            let message = error.localizedDescription
            Task { @MainActor in self.phase = .failed(message) }
            return false
        }
        return true
    }

    nonisolated func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        let message = error?.localizedDescription
        Task { @MainActor in
            if let message {
                self.phase = .failed(message)
            } else {
                self.phase = .review(processedResult)
            }
        }
    }
}

struct RoomCaptureRepresentable: UIViewRepresentable {
    let controller: RoomScanController

    func makeUIView(context: Context) -> RoomCaptureView { controller.makeView() }
    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
    static func dismantleUIView(_ uiView: RoomCaptureView, coordinator: ()) {
        uiView.captureSession.stop()
    }
}

/// Full-screen LiDAR scan: tips → guided scan → review → floor plan image.
struct RoomScanView: View {
    var onImage: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = RoomScanController()
    @StateObject private var coach = ScanCoach()
    @State private var introDone: Bool
    private let ticker = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    init(onImage: @escaping (UIImage) -> Void) {
        self.onImage = onImage
        _introDone = State(initialValue: UserDefaults.standard.bool(forKey: ScanGuideIntroView.skipKey))
    }

    private var isScanning: Bool {
        if case .scanning = controller.phase { return true }
        return false
    }

    var body: some View {
        if !introDone {
            ScanGuideIntroView(onStart: { introDone = true }, onCancel: { dismiss() })
        } else {
            ZStack {
                RoomCaptureRepresentable(controller: controller)
                    .id(controller.generation)
                    .ignoresSafeArea()

                VStack(spacing: 10) {
                    topBar
                    if isScanning, let warning = coach.warning {
                        CoachBanner(message: warning)
                    }
                    Spacer()
                    bottomCard
                }
                .padding()
                .animation(.easeInOut(duration: 0.25), value: coach.warning)
            }
            .onReceive(ticker) { _ in
                if isScanning { coach.tick(session: controller.arSession) }
            }
        }
    }

    private var topBar: some View {
        HStack {
            Button("Cancel") {
                controller.cancel()
                dismiss()
            }
            .buttonStyle(.bordered)
            Spacer()
            if isScanning {
                Label(String(format: "%d:%02d", coach.elapsedSeconds / 60, coach.elapsedSeconds % 60),
                      systemImage: "timer")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.black.opacity(0.5), in: Capsule())
                Spacer()
                Button("Done") { controller.finish() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var bottomCard: some View {
        switch controller.phase {
        case .scanning:
            ScanStepCard(coach: coach) { controller.finish() }

        case .processing:
            HStack(spacing: 10) {
                ProgressView().tint(.white)
                Text("Building your floor plan…").font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding()
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 18))

        case .review(let room):
            reviewCard(room)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Label("The scan didn't work", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline).foregroundStyle(.orange)
                Text(message).font(.subheadline)
                HStack {
                    Spacer()
                    Button("Try again") { restart() }.buttonStyle(.borderedProminent)
                }
            }
            .foregroundStyle(.white)
            .padding()
            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 18))
            .environment(\.colorScheme, .dark)
        }
    }

    private func reviewCard(_ room: CapturedRoom) -> some View {
        let incomplete = room.walls.count < 3
        return VStack(alignment: .leading, spacing: 12) {
            if incomplete {
                Label("The scan looks incomplete", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline).foregroundStyle(.orange)
                Text("Only \(room.walls.count) wall\(room.walls.count == 1 ? "" : "s") found. Scanning again, slowly and with the lights on, usually helps.")
                    .font(.subheadline)
            } else {
                Label("Scan complete", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(.green)
                Text("Found \(room.walls.count) walls, \(room.doors.count) doors and \(room.windows.count) windows.")
                    .font(.subheadline)
            }
            HStack {
                Button("Rescan") { restart() }.buttonStyle(.bordered)
                Spacer()
                Button(incomplete ? "Use anyway" : "Use this scan") {
                    onImage(FloorPlanDrawer.image(from: room))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .foregroundStyle(.white)
        .padding()
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 18))
        .environment(\.colorScheme, .dark)
    }

    private func restart() {
        coach.reset()
        controller.rescan()
    }
}
