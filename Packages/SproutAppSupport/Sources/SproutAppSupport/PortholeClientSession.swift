import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SproutCore
import SproutResolverAdapter

public enum PortholeClientSessionMode: String, Codable, Equatable, Sendable {
    case web
    case native
    case unsupported
}

public enum PortholeClientSessionError: Error, Equatable, Sendable {
    case invalidContractFile
    case invalidLaunchURL
    case webDescriptorUnavailable
    case nativeDescriptorUnavailable
}

public struct PortholeClientSession: Equatable, Sendable {
    public var contract: PortholeAccessContract
    public var mode: PortholeClientSessionMode
    public var webDescriptor: WebPortholeBootstrapDescriptor?
    public var nativeDescriptor: NativePortholeBindingDescriptor?

    public init(
        contract: PortholeAccessContract,
        mode: PortholeClientSessionMode,
        webDescriptor: WebPortholeBootstrapDescriptor?,
        nativeDescriptor: NativePortholeBindingDescriptor?
    ) {
        self.contract = contract
        self.mode = mode
        self.webDescriptor = webDescriptor
        self.nativeDescriptor = nativeDescriptor
    }

    public static func load(from url: URL, now: Date = Date()) throws -> PortholeClientSession {
        try load(data: Data(contentsOf: url), now: now)
    }

    public static func load(data: Data, now: Date = Date()) throws -> PortholeClientSession {
        let contract = try JSONDecoder().decode(PortholeAccessContract.self, from: data)
        return try fromContract(contract, now: now)
    }

    public static func fromContract(_ contract: PortholeAccessContract, now: Date = Date()) throws -> PortholeClientSession {
        switch (contract.client_kind, contract.porthole_protocol) {
        case (.web, .web):
            return PortholeClientSession(
                contract: contract,
                mode: .web,
                webDescriptor: try PortholeContractConsumer.makeWebBootstrap(contract: contract, now: now),
                nativeDescriptor: nil
            )
        case (.native, .cellprotocol):
            return PortholeClientSession(
                contract: contract,
                mode: .native,
                webDescriptor: nil,
                nativeDescriptor: try PortholeContractConsumer.makeNativeBindingDescriptor(contract: contract, now: now)
            )
        default:
            return PortholeClientSession(
                contract: contract,
                mode: .unsupported,
                webDescriptor: nil,
                nativeDescriptor: nil
            )
        }
    }

    public func makeWebURLRequest() throws -> URLRequest {
        guard let webDescriptor else {
            throw PortholeClientSessionError.webDescriptorUnavailable
        }
        guard let url = URL(string: webDescriptor.launch_url) else {
            throw PortholeClientSessionError.invalidLaunchURL
        }

        var request = URLRequest(url: url)
        for (header, value) in webDescriptor.headers.sorted(by: { $0.key < $1.key }) {
            request.setValue(value, forHTTPHeaderField: header)
        }
        return request
    }

    public func nativeDescriptorJSON() throws -> String {
        guard let nativeDescriptor else {
            throw PortholeClientSessionError.nativeDescriptorUnavailable
        }
        let data = try JSONEncoder.pretty.encode(nativeDescriptor)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
