import SwiftUI

/// Static placeholder for the Home tab.
struct HomePlaceholderView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "house")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Home")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Home")
    }
}
