# Interop Matrix (Implemented vs Planned)

Note:
- `CLI` applies to the supported native CLI runtime on macOS and Linux.
- The current Linux baseline is `sprout` + `sprout-updater` on Ubuntu 22.04 `x86_64`.
- Full Linux WSS transport parity is still planned work, not implemented baseline.

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
| Native consumer output (`NativePortholeBindingDescriptor`) | Yes | Planned consumer | Descriptor inspection in standalone build | Implemented in core + CLI + macOS app |
| Resolver register/capability/membership | Mock + anchor-backed + live HTTP client | Planned real | Planned real | P0/P1 bridge implemented on the Sprout side; authoritative server remains external |
| Offline catalog discovery | Yes | Planned | Planned | Implemented |
| Web discovery client | Yes (client) | Planned | Planned | Implemented client + mock server |
| Cross-device QR mutual linking | File contract only | Planned | Planned | P1 |
| Separate updater binary | Yes | N/A | Planned bundle path | Implemented as `sprout-updater` |
| Signed distro + provenance verify | Yes (CI + local scripts) | N/A | Planned | Checksum + cosign keyless enabled; GitHub attestations are opt-in because private-repo support is plan-dependent |
| Native Linux CLI/updater deployment | Yes | N/A | N/A | Implemented baseline for Ubuntu 22.04 `x86_64`; no Docker required |
| Linux WSS streaming transport | Planned | N/A | N/A | Not implemented; release scope explicitly excludes it |
| TUF updater metadata | Planned | N/A | Planned | P2 |
