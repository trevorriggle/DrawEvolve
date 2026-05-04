// Phase 5f — App Attest device verification.
//
// Two-phase device proof layered ON TOP of Supabase JWT auth (which proves
// who the user is). App Attest proves the request comes from a real
// DrawEvolve install on a real Apple device:
//
//   1. Registration (one-time per device install):
//      - Client requests a fresh challenge: POST /attest/challenge
//      - Client generates a Secure Enclave key, has Apple sign an attestation
//        binding the key to the app + the challenge.
//      - Client POSTs { keyId, attestation, challenge } to /attest/register.
//      - Worker verifies the attestation per Apple's spec, stores the public
//        key under `attest_key:<keyId>` in QUOTA_KV (counter starts at 0).
//
//   2. Per-request assertion (every protected call):
//      - Client computes clientDataHash = SHA256("METHOD:PATH:sha256-hex(body)")
//      - Client asks the Secure Enclave for an assertion over clientDataHash.
//      - Headers: X-Apple-AppAttest-KeyId, X-Apple-AppAttest-Assertion (base64)
//      - Worker re-derives clientDataHash from the request, parses the
//        assertion CBOR, verifies the ECDSA signature against the stored
//        public key, checks rpIdHash, and enforces signCount monotonicity.
//
// JWT and App Attest run as parallel gates in routes/feedback.js — JWT first
// (cheap), App Attest second. Both must pass.
//
// SECURITY POSTURE / KNOWN GAPS:
//   - Apple App Attest Root CA pinning is REQUIRED for production but
//     deferred here. APPLE_ATTEST_ROOT_PUBKEY_HEX is a placeholder; until
//     the operator pastes the real key, /attest/register fail-closes with
//     a 500 ('attest_root_not_pinned'). This is intentional — it prevents
//     a misconfigured deploy from silently accepting forged attestations.
//   - The intermediate cert is required to be present in x5c[1] and its
//     signature on the leaf is verified, so a leaf with no intermediate
//     or with a wrong-issuer leaf is rejected even before root pinning.
//   - Counter monotonicity (assertion path) defeats replay of identical
//     requests; binding clientDataHash to METHOD:PATH:body defeats cross-
//     endpoint replay.

export const APP_ATTEST_KEY_TTL_SECONDS = 30 * 24 * 3600;   // 30d sliding expiration on stored keys
export const APP_ATTEST_CHALLENGE_TTL_SECONDS = 5 * 60;     // 5m to complete attestation
export const APP_ATTEST_CHALLENGE_BYTES = 32;
const APP_ATTEST_OID = '1.2.840.113635.100.8.2';
const APP_ATTEST_AAGUID_DEV  = new TextEncoder().encode('appattestdevelop'); // exactly 16 bytes
const APP_ATTEST_AAGUID_PROD = (() => {
  // 'appattest' (9 bytes) + 7 zero bytes = 16
  const out = new Uint8Array(16);
  out.set(new TextEncoder().encode('appattest'), 0);
  return out;
})();

// PRODUCTION BLOCKER — paste Apple App Attest Root CA's uncompressed P-384
// public point as a hex string here ("04" || X(48) || Y(48), 97 bytes / 194
// hex chars). Source: https://www.apple.com/certificateauthority/
// (Apple_App_Attestation_Root_CA.pem). Until set, /attest/register returns
// 500 'attest_root_not_pinned' and refuses to verify any attestation. This
// is intentional fail-closed behavior — see DEPLOYMENT.md.
//
// This lives as a source constant (NOT a wrangler env var) on purpose: the
// root pubkey is bundled with worker code so a deploy can never accidentally
// pair a worker version with the wrong root.
const APPLE_ATTEST_ROOT_PUBKEY_HEX = '';

// ---- byte / encoding helpers ----------------------------------------------

export function bytesEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

export function bytesToHex(bytes) {
  return [...bytes].map((b) => b.toString(16).padStart(2, '0')).join('');
}

export function hexToBytes(hex) {
  if (hex.length % 2 !== 0) throw new Error('odd hex length');
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  return out;
}

