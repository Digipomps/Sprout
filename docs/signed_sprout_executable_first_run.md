# Signed Sprout Executable Download and First Run

Date: 2026-06-02

This document describes the end-to-end path we need to test for downloading a
signed `sprout` executable, running it for the first time, binding it to an
owner Identity that belongs to an Entity, and then using that proof to download
or connect to a HAVEN scaffold.

The important separation is:

- software signing proves that the executable and metadata came from the
  expected release pipeline or scaffold publisher
- owner binding proves that this local Sprout instance is controlled by a
  particular Identity
- Entity evidence proves that the owner Identity belongs to an Entity that is
  allowed to download software or connect to a scaffold

Possession of a signed executable is never authority by itself.

## Current Implementation Status

Implemented now:

- GitHub release workflow builds platform-suffixed CLI artifacts for macOS and
  Linux.
- Release artifacts are signed with cosign keyless signing in CI.
- Release bundles include checksum metadata and an SPDX SBOM.
- `sprout-updater verify-bundle` verifies artifact hashes against the checksum
  file.
- `sprout software fetch|verify|select|sign-catalog` can consume a signed
  scaffold executable catalog.
- `sprout owner init|show|list|trust-root` can create and inspect a local
  scaffold owner identity.
- `sprout bootstrap join` can consume `EntityLinkContract` or
  `EntityAdmissionContract` evidence during bootstrap.
- `sprout admission create-request` can create the target-side admission
  request from a continuity proof.

Not implemented yet:

- a single first-run command that combines download verification, owner identity
  initialization, owner binding and bootstrap
- raw Identity JSON import into a local vault-backed identity slot
- Binding-assisted owner binding over local discovery
- Bonjour/DNS-SD discovery for a local Sprout pairing endpoint
- a first-class software download authorization contract
- a protected scaffold software route that requires Entity evidence before
  returning a private artifact URL

## Release Artifacts to Publish

For the laptop test, publish at least:

- `sprout-macos-arm64`
- `sprout-updater-macos-arm64`
- `SHA256SUMS-macos-arm64.b64url`
- `release-manifest-macos-arm64.json`
- `sprout-macos-arm64.spdx.json`
- `sprout-macos-arm64.sig`
- `sprout-macos-arm64.pem`
- `sprout-updater-macos-arm64.sig`
- `sprout-updater-macos-arm64.pem`
- `SHA256SUMS-macos-arm64.b64url.sig`
- `SHA256SUMS-macos-arm64.b64url.pem`

For the staging Linux test, publish at least:

- `sprout-linux-x86_64`
- `sprout-updater-linux-x86_64`
- `SHA256SUMS-linux-x86_64.b64url`
- `release-manifest-linux-x86_64.json`
- `sprout-linux-x86_64.spdx.json`
- `sprout-linux-x86_64.sig`
- `sprout-linux-x86_64.pem`
- `sprout-updater-linux-x86_64.sig`
- `sprout-updater-linux-x86_64.pem`
- `SHA256SUMS-linux-x86_64.b64url.sig`
- `SHA256SUMS-linux-x86_64.b64url.pem`

The current workflow signs detached blobs with cosign signature and certificate
files. For a stronger release UX we should also consider emitting Sigstore
bundle files with transparency log proof, but the current repo baseline is
detached `.sig` and `.pem`.

## macOS Signing Interpretation

For the first terminal-based laptop test, cosign verification is enough to test
Sprout's supply-chain path. The user flow is:

1. download release artifacts
2. verify checksum and cosign signatures
3. mark the executable runnable
4. start `sprout` from Terminal

For broader macOS distribution outside a developer/test setting, the CLI or app
bundle should also be Developer ID signed and notarized. Apple's current
notarization documentation points developers to `notarytool`; `altool` is no
longer the supported notarization path. That OS-level trust is separate from
HAVEN's own catalog, owner and Entity contracts.

## Download and Verify on macOS

Set the release tag:

```bash
export SPROUT_VERSION=v0.2.0 # example; replace with the release tag under test
export SPROUT_REPO=https://github.com/Digipomps/Sprout
export SPROUT_PLATFORM=macos-arm64
mkdir -p "$HOME/Downloads/sprout-$SPROUT_VERSION"
cd "$HOME/Downloads/sprout-$SPROUT_VERSION"
```

If the GitHub release is private, use `gh release download "$SPROUT_VERSION"`
or authenticated `curl` with a token that can read the release.

