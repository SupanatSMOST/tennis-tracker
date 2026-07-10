import SwiftUI
import TennisCore

/// Sheet to pick a court surface and create a new match.
/// Calls viewModel.create(surface:); routing is driven by MatchListView's
/// onChange(of: viewModel.createdMatch?.id) observer (AC30).
struct CreateMatchSheet: View {
    @Bindable var viewModel: MatchListViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedSurface = "hard"
    @State private var isSubmitting = false

    private let surfaces = ["hard", "clay", "grass"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Court Surface") {
                    Picker("Surface", selection: $selectedSurface) {
                        ForEach(surfaces, id: \.self) { surface in
                            Text(surface.capitalized).tag(surface)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if let error = viewModel.loadError {
                    Section {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button("Start Match") {
                        start()
                    }
                    .disabled(isSubmitting)
                }
            }
            .navigationTitle("New Match")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func start() {
        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            await viewModel.create(surface: selectedSurface)
            // Dismiss is handled by MatchListView's onChange(of: viewModel.createdMatch?.id)
        }
    }
}
