import SwiftUI

/// The only screen this app has, until the first real one lands. Exists so there is something to
/// launch, and something for the `Mac` workflow to screenshot.
struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "calendar")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("MirrorCal")
                .font(.title)
                .fontWeight(.semibold)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