Download:

```bash
curl -L -O "$SPROUT_REPO/releases/download/$SPROUT_VERSION/sprout-$SPROUT_PLATFORM"
curl -L -O "$SPROUT_REPO/releases/download/$SPROUT_VERSION/sprout-updater-$SPROUT_PLATFORM"
curl -L -O "$SPROUT_REPO/releases/download/$SPROUT_VERSION/SHA256SUMS-$SPROUT_PLATFORM.b64url"
curl -L -O "$SPROUT_REPO/releases/download/$SPROUT_VERSION/SHA256SUMS-$SPROUT_PLATFORM.b64url.sig"
curl -L -O "$SPROUT_REPO/releases/download/$SPROUT_VERSION/SHA256SUMS-$SPROUT_PLATFORM.b64url.pem"
curl -L -O "$SPROUT_REPO/releases/download/$SPROUT_VERSION/sprout-$SPROUT_PLATFORM.sig"
curl -L -O "$SPROUT_REPO/releases/download/$SPROUT_VERSION/sprout-$SPROUT_PLATFORM.pem"
curl -L -O "$SPROUT_REPO/releases/download/$SPROUT_VERSION/sprout-updater-$SPROUT_PLATFORM.sig"
curl -L -O "$SPROUT_REPO/releases/download/$SPROUT_VERSION/sprout-updater-$SPROUT_PLATFORM.pem"
```

Verify the checksum file signature:

```bash
cosign verify-blob \
  --certificate "SHA256SUMS-$SPROUT_PLATFORM.b64url.pem" \
  --signature "SHA256SUMS-$SPROUT_PLATFORM.b64url.sig" \
  --certificate-identity-regexp "https://github.com/Digipomps/Sprout/.+" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  "SHA256SUMS-$SPROUT_PLATFORM.b64url"
```

Verify the executable signatures:

```bash
cosign verify-blob \
  --certificate "sprout-$SPROUT_PLATFORM.pem" \
  --signature "sprout-$SPROUT_PLATFORM.sig" \
  --certificate-identity-regexp "https://github.com/Digipomps/Sprout/.+" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  "sprout-$SPROUT_PLATFORM"

cosign verify-blob \
  --certificate "sprout-updater-$SPROUT_PLATFORM.pem" \
  --signature "sprout-updater-$SPROUT_PLATFORM.sig" \
  --certificate-identity-regexp "https://github.com/Digipomps/Sprout/.+" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  "sprout-updater-$SPROUT_PLATFORM"
```

Verify hashes through the updater:

```bash
chmod +x "sprout-$SPROUT_PLATFORM" "sprout-updater-$SPROUT_PLATFORM"

./sprout-updater-$SPROUT_PLATFORM verify-bundle \
  --artifact-path "./sprout-$SPROUT_PLATFORM" \
  --checksum-file "./SHA256SUMS-$SPROUT_PLATFORM.b64url"
```

First launch:

```bash
./sprout-$SPROUT_PLATFORM --help
```

## Download and Verify on Linux Staging

On the staging host:

```bash
export SPROUT_VERSION=v0.2.0 # example; replace with the release tag under test
export SPROUT_REPO=https://github.com/Digipomps/Sprout
export SPROUT_PLATFORM=linux-x86_64
mkdir -p /tmp/sprout-$SPROUT_VERSION
cd /tmp/sprout-$SPROUT_VERSION
```

If the GitHub release is private, use `gh release download "$SPROUT_VERSION"`
or authenticated `curl` with a token that can read the release.

Download:

```bash
curl -L -O "$SPROUT_REPO/releases/download/$SPROUT_VERSION/sprout-$SPROUT_PLATFORM"
curl -L -O "$SPROUT_REPO/releases/download/$SPROUT_VERSION/sprout-updater-$SPROUT_PLATFORM"
curl -L -O "$SPROUT_REPO/releases/download/$SPROUT_VERSION/SHA256SUMS-$SPROUT_PLATFORM.b64url"
curl -L -O "$SPROUT_REPO/releases/download/$SPROUT_VERSION/SHA256SUMS-$SPROUT_PLATFORM.b64url.sig"
curl -L -O "$SPROUT_REPO/releases/download/$SPROUT_VERSION/SHA256SUMS-$SPROUT_PLATFORM.b64url.pem"
curl -L -O "$SPROUT_REPO/releases/download/$SPROUT_VERSION/sprout-$SPROUT_PLATFORM.sig"
curl -L -O "$SPROUT_REPO/releases/download/$SPROUT_VERSION/sprout-$SPROUT_PLATFORM.pem"
curl -L -O "$SPROUT_REPO/releases/download/$SPROUT_VERSION/sprout-updater-$SPROUT_PLATFORM.sig"
curl -L -O "$SPROUT_REPO/releases/download/$SPROUT_VERSION/sprout-updater-$SPROUT_PLATFORM.pem"
```

