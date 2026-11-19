import Foundation
// Only this file sees CellBase, so CellProtocol's names (Identity, Agreement,
// ...) do not collide with SproutCore's own.
internal import CellBase

extension PortholeContractConsumer {
    /// Checks a native bridge endpoint with CellProtocol's own
    /// `BridgeChannelAuthentication.Endpoint(url:domain:allowInsecureLoopback:)`
    /// on the URL CellProtocol actually opens: `CellResolver.makeCellBridgeEmit`
    /// appends a UUID bridge ID and builds the endpoint with domain "bridge".
    /// `allowInsecureLoopback` is true here: this checks the endpoint's shape
    /// (ws only to CellProtocol's loopback hosts). Whether this process may use
    /// plain ws at all is CellProtocol's runtime policy, which
    /// `NativePortholeBindingRuntime` checks before it presents the contract.
    public static func validateNativeBridgeEndpoint(_ endpoint: String) throws {
        guard let base = URL(string: endpoint) else {
            throw PortholeContractConsumerError.invalidBridgeEndpoint
        }
        do {
            _ = try BridgeChannelAuthentication.Endpoint(
                url: base.appendingPathComponent(UUID().uuidString),
                domain: "bridge",
                allowInsecureLoopback: true
            )
        } catch {
            throw PortholeContractConsumerError.invalidBridgeEndpoint
        }
    }
}
