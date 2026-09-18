# Production integration candidate — 2026-09-18

This integrates the previously separate requested-capability/proof forwarding,
Entity connection launcher, Nearby executable lookup, and uncommitted terminal
onboarding, identity recovery, bounded HTTP and release verification work.
Original local working trees and historical branches remain preserved.
The dated September 7–11 reports are historical evidence; their permissions,
branch names, test counts and rollout status do not describe this candidate.

The bootstrap context decoder now reads older state without the new
requestedCapabilities field. Only a missing field defaults to an empty request;
malformed present values are rejected, and valid values use sorted set semantics.
The original defect failed three of four regression tests before the fix.
Verified Entity inclusion proofs are forwarded unchanged into both capability
and Porthole requests. Resolver rejection stays authoritative. Invalid signatures
stop before either issuance request; requesting a capability does not grant it.

Local evidence:

- All 134 XCTest and 6 Swift Testing cases passed with the integrated source.
- Terminal process tests passed against both debug and optimized release binaries:
  refusal, EOF, resumption with the same key, optional arguments, no blanket
  consent flag, and corrupt-state refusal.
- Five installed-companion lookup tests passed, including PATH and symlinks.
- Release guards rejected unsigned delivery, tampering, unsafe/duplicate manifest
  paths, symlinks, partial signatures, wrong source/tag/platform, dynamic Linux
  binaries, and missing or wrong Nearby source. Signer selection uses a local
  double in these tests; that is not a cryptographic signing receipt.
- The optimized macOS arm64 bundle built Sprout, updater and the actual
  haven-nearby companion from CellProtocol533b42d5. All binary architectures,
  manifest entries and local development checksums passed.
- The packaged Sprout executed its adjacent real companion and accepted a valid
  synthetic local offer while rejecting expired, untrusted-origin and malformed
  offers. No browse, advertise, network enrollment or existing identity was used.

The macOS bundle now includes the companion and its exact upstream source
revision under the same checksums/signing process. The official Swift install
page independently confirmed the existing6.2.4 static Linux SDK checksum:
https://www.swift.org/install/macos/ . Linux CI must still build and execute the
actual static artifact; local macOS success cannot replace that gate.

Remaining acceptance: exact remote CI, signed tagged distribution, installation
and actual two-device discovery/link approval. Terminal onboarding intentionally
stops without verified Entity admission; it is not a complete correspondence
client or channel authorization. The separate sprout-macos UI is built in CI but
is still outside the CLI release bundle. Do not infer production deployment or
human enrollment from the local evidence above.