Verify:

```bash
cosign verify-blob \
  --certificate "SHA256SUMS-$SPROUT_PLATFORM.b64url.pem" \
  --signature "SHA256SUMS-$SPROUT_PLATFORM.b64url.sig" \
  --certificate-identity-regexp "https://github.com/Digipomps/Sprout/.+" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  "SHA256SUMS-$SPROUT_PLATFORM.b64url"

chmod +x "sprout-$SPROUT_PLATFORM" "sprout-updater-$SPROUT_PLATFORM"

./sprout-updater-$SPROUT_PLATFORM verify-bundle \
  --artifact-path "./sprout-$SPROUT_PLATFORM" \
  --checksum-file "./SHA256SUMS-$SPROUT_PLATFORM.b64url"
```

Install for the staging smoke test:

```bash
sudo install -d -m 0755 /opt/sprout/bin /etc/sprout /var/lib/sprout /var/log/sprout
sudo install -m 0755 "sprout-$SPROUT_PLATFORM" /opt/sprout/bin/sprout
sudo install -m 0755 "sprout-updater-$SPROUT_PLATFORM" /opt/sprout/bin/sprout-updater
```

First launch:

```bash
/opt/sprout/bin/sprout --help
```

## First-Run Identity Sequence

The first-run sequence should be:

1. create or load the local Sprout scaffold owner identity
2. present a pairing challenge for the real owner Identity
3. bind the local scaffold owner identity to that owner Identity
4. attach Entity evidence proving that the owner Identity belongs to the
   Entity allowed to use this Sprout instance
5. fetch or verify the HAVEN scaffold trust root
6. fetch the executable catalog for available scaffolds
7. request or present software/scaffold access evidence
8. select a scaffold artifact or request a porthole contract

Current CLI approximation:

```bash
./sprout-macos-arm64 owner init \
  --domain laptop-kjetil.local \
  --display-name "Kjetil laptop Sprout" \
  --root "$HOME/.sprout/scaffold-owners" \
  --out "$HOME/.sprout/owner.identity.json"
```

Then create a trust root:

```bash
./sprout-macos-arm64 owner trust-root \
  --domain laptop-kjetil.local \
  --root "$HOME/.sprout/scaffold-owners" \
  --resolver-base-url "https://staging.haven.digipomps.org" \
  --software-catalog-url "https://staging.haven.digipomps.org/.well-known/haven-executable-catalog.json" \
  --out "$HOME/.sprout/trust-roots/laptop-kjetil.local.json"
```

This creates a local scaffold/admin identity, but it does not yet prove that the
owner Identity belongs to the user's Entity. That proof has to arrive as
separate owner-binding and Entity evidence.

## Required Owner-Binding Contract

We need a new artifact, tentatively `SproutOwnerBindingClaim`.

Suggested shape:

```json
{
  "version": "1.0",
  "claim_id": "sobc_...",
  "sprout_domain": "laptop-kjetil.local",
  "sprout_owner_public_key": "...",
  "owner_identity_domain": "personal-vault.example",
  "owner_identity_public_key": "...",
  "entity_id": "entity_kjetil",
  "entity_evidence_type": "entity_admission_contract",
  "entity_evidence_sha256_b64url": "...",
  "capabilities": [
    "sprout.owner",
    "software.download",
    "scaffold.connect"
  ],
  "pairing_challenge": "...",
  "issued_at": "2026-06-02T12:00:00Z",
  "expires_at": "2026-06-02T12:15:00Z",
  "signature": {
    "alg": "Ed25519",
    "sig": "..."
  }
}
```

Rules:

- signed by the owner Identity, not by the local Sprout scaffold identity
- includes the local Sprout owner public key so the claim cannot be replayed to
  another installation
- includes a pairing challenge generated by this first-run Sprout process
- includes Entity evidence by hash or inline reference
- expires quickly
- grants only explicit capabilities

Suggested follow-up commands:

