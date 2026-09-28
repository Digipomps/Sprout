import SproutAppSupport
import SwiftUI
import UniformTypeIdentifiers

@main
struct SproutMacOSApp: App {
    @StateObject private var viewModel = PortholeClientViewModel()
    @State private var showingImporter = false
    @State private var personLinkMessage: String?

    var body: some Scene {
        WindowGroup {
            NavigationSplitView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Sprout macOS")
                        .font(.largeTitle)
                    Button("Utvid min entitet …") {
                        let opened = NSWorkspace.shared.open(URL(string: "haven://link-devices")!)
                        personLinkMessage = opened
                            ? "Fortsett i HAVEN og bekreft hvilke av dine entiteter som skal kobles."
                            : "Installer HAVEN-appen for å finne eller skanne en invitasjon."
                    }
                    Button("Automatikk ved cellebruk …") {
                        let opened = NSWorkspace.shared.open(URL(string: "haven://entity-extension-policy")!)
                        personLinkMessage = opened ? "Fortsett i HAVEN." : "Installer HAVEN-appen for å administrere policyen."
                    }
                    if let personLinkMessage {
                        Text(personLinkMessage).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Import a signed porthole contract and consume it as a macOS web/native handoff client.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack {
                        Button("Import Contract") {
                            showingImporter = true
                        }
                        Button("Clear") {
                            viewModel.clear()
                        }
                        .disabled(viewModel.session == nil && viewModel.importedFilePath.isEmpty)
                    }

                    if !viewModel.importedFilePath.isEmpty {
                        LabeledContent("File", value: viewModel.importedFilePath)
                            .font(.caption)
                    }

                    if let session = viewModel.session {
                        Divider()
                        LabeledContent("Mode", value: session.mode.rawValue)
                        LabeledContent("Contract", value: session.contract.contract_id)
                        LabeledContent("Entity", value: session.contract.entity_id)
                        LabeledContent("Domain", value: session.contract.scaffold_domain)
                        LabeledContent("Bridge", value: session.contract.bridge_endpoint)
                        LabeledContent("Expires", value: session.contract.expires_at)

                        if session.mode == .native {
                            Button("Copy Native Binding JSON") {
                                viewModel.copyNativeDescriptorJSON()
                            }
                        }
                    }

                    if let errorMessage = viewModel.errorMessage {
                        Divider()
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.caption)
                            .textSelection(.enabled)
                    }

                    Spacer()
                }
                .padding(20)
                .fileImporter(
                    isPresented: $showingImporter,
                    allowedContentTypes: [.json],
                    allowsMultipleSelection: false
                ) { result in
                    switch result {
                    case let .success(urls):
                        if let url = urls.first {
                            viewModel.loadContract(from: url)
                        }
                    case let .failure(error):
                        viewModel.errorMessage = error.localizedDescription
                    }
                }
            } detail: {
                if let session = viewModel.session {
                    switch session.mode {
                    case .web:
                        if let request = viewModel.webRequest {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Web Porthole")
                                    .font(.title2)
                                Text(request.url?.absoluteString ?? "")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                PortholeWebView(request: request)
                            }
                            .padding(16)
                        } else {
                            Text("Web request could not be created.")
                                .foregroundStyle(.secondary)
                        }
                    case .native:
                        VStack(alignment: .leading, spacing: 12) {
                            NativePortholeHostView(session: session)

                            Divider()

                            Text("Descriptor")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text((try? session.nativeDescriptorJSON()) ?? "{}")
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        .padding(16)
                    case .unsupported:
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Unsupported Contract Mode")
                                .font(.title2)
                            Text("This macOS client currently consumes `web` contracts and can inspect `native` contracts. CLI-only contracts remain unsupported here.")
                                .foregroundStyle(.secondary)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("No Contract Loaded")
                            .font(.title2)
                        Text("Import a `PortholeAccessContract` JSON file to start a web session or inspect a native binding descriptor.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(minWidth: 1040, minHeight: 700)
        }
    }
}
