import SwiftUI
import AVFoundation
import TennisCore

/// In-session recording screen.
/// Draws a static six-zone court diagram; the entire court rect is tappable.
/// On each tap: calls ZoneClassifier.classify(point:in:) with the tap location
/// and diagram rect, then passes the zone string to viewModel.record(zone:).
/// No zone math in this file beyond the ZoneClassifier call (AC30).
///
/// Phase-2 camera param (AC26 / FR-V3 / D-2):
/// `cameraVM` is a **trailing optional defaulting to `nil`** — the existing
/// `RecordSessionView(matchClient:matchID:path:)` call site compiles unchanged.
/// When nil → Phase-1 behavior exactly (no camera UI).
/// When non-nil → auto-starts recording on appear; shows a preview thumbnail
/// and REC badge; End Match stops recording before the backend post.
struct RecordSessionView: View {
    let matchClient: MatchClient
    let matchID: String
    @Binding var path: [Route]
    let cameraVM: CameraSessionViewModel?

    @State private var viewModel: RecordSessionViewModel

    init(matchClient: MatchClient, matchID: String, path: Binding<[Route]>, cameraVM: CameraSessionViewModel? = nil) {
        self.matchClient = matchClient
        self.matchID = matchID
        self._path = path
        self.cameraVM = cameraVM
        _viewModel = State(initialValue: RecordSessionViewModel(client: matchClient, matchID: matchID))
    }

    var body: some View {
        VStack(spacing: 16) {
            // Camera preview thumbnail + REC badge (Phase 2, non-nil cameraVM only)
            if let cam = cameraVM {
                CameraRecordingBadgeView(cameraVM: cam)
                    .padding(.horizontal)
            }

            // Shot counter
            HStack {
                Label("\(viewModel.count) shots", systemImage: "tennisball")
                    .font(.headline)
                Spacer()
                Button("End Match", role: .destructive) {
                    endMatch()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding(.horizontal)

            // Court diagram — only this rect is tappable
            CourtDiagramView { zone in
                Task { await viewModel.record(zone: zone) }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(0.6, contentMode: .fit)
            .padding(.horizontal)

            // Last 5 shots
            ShotHistoryView(shots: viewModel.lastN(5))
                .padding(.horizontal)

            if let error = viewModel.endMatchError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            Spacer()
        }
        .navigationTitle("Recording")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: viewModel.endedMatch?.id) { _, newID in
            if let id = newID {
                // Replace entire path: pop session, push summary
                path = [.summary(id)]
            }
        }
        .task {
            // OQ-6: auto-start recording on entry when cameraVM is present.
            if let cam = cameraVM {
                try? cam.startRecording(matchId: matchID)
            }
        }
    }

    private func endMatch() {
        Task {
            // AC26 / D-2 ordering: stop recording BEFORE the backend endMatch post.
            if let cam = cameraVM {
                try? await cam.stopRecording()
            }
            await viewModel.endMatch()
        }
    }
}

// MARK: - Camera recording badge (Phase 2)

/// Shown inside RecordSessionView only when cameraVM != nil.
/// Displays a small live-preview thumbnail and a pulsing "● REC" badge while
/// the camera state is `.recording`.
private struct CameraRecordingBadgeView: View {
    let cameraVM: CameraSessionViewModel

    var body: some View {
        HStack(spacing: 8) {
            // Inline preview thumbnail
            CameraThumbView(previewLayer: cameraVM.camera.previewLayer)
                .frame(width: 80, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                )

            if cameraVM.state == .recording {
                Label("REC", systemImage: "circle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.red)
            }

            Spacer()
        }
    }
}

/// A tiny UIViewRepresentable that renders a preview layer in a SwiftUI frame.
private struct CameraThumbView: UIViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer

    func makeUIView(context: Context) -> ThumbUIView {
        let view = ThumbUIView()
        view.attach(previewLayer)
        return view
    }

    func updateUIView(_ uiView: ThumbUIView, context: Context) {
        uiView.setNeedsLayout()
    }
}

private final class ThumbUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    func attach(_ previewLayer: AVCaptureVideoPreviewLayer) {
        guard let layer = self.layer as? AVCaptureVideoPreviewLayer else { return }
        layer.session = previewLayer.session
        layer.videoGravity = .resizeAspectFill
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.frame = bounds
    }
}

// MARK: - Court diagram

/// Draws a static six-zone court grid. The entire rect is tappable.
/// Zone mapping (net at top, baseline at bottom):
///   front_court_left | front_court_right  (top third)
///   baseline_left    | baseline_right     (middle third)
///   out_left         | out_right          (bottom third)
private struct CourtDiagramView: View {
    let onTap: (String) -> Void