```bash
sprout owner pairing start \
  --domain laptop-kjetil.local \
  --root "$HOME/.sprout/scaffold-owners" \
  --out "$HOME/.sprout/pairing-challenge.json"

sprout owner bind \
  --domain laptop-kjetil.local \
  --claim "$HOME/.sprout/owner-binding-claim.json" \
  --entity-evidence "$HOME/.sprout/entity-admission-contract.json" \
  --out "$HOME/.sprout/owner-binding-receipt.json"
```

The receipt should be signed by the local Sprout owner identity and persisted in
the local owner store. It should be inspectable without exposing private key
material.

## Identity Import From JSON

We need JSON import for CLI-only testing, but it should have two modes.

Safe mode:

- imports a public Identity descriptor
- stores only public key, domain, context and key reference
- expects signing to happen through an external vault/provider

Test-only raw-key mode:

- accepts a private seed/key in JSON
- requires an explicit flag such as `--allow-raw-private-key-import`
- writes key material to the local encrypted or permission-restricted vault
- never logs the seed

Suggested command:

```bash
sprout identity import \
  --file owner-identity-export.json \
  --domain personal-vault.example \
  --context OwnerDevice \
  --vault "$HOME/.sprout/identity-vault" \
  --out "$HOME/.sprout/imported-owner-identity.json"
```

Suggested test-only raw import:

```bash
sprout identity import \
  --file owner-identity-with-seed.test.json \
  --domain personal-vault.example \
  --context OwnerDevice \
  --vault "$HOME/.sprout/identity-vault" \
  --allow-raw-private-key-import \
  --out "$HOME/.sprout/imported-owner-identity.json"
```

Raw private-key import should not be the normal iPhone/iPad/laptop vault model.
For real private vault use, Binding should sign a challenge without exporting
the private key.

## Binding-Assisted Owner Binding

Binding can be the preferred owner path when the Identity lives in a private
vault on laptop, iPhone or iPad.

Flow:

1. Sprout starts a local pairing listener.
2. Sprout advertises the listener through Bonjour/DNS-SD on the local network.
3. Binding discovers the Sprout instance.
4. Binding shows the domain, public key fingerprint and pairing challenge.
5. The user approves.
6. Binding signs a `SproutOwnerBindingClaim` with the selected Identity.
7. Binding sends the claim and Entity evidence to Sprout.
8. Sprout verifies the owner signature, challenge, expiry and Entity evidence.
9. Sprout persists an owner-binding receipt.

Suggested command:

```bash
sprout owner pairing listen \
  --domain laptop-kjetil.local \
  --root "$HOME/.sprout/scaffold-owners" \
  --bonjour \
  --service-type "_haven-sprout._tcp" \
  --out "$HOME/.sprout/pairing-session.json"
```

Suggested DNS-SD TXT keys:

- `v=1`
- `domain=laptop-kjetil.local`
- `pub=<short-public-key-fingerprint>`
- `challenge=<short-challenge-fingerprint>`
- `proto=https`
- `path=/v1/sprout/pairing`

Discovery is not authority. The signed pairing challenge and owner-binding
claim are authority.

For Linux staging, Bonjour/mDNS should only be expected to work on the same
local link. Cloud staging should prefer an explicit HTTPS pairing URL or an
operator-provided tunnel because mDNS/DNS-SD is local-network discovery, not a
general Internet discovery mechanism.

## Entity Proof for Download or Scaffold Connection

We need two related but separate access paths.

### Public software catalog test

This is enough for the first supply-chain smoke test:

1. anyone can fetch the signed software catalog
2. Sprout verifies the catalog signature and artifact signing evidence
3. Sprout selects the macOS or Linux artifact
4. download authorization is not tested

This proves distribution integrity, not Entity authorization.

### Entity-gated software/scaffold access

For the real HAVEN path, the owner Identity must present Entity evidence before
receiving a private artifact URL or scaffold connection contract.

Recommended new contract:

- `SoftwareAccessContract` or `ExecutableArtifactAccessContract`

Required fields:

- subject identity domain and public key
- resolved Entity ID
- capability, for example `software.download.cellscaffold`
- artifact kind, platform and channel
- scaffold domain
- issued by resolver or scaffold admin key
- issued/expires timestamps
- optional nonce/request ID
- signature

Suggested command sequence:

