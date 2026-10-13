# IdentityLink v1 independent reference

Synthetic fixtures for CellProtocol revision `81601a6` and Sprout's portable
client. Run `python3 generate.py` in an environment with `cryptography` installed
(generator run used 50.0.1). The committed output is deterministic. Every seed in
this fixture is public test material and must never be used in production.

Request and approval canonical JSON use Foundation's case-insensitive sorted
ASCII field ordering and escaped slashes; VC canonical JSON uses lexical ordering
and unescaped slashes; challenge JSON uses lexical ordering and escaped slashes.
See `docs/Identity_Link_CLI_Interop_2026-09-29.md` for source provenance and scope.

The fake WebAuthn values intentionally require a synthetic verifier in server
tests; this file is not a real passkey approval. Do not submit it to live HAVEN.
