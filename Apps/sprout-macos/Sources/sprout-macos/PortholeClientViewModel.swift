import AppKit
import Foundation
import SproutAppSupport
import SwiftUI

@MainActor
final class PortholeClientViewModel: ObservableObject {
    @Published var importedFilePath = ""
    @Published var session: PortholeClientSession?
    @Published var webRequest: URLRequest?
    @Published var errorMessage: String?

    func loadContract(from url: URL) {
        importedFilePath = url.path
        do {
            let session = try PortholeClientSession.load(from: url)
            self.session = session
            self.webRequest = try? session.makeWebURLRequest()
            self.errorMessage = nil
        } catch {
            self.session = nil
            self.webRequest = nil
            self.errorMessage = String(describing: error)
        }
    }

    func clear() {
        importedFilePath = ""
        session = nil
        webRequest = nil
        errorMessage = nil
    }

    func copyNativeDescriptorJSON() {
        guard let session else { return }
        do {
            let json = try session.nativeDescriptorJSON()
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(json, forType: .string)
        } catch {
            errorMessage = String(describing: error)
        }
    }
}