```bash
sprout software access-request \
  --domain staging.haven.digipomps.org \
  --kind cellscaffold \
  --platform linux-x86_64 \
  --identity "$HOME/.sprout/imported-owner-identity.json" \
  --entity-evidence "$HOME/.sprout/entity-admission-contract.json" \
  --purpose software.download \
  --goal "Download CellScaffold for staging smoke test" \
  --out "$HOME/.sprout/software-access-request.json"

sprout software fetch \
  --domain staging.haven.digipomps.org \
  --trust-root "$HOME/.sprout/trust-roots/staging.haven.digipomps.org.json" \
  --access-contract "$HOME/.sprout/software-access-contract.json" \
  --out "$HOME/.sprout/software-catalogs/staging.haven.digipomps.org.json"
```

For connecting to a scaffold, continue using the existing bootstrap evidence
chain:

```bash
sprout bootstrap join \
  --domain staging.haven.digipomps.org \
  --purpose bootstrap.join_scaffold \
  --goal "Connect this Sprout instance to staging CellScaffold" \
  --interests haven.core.bootstrap,haven.core.bridge,software.download.cellscaffold \
  --trust-root "$HOME/.sprout/trust-roots/staging.haven.digipomps.org.json" \
  --admission-contract "$HOME/.sprout/entity-admission-contract.json" \
  --continuity-proof "$HOME/.sprout/cross-scaffold-continuity-proof.json" \
  --porthole web \
  --state-out "$HOME/.sprout/bootstrap_state.json"
```

## End-to-End Test Matrix

### Laptop macOS test

Pass criteria:

- release artifacts download from terminal
- cosign verifies checksum and binary signatures
- `sprout-updater verify-bundle` verifies `sprout-macos-arm64`
- `sprout-macos-arm64 --help` runs
- `sprout owner init` creates local owner identity
- owner binding claim is imported from JSON or received from Binding
- Entity evidence verifies
- Sprout can fetch the signed scaffold executable catalog
- Sprout selects a `cellscaffold` artifact for either `macos-arm64` or
  `linux-x86_64`
- Sprout can request or consume a scaffold connection contract

### Linux staging test

Pass criteria:

- release artifacts download from terminal on staging host
- cosign verifies checksum and binary signatures
- `sprout-updater verify-bundle` verifies `sprout-linux-x86_64`
- binary installs under `/opt/sprout/bin`
- `/opt/sprout/bin/sprout --help` runs
- local state is under `/var/lib/sprout`
- trust root and executable catalog fetch from staging
- Entity evidence is required before non-public download or scaffold connection
- denial path works when Entity evidence is missing, expired or wrong-domain

### Binding local discovery test

Pass criteria:

- Sprout pairing listener advertises `_haven-sprout._tcp`
- Binding sees the service on the same LAN
- Binding displays the same challenge fingerprint that Sprout printed
- Binding signs owner claim with selected private-vault Identity
- Sprout accepts correct claim
- Sprout rejects stale challenge, wrong public key, wrong domain and expired
  Entity evidence

## Implementation Work Items

P0:

- add `sprout identity import`
- add `SproutOwnerBindingClaim` schema/model/verification
- add `sprout owner pairing start`
- add `sprout owner bind`
- add tests for missing, forged, stale and wrong-domain owner claims
- add `SoftwareAccessContract` or equivalent artifact-access contract
- require Entity evidence before protected software download or scaffold connect

P1:

- add local pairing listener
- add Bonjour/DNS-SD advertisement for `_haven-sprout._tcp`
- add Binding sender for owner-binding claim
- add Linux explicit pairing URL fallback
- emit Sigstore bundle files in release workflow
- add macOS Developer ID signing and notarization if the CLI/app is meant for
  broader non-developer distribution

P2:

- move artifact metadata into TUF roles for rollback protection
- add version floor and rollback grant handling
- add automated staging smoke test that downloads from the published release and
  performs the whole first-run owner-binding flow

## Sources Checked

- Apple Developer, "Notarizing macOS software before distribution":
  https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- Apple Developer, "Customizing the notarization workflow":
  https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/customizing_the_notarization_workflow
- Sigstore documentation, "Signing Blobs":
  https://docs.sigstore.dev/cosign/signing/signing_with_blobs/
- Apple Developer Bonjour overview:
  https://developer.apple.com/bonjour/
- RFC 6762, Multicast DNS:
  https://www.rfc-editor.org/info/rfc6762/
- RFC 6763, DNS-Based Service Discovery:
  https://www.rfc-editor.org/info/rfc6763
