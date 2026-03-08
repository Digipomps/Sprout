import Foundation

#if SPROUT_ENABLE_CELLPROTOCOL_RUNTIME && canImport(CellBase)
@preconcurrency import CellBase

// CellProtocol predates strict Swift 6 sendability annotations.
// Sprout keeps this escape hatch narrow and local to the native binding bridge.
extension Identity: @retroactive @unchecked Sendable {}
#endif
