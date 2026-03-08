# Interop Matrix (Implemented vs Planned)

| Flow | CLI | iOS | macOS | Status |
|---|---|---|---|---|
| Parse/validate `StarterAuthPayload` | Yes | Planned | Planned | Implemented in core + CLI |
| Validate signed `BridgeDescriptor` | Yes | Planned | Planned | Implemented in core + CLI |
| Explicit `ScaffoldAdminIdentity` derivation | Yes | Planned | Planned | Implemented in core + CLI |
| Explicit entity resolution state (`resolved` / `unresolved`) | Yes | Planned | Planned | Implemented in core + CLI |
| Resolver-signed `EntityInclusionProof` | Yes | Planned | Planned | Implemented via file-backed anchor adapter and live HTTP adapter + tests |
| File-backed `EntityAnchorSnapshot` resolution | Yes | Planned consumer | Planned consumer | Implemented in resolver adapter + CLI flag |
| Optional `EntityLinkEvidence` handoff | Yes | Planned QR | Planned QR | Implemented for signed contract file input |
| Signed `PortholeAccessContract` for CLI | Yes | Planned | Planned | Implemented |
| Web consumer output (`WebPortholeBootstrapDescriptor`) | Yes | Planned consumer | Yes | Implemented in core + CLI + macOS app |
| Native consumer output (`NativePortholeBindingDescriptor`) | Yes | Planned consumer | Yes | Implemented in core + CLI + macOS app |
| Resolver register/capability/membership | Mock + anchor-backed + live HTTP client | Planned real | Planned real | P0/P1 bridge implemented on the Sprout side; authoritative server remains external |
| Offline catalog discovery | Yes | Planned | Planned | Implemented |
| Web discovery client | Yes (client) | Planned | Planned | Implemented client + mock server |
| Cross-device QR mutual linking | File contract only | Planned | Planned | P1 |
| Separate updater binary | Yes | N/A | Planned bundle path | Implemented as `sprout-updater` |
| Signed distro + provenance verify | Yes (CI + local scripts) | N/A | Planned | Checksum + cosign keyless + attestation wired; published trust roots remain environment-dependent |
| TUF updater metadata | Planned | N/A | Planned | P2 |
