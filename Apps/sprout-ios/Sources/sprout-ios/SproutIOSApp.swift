import SwiftUI

@main
struct SproutIOSApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 12) {
                Text("Sprout iOS")
                    .font(.title)
                Text("P1 placeholder. Bootstrap and linking flows are implemented in SproutCore/CLI for P0.")
                    .font(.footnote)
            }
            .padding()
        }
    }
}