function base64ToBytes(b64) {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function bytesToBase64Url(bytes) {
  let s = '';
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

async function sha256Bytes(bytes) {
  const buf = await crypto.subtle.digest('SHA-256', bytes);
  return new Uint8Array(buf);
}

function concatBytes(...arrays) {
  let total = 0;
  for (const a of arrays) total += a.length;
  const out = new Uint8Array(total);
  let off = 0;
  for (const a of arrays) { out.set(a, off); off += a.length; }
  return out;
}

// ---- minimal CBOR decoder --------------------------------------------------
//
// Implements just the subset App Attest emits: positive ints, byte strings,
// text strings, arrays, maps. Indefinite-length items are NOT supported (App
// Attest doesn't use them). Throws on anything outside this subset so an
// unexpected input surfaces as a clear error rather than silent miscoding.

export function cborDecode(bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const state = { offset: 0 };
  const value = cborReadItem(bytes, view, state);
  if (state.offset !== bytes.length) throw new Error('CBOR trailing bytes');
  return value;
}

function cborReadItem(bytes, view, state) {
  if (state.offset >= bytes.length) throw new Error('CBOR truncated');
  const initial = bytes[state.offset++];
  const major = initial >> 5;
  const info = initial & 0x1f;
  const length = cborReadLength(info, view, state);
  switch (major) {
    case 0: return length;                                       // unsigned int
    case 2: return cborReadBytes(bytes, state, length);          // byte string
    case 3: return new TextDecoder().decode(cborReadBytes(bytes, state, length)); // text string
    case 4: { // array
      const arr = new Array(length);
      for (let i = 0; i < length; i++) arr[i] = cborReadItem(bytes, view, state);
      return arr;
    }
    case 5: { // map (Object — App Attest uses string keys at all levels)
      const obj = {};
      for (let i = 0; i < length; i++) {
        const key = cborReadItem(bytes, view, state);
        const val = cborReadItem(bytes, view, state);
        obj[String(key)] = val;
      }
      return obj;
    }
    default:
      throw new Error(`CBOR unsupported major type: ${major}`);
  }
}

function cborReadLength(info, view, state) {
  if (info < 24) return info;
  if (info === 24) { const v = view.getUint8(state.offset); state.offset += 1; return v; }
  if (info === 25) { const v = view.getUint16(state.offset); state.offset += 2; return v; }
  if (info === 26) { const v = view.getUint32(state.offset); state.offset += 4; return v; }
  if (info === 27) {
    const hi = view.getUint32(state.offset);
    const lo = view.getUint32(state.offset + 4);
    state.offset += 8;
    if (hi !== 0) throw new Error('CBOR length > 2^32 unsupported');
    return lo;
  }
  throw new Error(`CBOR unsupported length info: ${info}`);
}

function cborReadBytes(bytes, state, length) {
  if (state.offset + length > bytes.length) throw new Error('CBOR truncated bytes');
  const out = bytes.slice(state.offset, state.offset + length);
  state.offset += length;
  return out;
}

// ---- minimal ASN.1 / DER parser -------------------------------------------
//
// Just enough to walk an X.509 cert: pull TBSCertificate (raw, for sig verify),
// the SubjectPublicKeyInfo, the signatureValue, and walk Extensions to find
// the App Attest nonce extension. Returns nodes as { tag, length, valueOffset,
// totalLength } so callers can re-slice the original buffer when they need
// raw bytes (TBS) vs decoded contents.

function derRead(bytes, offset) {
  const startTagOffset = offset;
  const tag = bytes[offset++];
  if (offset >= bytes.length) throw new Error('DER truncated tag');
  let length = bytes[offset++];
  if (length & 0x80) {
    const numBytes = length & 0x7f;
    if (numBytes === 0 || numBytes > 4) throw new Error(`DER unsupported length form: ${numBytes}`);
    length = 0;
    for (let i = 0; i < numBytes; i++) {
      length = (length << 8) | bytes[offset++];
    }
  }
  return { tag, length, valueOffset: offset, totalLength: offset - startTagOffset + length, startTagOffset };
}

function derChildren(bytes, parent) {
  const end = parent.valueOffset + parent.length;
  const out = [];
  let pos = parent.valueOffset;
  while (pos < end) {
    const node = derRead(bytes, pos);
    out.push(node);
    pos = node.valueOffset + node.length;
  }
  return out;
}

function derOidToString(bytes, node) {
  if (node.tag !== 0x06) throw new Error('DER not OID');
  const v = bytes.subarray(node.valueOffset, node.valueOffset + node.length);
  if (v.length === 0) return '';
  const first = v[0];
  const parts = [Math.floor(first / 40), first % 40];
  let value = 0;
  for (let i = 1; i < v.length; i++) {
    value = (value << 7) | (v[i] & 0x7f);
    if ((v[i] & 0x80) === 0) {
      parts.push(value);
      value = 0;
    }
  }
  return parts.join('.');
}

// X.509 v3 cert structure:
//   Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue }
//   tbsCertificate ::= SEQUENCE { version[0], serial, sigAlg, issuer, validity,
//                                 subject, subjectPublicKeyInfo, ..., extensions[3] }
function parseX509(certBytes) {
  const root = derRead(certBytes, 0);
  if (root.tag !== 0x30) throw new Error('X509 root not SEQUENCE');
  const [tbs, sigAlg, sigValue] = derChildren(certBytes, root);
  if (!tbs || !sigAlg || !sigValue) throw new Error('X509 missing fields');
  if (sigValue.tag !== 0x03) throw new Error('X509 sig not BIT STRING');
  // Skip the leading "unused bits" byte of BIT STRING.
  const sigDer = certBytes.subarray(sigValue.valueOffset + 1, sigValue.valueOffset + sigValue.length);
  const tbsBytes = certBytes.subarray(tbs.startTagOffset, tbs.valueOffset + tbs.length);
  const tbsChildren = derChildren(certBytes, tbs);
  // version is contextual [0] explicit — present iff v2/v3. If absent, all
  // indices shift left by one. Detect via tag.
  let idx = 0;
  if (tbsChildren[0]?.tag === 0xa0) idx = 1;
  // skip serial(0), sigAlg(1), issuer(2), validity(3), subject(4)
  const spki = tbsChildren[idx + 5];
  if (!spki || spki.tag !== 0x30) throw new Error('X509 missing SPKI');
  // Find extensions block: [3] EXPLICIT SEQUENCE OF Extension
  let extensionsNode = null;
  for (let i = idx + 6; i < tbsChildren.length; i++) {
    if (tbsChildren[i].tag === 0xa3) { extensionsNode = tbsChildren[i]; break; }
  }
  // signatureAlgorithm OID
  const sigAlgChildren = derChildren(certBytes, sigAlg);
  const sigAlgOid = sigAlgChildren[0] ? derOidToString(certBytes, sigAlgChildren[0]) : '';
  return { certBytes, tbsBytes, sigDer, sigAlgOid, spki, extensionsNode };
}

// SubjectPublicKeyInfo: SEQUENCE { algorithm AlgorithmIdentifier, subjectPublicKey BIT STRING }
// For EC keys, subjectPublicKey is the uncompressed point (0x04 || X || Y).
function spkiPublicKeyBytes(certBytes, spki) {
  const [, subjectPublicKey] = derChildren(certBytes, spki);
  if (!subjectPublicKey || subjectPublicKey.tag !== 0x03) throw new Error('SPKI missing pubkey BIT STRING');
  return certBytes.subarray(subjectPublicKey.valueOffset + 1, subjectPublicKey.valueOffset + subjectPublicKey.length);
}

// Extensions block contains a SEQUENCE OF Extension. Each Extension is
// SEQUENCE { extnID OBJECT IDENTIFIER, critical BOOLEAN OPTIONAL, extnValue OCTET STRING }.
// Returns the raw bytes inside the inner OCTET STRING (caller re-parses).
function findExtensionValue(certBytes, extensionsNode, oidString) {
  if (!extensionsNode) return null;
  const [seq] = derChildren(certBytes, extensionsNode);
  if (!seq || seq.tag !== 0x30) return null;
  for (const ext of derChildren(certBytes, seq)) {
    if (ext.tag !== 0x30) continue;
    const children = derChildren(certBytes, ext);
    const oidNode = children[0];
    if (!oidNode || oidNode.tag !== 0x06) continue;
    if (derOidToString(certBytes, oidNode) !== oidString) continue;
    // Last child is the OCTET STRING (skips optional BOOLEAN critical).
    const valueNode = children[children.length - 1];
    if (!valueNode || valueNode.tag !== 0x04) return null;
    return certBytes.subarray(valueNode.valueOffset, valueNode.valueOffset + valueNode.length);
  }
  return null;
}

// ECDSA-Sig-Value ::= SEQUENCE { r INTEGER, s INTEGER }  →  raw r||s for WebCrypto.
// curveByteLength is 32 for P-256, 48 for P-384.
export function ecdsaDerToRaw(der, curveByteLength) {
  const seq = derRead(der, 0);
  if (seq.tag !== 0x30) throw new Error('ECDSA sig not SEQUENCE');
  const [rNode, sNode] = derChildren(der, seq);
  if (!rNode || !sNode || rNode.tag !== 0x02 || sNode.tag !== 0x02) {
    throw new Error('ECDSA sig missing r/s');
  }
  const trim = (node) => {
    let v = der.subarray(node.valueOffset, node.valueOffset + node.length);
    // strip leading zero used for sign-bit padding
    if (v.length > 1 && v[0] === 0x00) v = v.subarray(1);
    if (v.length > curveByteLength) throw new Error('ECDSA sig component too large');
    const out = new Uint8Array(curveByteLength);
    out.set(v, curveByteLength - v.length);
    return out;
  };
  return concatBytes(trim(rNode), trim(sNode));
}

// Verify a cert's signature against an issuer's raw uncompressed EC point.
// Auto-detects P-256 (65-byte point) vs P-384 (97-byte point).
async function verifyCertSignature(cert, issuerPubKeyRaw) {
  let namedCurve, byteLen, hash;
  if (issuerPubKeyRaw.length === 65) { namedCurve = 'P-256'; byteLen = 32; hash = 'SHA-256'; }
  else if (issuerPubKeyRaw.length === 97) { namedCurve = 'P-384'; byteLen = 48; hash = 'SHA-384'; }
  else throw new Error(`unsupported issuer pubkey length: ${issuerPubKeyRaw.length}`);
  const key = await crypto.subtle.importKey(
    'raw', issuerPubKeyRaw, { name: 'ECDSA', namedCurve }, false, ['verify'],
  );
  const sigRaw = ecdsaDerToRaw(cert.sigDer, byteLen);
  return crypto.subtle.verify({ name: 'ECDSA', hash }, key, sigRaw, cert.tbsBytes);
}

// ---- attestation + assertion verifiers ------------------------------------

// Bundle ID stored as a Worker var so dev/prod can use different bundles
// without a code change. Falls back to a sensible default to keep the
// dev/test loop trivial. appID = "<TEAM>.<BUNDLE>".
function appAttestAppId(env) {
  const teamId = env.APP_ATTEST_TEAM_ID || '';
  const bundleId = env.APP_ATTEST_BUNDLE_ID || 'com.drawevolve.app';
  if (!teamId) throw new Error('APP_ATTEST_TEAM_ID not configured');
  return `${teamId}.${bundleId}`;
}

function appAttestExpectedAaguid(env) {
  const mode = env.APP_ATTEST_ENV === 'production' ? 'production' : 'development';
  return mode === 'production' ? APP_ATTEST_AAGUID_PROD : APP_ATTEST_AAGUID_DEV;
}

/**
 * Verify an App Attest attestation per Apple's documented steps. Returns the
 * extracted public key bytes (uncompressed P-256 point) on success; throws
 * with a stable error message on any failure. Does not touch storage —
 * caller decides when to persist.
 */
export async function verifyAppAttestAttestation({ keyIdB64, attestationB64, challengeBytes, env }) {
  if (!APPLE_ATTEST_ROOT_PUBKEY_HEX) {
    const err = new Error('attest_root_not_pinned');
    err.code = 'attest_root_not_pinned';
    throw err;
  }
  const attestation = base64ToBytes(attestationB64);
  const decoded = cborDecode(attestation);
  if (decoded.fmt !== 'apple-appattest') throw new Error('attest_bad_fmt');
  const authData = decoded.authData;
  const x5c = decoded.attStmt?.x5c;
  if (!authData || !Array.isArray(x5c) || x5c.length < 2) throw new Error('attest_bad_structure');

  // Step 1: chain verification. Leaf is x5c[0], intermediate is x5c[1].
  // Intermediate is verified against the Apple Root CA (P-384). Leaf is
  // verified against the intermediate's public key.
  const leaf = parseX509(x5c[0]);
  const intermediate = parseX509(x5c[1]);
  const intermediatePubKey = spkiPublicKeyBytes(x5c[1], intermediate.spki);
  const leafPubKey = spkiPublicKeyBytes(x5c[0], leaf.spki);
  const rootPubKey = hexToBytes(APPLE_ATTEST_ROOT_PUBKEY_HEX);
  if (rootPubKey.length !== 97) throw new Error('attest_root_pubkey_bad_length');

  const leafOk = await verifyCertSignature(leaf, intermediatePubKey);
  if (!leafOk) throw new Error('attest_leaf_sig_invalid');
  const intOk = await verifyCertSignature(intermediate, rootPubKey);
  if (!intOk) throw new Error('attest_intermediate_sig_invalid');

  // Steps 2–4: nonce extension matches sha256(authData || sha256(challenge)).
  const clientDataHash = await sha256Bytes(challengeBytes);
  const expectedNonce = await sha256Bytes(concatBytes(authData, clientDataHash));
  const extValue = findExtensionValue(x5c[0], leaf.extensionsNode, APP_ATTEST_OID);
  if (!extValue) throw new Error('attest_oid_missing');
  // extValue is a SEQUENCE { [1] OCTET STRING actualNonce }. Walk it.
  const extSeq = derRead(extValue, 0);
  if (extSeq.tag !== 0x30) throw new Error('attest_oid_not_seq');
  const inner = derChildren(extValue, extSeq);
  // The inner item is a context-specific [1] (tag 0xa1) wrapping an OCTET STRING.
  const tagged = inner.find((n) => n.tag === 0xa1);
  if (!tagged) throw new Error('attest_oid_missing_tagged');
  const taggedChildren = derChildren(extValue, tagged);
  const actualNonceNode = taggedChildren[0];
  if (!actualNonceNode || actualNonceNode.tag !== 0x04) throw new Error('attest_oid_no_octet');
  const actualNonce = extValue.subarray(actualNonceNode.valueOffset, actualNonceNode.valueOffset + actualNonceNode.length);
  if (!bytesEqual(expectedNonce, actualNonce)) throw new Error('attest_nonce_mismatch');

  // Steps 5–7: keyIdentifier check. publicKey is the uncompressed point inside
  // the leaf SPKI BIT STRING. Apple's keyId == sha256(publicKey).
  if (leafPubKey.length !== 65 || leafPubKey[0] !== 0x04) throw new Error('attest_pubkey_not_uncompressed');
  const expectedKeyId = await sha256Bytes(leafPubKey);
  const clientKeyId = base64ToBytes(keyIdB64);
  if (!bytesEqual(expectedKeyId, clientKeyId)) throw new Error('attest_keyid_mismatch');

  // Steps 8–11: parse authData. rpIdHash, aaguid, credId.
  if (authData.length < 37) throw new Error('attest_authdata_short');
  const rpIdHash = authData.subarray(0, 32);
  // flags(1), signCount(4) — initial counter must be 0 per spec.
  // Then attestedCredentialData: aaguid(16) || credIdLen(2 BE) || credId
  if (authData.length < 37 + 18) throw new Error('attest_authdata_no_credential');
  const aaguid = authData.subarray(37, 37 + 16);
  const credIdLen = (authData[37 + 16] << 8) | authData[37 + 16 + 1];
  if (authData.length < 37 + 18 + credIdLen) throw new Error('attest_authdata_credid_short');
  const credId = authData.subarray(37 + 18, 37 + 18 + credIdLen);

  const expectedRpIdHash = await sha256Bytes(new TextEncoder().encode(appAttestAppId(env)));
  if (!bytesEqual(rpIdHash, expectedRpIdHash)) throw new Error('attest_rpid_mismatch');

  const expectedAaguid = appAttestExpectedAaguid(env);
  if (!bytesEqual(aaguid, expectedAaguid)) throw new Error('attest_aaguid_mismatch');

  if (!bytesEqual(credId, clientKeyId)) throw new Error('attest_credid_mismatch');

  return { publicKey: leafPubKey };
}

/**
 * Verify a per-request assertion. Throws on failure with a stable error
 * message; returns { newCounter } on success so the caller can persist.
 *
 * `methodPathBodyHash` MUST be derived from the actual request — see
 * computeAppAttestClientDataHash. iOS computes the same value before signing.
 */
export async function verifyAppAttestAssertion({ assertionB64, storedPubKey, storedCounter, expectedClientDataHash, env }) {
  const assertion = base64ToBytes(assertionB64);
  const decoded = cborDecode(assertion);
  const signature = decoded.signature;
  const authenticatorData = decoded.authenticatorData;
  if (!signature || !authenticatorData) throw new Error('assert_bad_structure');

  const signedData = concatBytes(authenticatorData, expectedClientDataHash);
  const sigRaw = ecdsaDerToRaw(signature, 32);
  const key = await crypto.subtle.importKey(
    'raw', storedPubKey, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify'],
  );
  const ok = await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, key, sigRaw, signedData);
  if (!ok) throw new Error('assert_sig_invalid');

  if (authenticatorData.length < 37) throw new Error('assert_authdata_short');
  const rpIdHash = authenticatorData.subarray(0, 32);
  const newCounter = (authenticatorData[33] << 24)
    | (authenticatorData[34] << 16)
    | (authenticatorData[35] << 8)
    | authenticatorData[36];
  const expectedRpIdHash = await sha256Bytes(new TextEncoder().encode(appAttestAppId(env)));
  if (!bytesEqual(rpIdHash, expectedRpIdHash)) throw new Error('assert_rpid_mismatch');
  if (newCounter <= storedCounter) throw new Error('assert_counter_replay');
  return { newCounter };
}

/**
 * SHA-256("METHOD:PATH:sha256-hex(body)"). Mirrors AppAttestManager.clientDataHash
 * in the iOS app exactly — change them together.
 */
export async function computeAppAttestClientDataHash(method, path, bodyBytes) {
  const bodyHashHex = bytesToHex(await sha256Bytes(bodyBytes));
  const data = new TextEncoder().encode(`${method.toUpperCase()}:${path}:${bodyHashHex}`);
  return sha256Bytes(data);
}

// ---- KV-backed challenge + key store --------------------------------------

export async function issueAppAttestChallenge(env) {
  if (!env.QUOTA_KV) throw new Error('QUOTA_KV not bound');
  const challenge = new Uint8Array(APP_ATTEST_CHALLENGE_BYTES);
  crypto.getRandomValues(challenge);
  const b64 = bytesToBase64Url(challenge);
  await env.QUOTA_KV.put(`attest_chal:${b64}`, '1', { expirationTtl: APP_ATTEST_CHALLENGE_TTL_SECONDS });
  return { challengeBytes: challenge, challengeKey: b64 };
}

export async function consumeAppAttestChallenge(challengeBytes, env) {
  if (!env.QUOTA_KV) return false;
  const key = `attest_chal:${bytesToBase64Url(challengeBytes)}`;
  const exists = await env.QUOTA_KV.get(key);
  if (!exists) return false;
  await env.QUOTA_KV.delete(key);
  return true;
}

export async function storeAttestedKey(keyIdB64, publicKey, env) {
  if (!env.QUOTA_KV) throw new Error('QUOTA_KV not bound');
  const record = JSON.stringify({
    pub: bytesToHex(publicKey),
    counter: 0,
    env: env.APP_ATTEST_ENV === 'production' ? 'production' : 'development',
    createdAt: new Date().toISOString(),
  });
  await env.QUOTA_KV.put(`attest_key:${keyIdB64}`, record, { expirationTtl: APP_ATTEST_KEY_TTL_SECONDS });
}

export async function getAttestedKey(keyIdB64, env) {
  if (!env.QUOTA_KV) return null;
  const raw = await env.QUOTA_KV.get(`attest_key:${keyIdB64}`);
  if (!raw) return null;
  try {
    const obj = JSON.parse(raw);
    return { pub: hexToBytes(obj.pub), counter: obj.counter | 0, env: obj.env, createdAt: obj.createdAt };
  } catch {
    return null;
  }
}

export async function updateAttestedKeyCounter(keyIdB64, newCounter, env) {
  // Re-read + re-write. Race-prone under heavy concurrency, but a counter
  // race only ever lets one extra request through (the loser still has a
  // higher counter than `storedCounter`). At TestFlight scale this is fine.
  const cur = await getAttestedKey(keyIdB64, env);
  if (!cur) return;
  const next = JSON.stringify({
    pub: bytesToHex(cur.pub),
    counter: newCounter,
    env: cur.env,
    createdAt: cur.createdAt,
  });
  await env.QUOTA_KV.put(`attest_key:${keyIdB64}`, next, { expirationTtl: APP_ATTEST_KEY_TTL_SECONDS });
}

/**
 * Pull keyId + assertion headers off a request. Returns null if either is
 * missing — caller decides whether that's a 401 or a different status.
 */
export function readAppAttestHeaders(request) {
  const keyId = request.headers.get('X-Apple-AppAttest-KeyId');
  const assertion = request.headers.get('X-Apple-AppAttest-Assertion');
  if (!keyId || !assertion) return null;
  return { keyId, assertion };
}

// Test-only export of the base64 helper. Keeps base64ToBytes module-private
// while still letting routes/attest/register.js parse the registration body.
export { base64ToBytes as _base64ToBytes };
