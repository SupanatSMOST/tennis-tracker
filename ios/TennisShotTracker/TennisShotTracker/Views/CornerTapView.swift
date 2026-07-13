import SwiftUI
import TennisCore

// MARK: - CornerTapView (FR-V2 / FR-V4)

/// FR-V2 / FR-V4: Sequential 4-corner tap screen.
///
/// Thin reader — no calibration math.  All coordinate conversion and homography
/// computation flow through `cameraVM` (injected from `MatchListView`).
///
/// Flow:
///   1. User taps each court corner in order: TL → TR → BL → BR.
///   2. After each tap, a colored dot marks the tapped location.
///   3. On the 4th tap, once `cameraVM.homography != nil`, `saveCalibration` is
///      called (FR-V4) and the path advances to `.session(matchID)`.
///   4. "Redo" clears all four taps and restarts from Top-Left (OQ-5).
struct CornerTapView: View {
    let cameraVM: CameraSessionViewModel
    let matchID: String
    @Binding var path: [Route]

    /// Pixel-space tap locations accumulated in this view for dot rendering.
    /// Kept locally to drive dot positions — the fraction coords are stored
    /// inside `cameraVM.imagePoints`.
    @State private var tapLocations: [CGPoint] = []

    /// The size of the preview area, captured from GeometryReader and used to
    /// pass imageSize to `cameraVM.tapCorner(at:imageSize:)`.
    @State private var previewSize: CGSize = .zero

    // Sequential corner prompts in [TL, TR, BL, BR] order (spec §4).
    private let cornerLabels = [
        "Tap Top-Left corner",
        "Tap Top-Right corner",
        "Tap Bottom-Left corner",
        "Tap Bottom-Right corner",
    ]

    private let dotColors: [Color] = [.red, .blue, .green, .yellow]

    var body: some View {
        ZStack {
            // Tappable preview area
            GeometryReader { geo in
                Color.black
                    .contentShape(Rectangle())
                    .onAppear { previewSize = geo.size }
                    .onChange(of: geo.size) { _, newSize in previewSize = newSize }
                    .gesture(
                        SpatialTapGesture()
                            .onEnded { value in
                                handleTap(at: value.location)
                            }
                    )

                // Dots for tapped points
                ForEach(tapLocations.indices, id: \.self) { index in
                    Circle()
                        .fill(dotColors[index % dotColors.count])
                        .frame(width: 16, height: 16)
                        .position(tapLocations[index])
                }
            }
            .ignoresSafeArea()

            // Prompt + controls pinned to bottom
            VStack {
                Spacer()
                VStack(spacing: 12) {
                    Text(currentPrompt)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.7), radius: 2)
                        .padding(.horizontal, 24)
                        .multilineTextAlignment(.center)

                    if tapLocations.count > 0 {
                        Button("Redo") {
                            // OQ-5: clear ALL four taps, restart from Top-Left.
                            tapLocations = []
                            cameraVM.resetCorners()
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                        .foregroundStyle(.white)
                    }

                    Spacer().frame(height: 32)
                }
            }
        }
        .navigationTitle("Tap Corners")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Private helpers

    private var currentPrompt: String {
        let count = tapLocations.count
        if count < cornerLabels.count {
            return cornerLabels[count]
        }
        return "All corners tapped"
    }

    private func handleTap(at location: CGPoint) {
        guard tapLocations.count < 4 else { return }
        guard previewSize != .zero else { return }

        // Accumulate the pixel-space location for dot rendering.
        tapLocations.append(location)

        // Forward to VM — converts to fraction coords internally (spec §4).
        cameraVM.tapCorner(at: location, imageSize: previewSize)

        // After the 4th tap, save calibration and advance to recording (FR-V4).
        if tapLocations.count == 4, cameraVM.homography != nil {
            do {
                try cameraVM.saveCalibration(for: matchID)
            } catch {
                // ponytail: saveCalibration throwing after a successful 4th tap
                // is unexpected (homography is non-nil). Silently continue to
                // .session so the user is not stuck — a failed persist means no
                // CV overlay in Phase 3 but does not block manual recording.
                // Upgrade path: surface a transient error banner if persist errors
                // become observable in practice.
            }
            path.append(.session(matchID))
        }
    }
}
