import SproutAppSupport
import SwiftUI

#if SPROUT_ENABLE_CELLPROTOCOL_RUNTIME && canImport(CellApple)
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
#else
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

            Text("Standalone GitHub builds do not embed CellProtocol. You can still inspect and copy the signed native descriptor, but a live native session requires a workspace-coupled build.")
                .foregroundStyle(.secondary)

            if let errorMessage = runtime.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .textSelection(.enabled)
            }

            if let descriptor = session.nativeDescriptor {
                Divider()
                LabeledContent("Bridge WebSocket", value: descriptor.bridge_websocket_url)
                    .font(.caption)
                LabeledContent("Contract", value: descriptor.contract_id)
                    .font(.caption)
                LabeledContent("Cell Endpoint", value: descriptor.cell_endpoint)
                    .font(.caption)
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
