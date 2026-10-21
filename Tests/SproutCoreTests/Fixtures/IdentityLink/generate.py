#!/usr/bin/env python3
"""Independent Python 3 + cryptography reference for CP81601a6 IdentityLink wire.
Synthetic keys only. Never use these public fixture seeds for real enrollment.
Canonical request/approval = compact case-insensitive-key-sorted JSON with slash escaping (CP Foundation JSONSerialization).
VC payload = compact sorted JSON without slash escaping; proof omitted.
Challenge = sorted JSON with slash escaping, matching IdentitySigningChallenge.
"""
import base64, hashlib, json
from pathlib import Path
from datetime import datetime, timezone
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

def b64(b): return base64.b64encode(b).decode()
def b64u(b): return base64.urlsafe_b64encode(b).decode().rstrip('=')
def rawjson(v): return json.dumps(v, ensure_ascii=False, sort_keys=True, separators=(',',':')).encode()
def foundation_order(value):
    # CP wire fields are ASCII; no numeric suffixes or equal folded keys occur.
    if isinstance(value, dict): return {key: foundation_order(value[key]) for key in sorted(value, key=str.casefold)}
    if isinstance(value, list): return [foundation_order(x) for x in value]
    return value

def canonical(v):
    ordered=foundation_order({k:x for k,x in v.items() if k!='proof'})
    return json.dumps(ordered, ensure_ascii=False, separators=(',',':')).encode().replace(b'/',b'\\/')
def unsignedvc(v): return rawjson({k:x for k,x in v.items() if k!='proof'})
def b58(data):
    chars='123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'; n=int.from_bytes(data,'big'); s=''
    while n: n,r=divmod(n,58); s=chars[r]+s
    return '1'*(len(data)-len(data.lstrip(b'\0')))+s

