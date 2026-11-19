import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SproutCore

public enum NativePortholeContractPresentationError: Error, Equatable, Sendable {
    case invalidPresentationURL
    case insecureTransport
    case nonHTTPResponse
    case rejected(status: Int)
}

/// Presents the native Porthole access contract to the scaffold before the
/// channel-authenticated bridge is opened. The contract goes in a POST body;
/// the bridge WebSocket URL stays free of contract data.
public protocol NativePortholeContractPresenting: Sendable {
    func present(_ descriptor: NativePortholeBindingDescriptor) async throws
}

public struct URLSessionNativePortholeContractPresenter: NativePortholeContractPresenting {
    public static let maximumResponseBytes = 16 * 1024
    private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

    private let sessionConfiguration: URLSessionConfiguration

    public init(sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        self.sessionConfiguration = sessionConfiguration
    }

    /// HTTPS only; plain HTTP is accepted for loopback hosts (local development).
    public static func makeRequest(for descriptor: NativePortholeBindingDescriptor) throws -> URLRequest {
        guard let components = URLComponents(string: descriptor.contract_presentation_url),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.query == nil, components.fragment == nil,
              components.user == nil, components.password == nil,
              let url = components.url else {
            throw NativePortholeContractPresentationError.invalidPresentationURL
        }
        guard scheme == "https" || (scheme == "http" && loopbackHosts.contains(host)) else {
            throw NativePortholeContractPresentationError.insecureTransport
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try encoder.encode(descriptor.contractPresentation)
        return request
    }

    public func present(_ descriptor: NativePortholeBindingDescriptor) async throws {
        let request = try Self.makeRequest(for: descriptor)
        let configuration = sessionConfiguration
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let delegate = NoRedirectDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NativePortholeContractPresentationError.nonHTTPResponse
        }
        guard (200..<300).contains(http.statusCode), data.count <= Self.maximumResponseBytes else {
            throw NativePortholeContractPresentationError.rejected(status: http.statusCode)
        }
    }
}

/// A redirect would resend the contract to a host the descriptor did not name.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
