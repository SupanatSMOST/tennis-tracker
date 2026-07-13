import SwiftUI
import AVFoundation
import TennisCore

// MARK: - CameraSetupView (FR-V1)

/// FR-V1: Live camera preview + corner-bracket guide overlay.
///
/// Thin reader — no math, no calibration logic.  All state and camera I/O flow
/// through `cameraVM` (injected from `MatchListView`).
///
/// On appear: `await cameraVM.startPreview()` — starts the AVFoundation session
/// and populates the preview layer.
///
/// "Next" appends `.cornerTap(matchID)` to the navigation path, advancing the
/// user to the 4-corner tap screen.
struct CameraSetupView: View {
    let cameraVM: CameraSessionViewModel
    let matchID: String
    @Binding var path: [Route]

    var body: some View {
        ZStack {
            // Live camera preview
            CameraPreviewView(previewLayer: cameraVM.camera.previewLayer)
                .ignoresSafeArea()

            // Corner-bracket guide overlay
            CornerBracketOverlay()
                .ignoresSafeArea()

            // Framing guidance + Next button pinned to the bottom
            VStack {
                Spacer()
                VStack(spacing: 16) {
                    Text("Frame the court so all 4 corners are visible, then tap Next")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 2)
                        .padding(.horizontal, 24)

                    Button("Next") {
                        path.append(.cornerTap(matchID))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
                    .padding(.bottom, 40)
                }
            }
        }
        .navigationTitle("Align Court")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await cameraVM.startPreview()
        }
    }
}

// MARK: - CameraPreviewView

/// UIViewRepresentable that hosts an `AVCaptureVideoPreviewLayer`.
///
/// The layer is sourced directly from `CameraCapturing.previewLayer` — no
/// session wiring in this view (that lives in `CameraService`).
private struct CameraPreviewView: UIViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.attach(previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        // ponytail: no per-update re-attachment needed — the layer reference is
        // stable for the lifetime of the CameraSessionViewModel (owned by MatchListView
        // @State). Upgrade path: detach/re-attach here if the VM can be swapped.
        uiView.setNeedsLayout()
    }
}

private final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    func attach(_ previewLayer: AVCaptureVideoPreviewLayer) {
        guard let layer = self.layer as? AVCaptureVideoPreviewLayer else { return }
        // Mirror the session from the injected layer to this view's own layer.
        layer.session = previewLayer.session
        layer.videoGravity = previewLayer.videoGravity
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.frame = bounds
    }
}

// MARK: - CornerBracketOverlay

/// Four L-shaped corner brackets drawn with Canvas to frame the court guide.
private struct CornerBracketOverlay: View {
    private let bracketLength: CGFloat = 36
    private let bracketWidth: CGFloat = 4
    private let inset: CGFloat = 40
    private let color: Color = .white.opacity(0.85)

    var body: some View {
        Canvas { context, size in
            let tl = CGPoint(x: inset, y: inset)
            let tr = CGPoint(x: size.width - inset, y: inset)
            let bl = CGPoint(x: inset, y: size.height - inset)
            let br = CGPoint(x: size.width - inset, y: size.height - inset)

            drawBracket(context: context, corner: tl, hDir: 1, vDir: 1)
            drawBracket(context: context, corner: tr, hDir: -1, vDir: 1)
            drawBracket(context: context, corner: bl, hDir: 1, vDir: -1)
            drawBracket(context: context, corner: br, hDir: -1, vDir: -1)
        }
    }

    private func drawBracket(
        context: GraphicsContext,
        corner: CGPoint,
        hDir: CGFloat,
        vDir: CGFloat
    ) {
        var horizontalArm = Path()
        horizontalArm.move(to: corner)
        horizontalArm.addLine(to: CGPoint(
            x: corner.x + hDir * bracketLength,
            y: corner.y
        ))

        var verticalArm = Path()
        verticalArm.move(to: corner)
        verticalArm.addLine(to: CGPoint(
            x: corner.x,
            y: corner.y + vDir * bracketLength
        ))

        let style = StrokeStyle(lineWidth: bracketWidth, lineCap: .round)
        context.stroke(horizontalArm, with: .color(color), style: style)
        context.stroke(verticalArm, with: .color(color), style: style)
    }
}
