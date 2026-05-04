// POST /attest/register — verify an iOS App Attest attestation and store the
// resulting public key under attest_key:<keyId> in QUOTA_KV. Runs WITHOUT JWT
// validation: registration must be reachable on first launch. Once the
// device is registered, every JWT-gated request also requires a per-request
// assertion from this same key (see routes/feedback.js).

import {
  verifyAppAttestAttestation,
  consumeAppAttestChallenge,
  storeAttestedKey,
  _base64ToBytes,
} from '../../middleware/app-attest.js';
import { jsonResponse } from '../../lib/http.js';

export async function handleAttestRegister(request, env, ctx) {
  try {
    const body = await request.json().catch(() => null);
    if (!body || typeof body !== 'object') {
      return jsonResponse({ error: 'invalid_body' }, 400);
    }
    const { keyId, attestation, challenge } = body;
    if (typeof keyId !== 'string' || typeof attestation !== 'string' || typeof challenge !== 'string') {
      return jsonResponse({ error: 'invalid_fields' }, 400);
    }
    let challengeBytes;
    try { challengeBytes = _base64ToBytes(challenge); }
    catch { return jsonResponse({ error: 'invalid_challenge_b64' }, 400); }
    const fresh = await consumeAppAttestChallenge(challengeBytes, env);
    if (!fresh) return jsonResponse({ error: 'challenge_expired_or_unknown' }, 400);

    let result;
    try {
      result = await verifyAppAttestAttestation({
        keyIdB64: keyId, attestationB64: attestation, challengeBytes, env,
      });
    } catch (err) {
      if (err?.code === 'attest_root_not_pinned') {
        console.error('[attest/register] root CA not pinned — refusing to verify');
        return jsonResponse({ error: 'attest_root_not_pinned' }, 500);
      }
      console.log('[attest/register] verification failed', err?.message);
      return jsonResponse({ error: 'attestation_invalid' }, 400);
    }
    await storeAttestedKey(keyId, result.publicKey, env);
    return jsonResponse({ ok: true });
  } catch (err) {
    console.error('[attest/register] internal', err?.message);
    return jsonResponse({ error: 'internal_error' }, 500);
  }
}
