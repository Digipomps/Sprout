import SproutAppSupport
import SwiftUI

#if canImport(CellApple)
import CellApple

struct NativePortholeHostView: View {
    let session: PortholeClientSession
    @StateObject private var runtime = NativePortholeBindingRuntime()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Native CellProtocol Porthole")
                .font(.title2)

            Text(runtime.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let errorMessage = runtime.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .textSelection(.enabled)
            }

            if let skeleton = runtime.skeleton {
                ScrollView {
                    SkeletonView(element: skeleton)
                        .padding(.bottom, 12)
                }
            } else {
                ProgressView("Connecting native bridge")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: session.contract.contract_id) {
            await runtime.connect(using: session)
        }
        .onDisappear {
            runtime.disconnect()
        }
    }
}
#endif
