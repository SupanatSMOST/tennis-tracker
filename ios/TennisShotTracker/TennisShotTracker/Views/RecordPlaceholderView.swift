import SwiftUI

/// Static placeholder for the Record tab.
struct RecordPlaceholderView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "video")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Record")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Record")
    }
}