def did(identity): return 'did:key:z'+b58(b'\xed\x01'+base64.b64decode(identity['publicKey']))
seed=bytes(range(32)); ownerseed=bytes(range(32,64))
key=Ed25519PrivateKey.from_private_bytes(seed); ownerkey=Ed25519PrivateKey.from_private_bytes(ownerseed)
public=key.public_key().public_bytes(Encoding.Raw,PublicFormat.Raw); ownerpublic=ownerkey.public_key().public_bytes(Encoding.Raw,PublicFormat.Raw)
nowstr='2026-09-29T12:00:00Z'; expires='2026-09-29T12:10:00Z'; now=int(datetime(2026,9,29,12,tzinfo=timezone.utc).timestamp())
origin='https://synthetic-person.example'; audience='synthetic-person.example'
identity=dict(uuid='11111111-2222-4333-8444-555555555555',displayName='Sprout CLI',publicKey=b64(public),algorithm='EdDSA',curveType='Curve25519')
owner=dict(uuid='66666666-7777-4888-8999-AAAAAAAAAAAA',displayName='Synthetic owner',publicKey=b64(ownerpublic),algorithm='EdDSA',curveType='Curve25519')
binding=dict(mode='localEntityAnchor',entityAnchorReference='cell:///EntityAnchor',audience=audience)
ticket=dict(schema='haven.identity-link.ticket.v1',ticketID='lt-00000000-0000-4000-8000-000000000001',audience=audience,origin=origin,entityBinding=binding,rendezvousURL=origin+'/link/api',nonce=b64(bytes([0x31])*32),expiresAt=expires,presentationChallenge=b64(bytes([0x37])*32),presentationDomain=origin,ownerDisplayName='Synthetic owner',approverLabel='Synthetic browser')
request=dict(version=1,requestID='request-00000000-0000-4000-8000-000000000002',purpose='link_identity',entityBinding=binding,newIdentity=identity,requestedDomains=['private','scaffold'],requestedIdentityContexts=['sprout-cli'],requestedScopes=['same_entity'],audience=audience,origin=origin,createdAt=nowstr,expiresAt=expires,nonce=ticket['nonce'],platform='linux',deviceLabel='Sprout CLI')
reqbytes=canonical(request); reqhash=hashlib.sha256(reqbytes).digest()
request['proof']=dict(type='signature',byIdentityUUID=identity['uuid'],algorithm='EdDSA',curveType='Curve25519',signature=b64(key.sign(reqbytes)))
authdata=bytes(32)+b'\x05'+bytes(4)
fresh=dict(method='webauthn',challenge=b64(reqhash),performedAt=nowstr,credentialID=b64(b'synthetic-credential'),authenticatorData=b64(authdata),clientDataJSON=b64(b'synthetic-client-data'),signature=b64(b'synthetic-authenticator-signature'))
approval=dict(version=1,approvalID='00000000-0000-4000-8000-000000000003',purpose='approve_link_identity',requestHash=b64(reqhash),entityBinding=binding,subjectIdentity=identity,approvedDomains=request['requestedDomains'],approvedIdentityContexts=request['requestedIdentityContexts'],approvedScopes=request['requestedScopes'],issuerIdentityUUID=owner['uuid'],issuerType='existingDevice',audience=audience,origin=origin,createdAt=nowstr,expiresAt='2026-09-29T12:05:00Z',jti='00000000-0000-4000-8000-000000000004',freshAuthRequired=True,freshAuthMethod='local-user-presence',freshAuthPerformedAt=nowstr,freshAuthEvidence=fresh)
approval['proof']=dict(type='signature',issuerIdentityUUID=owner['uuid'],issuerType='existingDevice',algorithm='EdDSA',curveType='Curve25519',signature=b64(ownerkey.sign(canonical(approval))))
context=['https://www.w3.org/2018/credentials/v1','https://www.w3.org/2018/credentials/examples/v1']
subject=dict(id=did(identity),linkType='same_entity',entityBinding=binding,linkedIdentity=identity,approvedDomains=request['requestedDomains'],approvedIdentityContexts=request['requestedIdentityContexts'],approvedScopes=request['requestedScopes'],enrollmentRequestHash=b64(reqhash),assuranceSource='fresh_auth_and_possession',assuranceLevel='high',validUntil=expires)
credential={'@context':context,'id':'cell:///identity/'+identity['uuid']+'/claims/00000000-0000-4000-8000-000000000005','type':['VerifiableCredential','SameEntityIdentityLinkCredential'],'issuer':did(owner),'issuanceDate':nowstr,'credentialSubject':subject}
credential['proof']=dict(type='Ed25519Signature2020',created=nowstr,proofPurpose='assertionMethod',verificationMethod=owner['uuid'],signatureData=b64(ownerkey.sign(unsignedvc(credential))))
package=dict(requestHash=b64u(reqhash),approval=approval,sameEntityCredential=credential,issuerIdentity=owner,presentationChallenge=ticket['presentationChallenge'],presentationDomain=origin,audience=audience,origin=origin,completeURL=origin+'/link/api/complete')
presentation={'@context':context,'id':'cell:///identity/'+identity['uuid']+'/claims/00000000-0000-4000-8000-000000000006','type':['VerifiableCredential','SameEntityIdentityLinkPresentation'],'holder':did(identity),'challenge':ticket['presentationChallenge'],'domain':origin,'holderBinding':identity,'verifiableCredential':[credential]}
presbytes=unsignedvc(presentation)
presentation['proof']=dict(type='Ed25519Signature2020',created=nowstr,proofPurpose='authentication',verificationMethod=identity['uuid'],signatureData=b64(key.sign(presbytes)))
envelope=dict(request=request,approval=approval,sameEntityCredential=credential,presentation=presentation,issuerIdentity=owner,expectedAudience=audience,expectedOrigin=origin,expectedPresentationChallenge=ticket['presentationChallenge'],expectedPresentationDomain=origin,requireFreshAuthEvidence=True)
receipt=dict(version=1,domain=audience,identity=identity,evidenceReference='a'*64,linkID=approval['approvalID'])
resolution=dict(identity_public_key=b64u(public),domain=audience,scaffold_admin_public_key=b64u(ownerpublic),purpose='bootstrap.join_scaffold',goal='Start a Linux service',interests=['haven.core.bootstrap'])
resolutionbinding=dict(resolution,schema='haven.sprout-person-entity-resolution.v1',evidence_reference=receipt['evidenceReference'],link_id=receipt['linkID'])
challenge=dict(type='org.haven.cellprotocol.identity-signing-challenge',version=1,purpose='identity-origin-proof',identityUUID=identity['uuid'],publicKeyFingerprint='EdDSA:Curve25519:'+b64(public),domain='private',resource='sprout-entity-resolution:'+b64u(hashlib.sha256(rawjson(resolutionbinding)).digest()),action='sprout.entity.resolve.v1',audience=origin,nonce=b64(bytes([0x47])*32),issuedAt=now,expiresAt=now+60)
challengebytes=rawjson(challenge).replace(b'/',b'\\/')
proof=dict(schema='haven.person-entity-read-route-proof.v1',evidenceReference=receipt['evidenceReference'],linkID=receipt['linkID'],challenge=b64(challengebytes),signature=b64(key.sign(challengebytes)))
fixture=dict(now=now,seedBase64URL=b64u(seed),issuerSeedBase64URL=b64u(ownerseed),ticket=ticket,deepLink='haven://identity-link?t='+b64u(rawjson(ticket)),requestCanonicalBase64=b64(reqbytes),request=request,requestHash=b64u(reqhash),package=package,presentationCanonicalBase64=b64(presbytes),envelope=envelope,receipt=receipt,resolutionRequest=resolution,resolveProof=proof,challengeCanonicalBase64=b64(challengebytes))
Path(__file__).with_name('identity-link-v1.json').write_text(json.dumps(fixture,ensure_ascii=False,sort_keys=True,indent=2)+'\n')
