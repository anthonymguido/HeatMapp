import ARKit
import SwiftUI
import simd

// MARK: - Before the scan: checklist

struct ScanGuideIntroView: View {
    static let skipKey = "skipScanIntro"
    @AppStorage(ScanGuideIntroView.skipKey) private var skipIntro = false
    var onStart: () -> Void
    var onCancel: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("A few tips so the scan finishes cleanly:")
                        .font(.title3.weight(.semibold))
                    tip("lightbulb.fill", .yellow, "Turn the lights on",
                        "LiDAR works in the dark, but the camera needs light to keep track of where you are.")
                    tip("door.left.hand.open", .brown, "Open the doors between rooms",
                        "You'll walk through each doorway with the phone, so the rooms join up into one plan.")
                    tip("iphone", .blue, "Hold the phone upright at chest height",
                        "Point it at the walls, not your feet. Keep the camera uncovered.")
                    tip("figure.walk", .green, "Move slowly",
                        "Slow, smooth turns work best. The app tells you if you're going too fast.")
                    tip("flag.fill", .red, "Start in a corner of the main room",
                        "Follow the steps at the bottom of the screen. They guide you room by room.")
                    Toggle("Don't show these tips again", isOn: $skipIntro)
                        .padding(.top, 4)
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: onStart) {
                    Label("Start scanning", systemImage: "viewfinder").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding()
                .background(.bar)
            }
            .navigationTitle("Scan your floor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) } }
        }
    }

    private func tip(_ icon: String, _ color: Color, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - During the scan: step script

enum ScanStep: Int, CaseIterable {
    case lookAround = 1, floorCeiling, nextRoom, finish

    var icon: String {
        switch self {
        case .lookAround: return "arrow.clockwise"
        case .floorCeiling: return "arrow.up.and.down"
        case .nextRoom: return "arrow.up"
        case .finish: return "flag.checkered"
        }
    }

    var title: String {
        switch self {
        case .lookAround: return "Sweep the walls"
        case .floorCeiling: return "Tilt down, then up"
        case .nextRoom: return "Walk to the next room"
        case .finish: return "Finish the scan"
        }
    }

    var detail: String {
        switch self {
        case .lookAround:
            return "Stand near a corner and turn slowly all the way around, so every wall of this room gets outlined."
        case .floorCeiling:
            return "Tilt down to see where the walls meet the floor, then up to the ceiling edges."
        case .nextRoom:
            return "Walk slowly through a doorway with the phone pointed ahead. Keep it pointed at the walls as you go."
        case .finish:
            return "All rooms covered? Tap Finish scan. The app then builds your floor plan."
        }
    }
}

struct CoachMessage: Equatable {
    var text: String
    var icon: String
}

/// Holds the guide's progress and turns the camera's motion into simple coaching messages.
@MainActor
final class ScanCoach: ObservableObject {
    @Published var step: ScanStep = .lookAround
    @Published var room = 1
    @Published private(set) var warning: CoachMessage?

    private var lastPosition: SIMD3<Float>?
    private var lastForward: SIMD3<Float>?
    private var lastTime: TimeInterval?
    private var fastScore = 0

    func reset() {
        step = .lookAround
        room = 1
        warning = nil
        lastPosition = nil; lastForward = nil; lastTime = nil
        fastScore = 0
    }

    func next() {
        switch step {
        case .lookAround: step = .floorCeiling
        case .floorCeiling: step = .nextRoom
        case .nextRoom, .finish: step = .finish
        }
    }

    func back() {
        switch step {
        case .lookAround: break
        case .floorCeiling: step = .lookAround
        case .nextRoom: step = .floorCeiling
        case .finish: step = .nextRoom
        }
    }

    func enteredNextRoom() {
        room += 1
        step = .lookAround
    }

    /// Called about 5 times a second while scanning.
    func tick(session: ARSession?) {
        guard let frame = session?.currentFrame else { return }
        let state = frame.camera.trackingState

        if case .limited(let reason) = state {
            switch reason {
            case .excessiveMotion:
                warning = CoachMessage(text: "Slow down. Move the phone more gently.", icon: "tortoise.fill")
            case .insufficientFeatures:
                warning = CoachMessage(text: "Can't see enough detail. Turn on a light or point at walls and furniture.", icon: "lightbulb.fill")
            case .initializing:
                warning = CoachMessage(text: "Move the phone slowly from side to side to get started.", icon: "arrow.left.and.right")
            case .relocalizing:
                warning = CoachMessage(text: "Point back at an area you already scanned.", icon: "arrow.uturn.backward")
            default:
                warning = CoachMessage(text: "Move the phone slowly.", icon: "tortoise.fill")
            }
            lastTime = nil
            return
        }
        guard case .normal = state else {
            warning = CoachMessage(text: "Getting the camera ready…", icon: "camera")
            lastTime = nil
            return
        }

        // Normal tracking: warn if turning or walking too fast.
        let t = frame.camera.transform
        let position = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let forward = -SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        defer { lastPosition = position; lastForward = forward; lastTime = frame.timestamp }

        guard let lp = lastPosition, let lf = lastForward, let lt = lastTime else {
            warning = nil
            return
        }
        let dt = frame.timestamp - lt
        guard dt > 0.05 else { return }

        let cosAngle = max(-1, min(1, simd_dot(simd_normalize(forward), simd_normalize(lf))))
        let turnDegPerSec = Double(acos(cosAngle)) * 180 / .pi / dt
        let walkMPerSec = Double(simd_distance(position, lp)) / dt

        let tooFast = turnDegPerSec > 70 || walkMPerSec > 1.2
        fastScore = tooFast ? min(fastScore + 1, 4) : max(fastScore - 1, 0)
        warning = fastScore >= 2
            ? CoachMessage(text: "Slow down. Turn and walk more slowly.", icon: "tortoise.fill")
            : nil
    }
}

// MARK: - Overlay pieces

struct ScanStepCard: View {
    @ObservedObject var coach: ScanCoach
    var onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: coach.step.icon)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.yellow)
                    .symbolEffect(.pulse, options: .repeating)
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Room \(coach.room) · Step \(coach.step.rawValue) of \(ScanStep.allCases.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    Text(coach.step.title).font(.headline)
                    Text(coach.step.detail).font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                if coach.step != .lookAround {
                    Button("Back") { coach.back() }
                        .buttonStyle(.bordered)
                }
                Spacer()
                switch coach.step {
                case .lookAround, .floorCeiling:
                    Button("Next") { coach.next() }
                        .buttonStyle(.borderedProminent)
                case .nextRoom:
                    Button("No more rooms") { coach.next() }
                        .buttonStyle(.bordered)
                    Button("I'm in the next room") { coach.enteredNextRoom() }
                        .buttonStyle(.borderedProminent)
                case .finish:
                    Button("Finish scan", action: onFinish)
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                }
            }
        }
        .foregroundStyle(.white)
        .padding()
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 18))
        .environment(\.colorScheme, .dark)
    }
}

struct CoachBanner: View {
    let message: CoachMessage

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: message.icon)
                .font(.title3.weight(.bold))
                .symbolEffect(.pulse, options: .repeating)
            Text(message.text)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
