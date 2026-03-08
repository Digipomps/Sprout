# Live Resolver Integration

## What is implemented
- `HavenResolverHTTPAdapter` in `SproutResolverAdapter`
- explicit CLI feature flag for live resolver mode
- resolver issuer-key pinning support
- OpenAPI contract in `OpenAPI/resolver.openapi.yaml`
- integration tests for full bootstrap through the HTTP adapter

## CLI activation
Use the live path only with explicit opt-in:
- `--enable-live-resolver`
- `--resolver-base-url <https://resolver.example>`
- optional `--trusted-resolver-key <pubkey1,pubkey2>`
- optional `--resolver-bearer <token>`
- optional `--resolver-path-prefix <path>`

## Trust model
- HTTPS is required by default
- resolver bearer auth is optional and environment-specific
- resolver issuer keys can be pinned explicitly
- inclusion proof and porthole contract must come from the same resolver issuer

## Current limitation
The client adapter is implemented and tested in this repo, but the authoritative HAVEN server-side routes that implement the resolver contract remain an external dependency. This repo's release status should therefore be read as:
- client-side live resolver path: implemented
- authoritative server-side live resolver path: not part of the verified `sprout` release scope yet