    var body: some View {
        GeometryReader { geo in
            let rect = CGRect(origin: .zero, size: geo.size)
            ZStack {
                courtBackground(in: rect)
                courtGrid(in: rect)
                zoneLabels(in: rect)
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture()
                    .onEnded { value in
                        let zone = ZoneClassifier.classify(point: value.location, in: rect)
                        onTap(zone)
                    }
            )
        }
    }

    @ViewBuilder
    private func courtBackground(in rect: CGRect) -> some View {
        Rectangle()
            .fill(Color(.systemGreen).opacity(0.15))
            .overlay(Rectangle().stroke(Color.primary.opacity(0.5), lineWidth: 1))
    }

    @ViewBuilder
    private func courtGrid(in rect: CGRect) -> some View {
        let w = rect.width
        let h = rect.height

        // Net line (horizontal, top of diagram)
        Path { p in
            p.move(to:    CGPoint(x: 0,     y: h / 3))
            p.addLine(to: CGPoint(x: w,     y: h / 3))
        }
        .stroke(Color.primary.opacity(0.4), lineWidth: 1)

        Path { p in
            p.move(to:    CGPoint(x: 0,     y: 2 * h / 3))
            p.addLine(to: CGPoint(x: w,     y: 2 * h / 3))
        }
        .stroke(Color.primary.opacity(0.4), lineWidth: 1)

        // Centre line (vertical)
        Path { p in
            p.move(to:    CGPoint(x: w / 2, y: 0))
            p.addLine(to: CGPoint(x: w / 2, y: h))
        }
        .stroke(Color.primary.opacity(0.4), lineWidth: 1)

        // Net indicator at the very top edge
        Path { p in
            p.move(to:    CGPoint(x: 0,     y: 2))
            p.addLine(to: CGPoint(x: w,     y: 2))
        }
        .stroke(Color.primary, lineWidth: 3)
    }

    @ViewBuilder
    private func zoneLabels(in rect: CGRect) -> some View {
        let w = rect.width
        let h = rect.height

        Group {
            label("NET",      at: CGPoint(x: w / 2, y: 10))
            label("Front L",  at: CGPoint(x: w / 4, y: h / 6))
            label("Front R",  at: CGPoint(x: 3 * w / 4, y: h / 6))
            label("Base L",   at: CGPoint(x: w / 4, y: h / 2))
            label("Base R",   at: CGPoint(x: 3 * w / 4, y: h / 2))
            label("Out L",    at: CGPoint(x: w / 4, y: 5 * h / 6))
            label("Out R",    at: CGPoint(x: 3 * w / 4, y: 5 * h / 6))
        }
    }

    private func label(_ text: String, at point: CGPoint) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .position(point)
    }
}

// MARK: - Shot history

private struct ShotHistoryView: View {
    let shots: [LocalShot]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Last shots")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if shots.isEmpty {
                Text("Tap the court to record a shot")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(shots) { shot in
                    HStack(spacing: 6) {
                        statusIcon(shot.status)
                        Text(shot.zone.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(.caption)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func statusIcon(_ status: ShotStatus) -> some View {
        switch status {
        case .pending:
            ProgressView().scaleEffect(0.6)
        case .confirmed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
        }
    }
}
