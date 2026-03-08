# Pseudocode

## SproutBootstrapStateMachine
```text
state = Idle
transition LoadContext
validate domain

transition AcquireIdentity
identity = identityProvider(context)
require identity.domain == context.domain

transition CollectPurposeInterest
require explicit purpose + goal + interests

transition ProbeEnvironment
environment = probe(context)

transition DiscoverBridges
require explicit purpose context
bridges = discover(context)
select first valid signed bridge for domain + purpose
scaffoldAdminIdentity = scaffoldAdminIdentityProvider(selectedBridge, context)
require scaffoldAdminIdentity.admin_public_key == selectedBridge.owner_pubkey

transition EstablishBridge
connect bridge endpoint

transition RegisterWithResolver
verify starter payload signature + expiry + domain
registration = resolver.registerStarterAuth(payload)
require registration.accepted

transition ResolveEntity
entityEvidence = entityEvidenceProvider(context)
if entityEvidence exists:
  require evidence contains identity.public_key
  require evidence verifies
entityResolution = resolver.resolveEntity(identity, purpose, goal, interests, entityEvidenceSummary)

transition MembershipChecks
caps = resolver.requestCapabilities(...)
if denied -> Error
membership = resolver.performMembershipChecks(...)
if denied -> Error

transition IssuePortholeAccess
require entityResolution.status == resolved
request signed porthole contract for requested client kind
verify returned contract signature
verify contract does not widen capabilities or alter entity/domain/bridge/admin identity

transition PersistBootstrap
persist(context)

transition Done
```

## Entity-link evidence
```text
EntityLinkEvidence =
  evidence_kind + EntityLinkContract + optional note

verify():
  currently only mutual_link_contract
  require mutual Ed25519 signatures over canonical payload

resolverSummary():
  emit contract_id
  emit linked public keys
  emit sha256 over canonical contract payload
```

## Porthole access contract
```text
request =
  scaffold domain
  resolved entity id
  subject identity public key
  scaffold admin public key
  selected bridge info
  requested client kind + protocol
  purpose + goal + interests
  granted capabilities

contract =
  signed resolver artifact
  same subject + entity + domain + bridge
  no capability amplification
  expiry bounded
```

## JCS Canonicalization (P0 subset)
```text
parse JSON -> internal tree
reject unsupported numbers (float/decimal/exponent)
for objects: sort keys lexicographically by unicode scalar values
emit compact JSON with escaped strings
```

## Ed25519 sign/verify
```text
canonicalPayload = JCS(payloadWithoutSignature)
sig = Ed25519.sign(privateKey, canonicalPayload)
valid = Ed25519.verify(publicKey, canonicalPayload, sig)
```

## Base64url strict parser
```text
reject '=' padding
reject characters outside [A-Za-z0-9_-]
reject length mod 4 == 1
decode + re-encode, require exact roundtrip
```
