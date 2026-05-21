// =============================================================================
// Drawing version history — snapshot promote + telemetry
// =============================================================================
//
// Snapshot capture flow (commit 7 wires this up):
//
//   1. iOS uploads a layered bundle (manifest + composite + thumb + per-layer
//      PNGs) to <user>/<drawing>/snapshots/_pending/<client_request_id>/
//      in parallel with the critique POST.
//   2. After OpenAI returns, this module's promoteSnapshot moves that bundle
//      to <user>/<drawing>/snapshots/<sequence>/ and returns a pointer for
//      the worker to embed in the CritiqueEntry's `snapshot` field.
//
// Manifest-last sentinel: manifest.json is the final file written to the
// destination, so the destination-exists short-circuit at the top of
// promoteSnapshot can use it to detect "prior promote completed" without
// risk of confusing a partial copy for a full one.
//
// Source-missing retry: 3 attempts at 1s / 2s / 3s backoff on the per-file
// copy when Supabase Storage reports the source object doesn't exist yet.
// This tolerates the common TestFlight case where the iOS upload is still
// in flight when promote starts (5-10MB on LTE = 5-15s; OpenAI is 5-15s;
// real overlap, not edge). Truly-failed uploads bubble out after retries
// and the caller in routes/feedback.js sets snapshot: null on the entry
// (graceful degradation).
//
// This module is the only place in the worker that touches Supabase
// Storage directly (everything else flows through Postgres via the
// service-role REST API). fetcher is dependency-injected so tests can
// stub without monkey-patching globalThis.fetch.

const BUCKET_ID = 'drawings';
const RETRY_BACKOFF_MS = [1000, 2000, 3000];
const COUNTER_TTL_SECONDS = 30 * 86400;

/**
 * Promote a pending snapshot folder to a numbered snapshot folder. Returns
 * the SnapshotPointer object to embed in the CritiqueEntry. Throws on any
 * unrecoverable error — caller handles graceful degradation by setting
 * snapshot: null on the entry.
 *
 * Caller contract: only invoke when iOS sent all three of layer_count /
 * total_bytes / format_version in the request body. The routes/feedback.js
 * wiring gates on field presence; this function assumes they're populated.
 */
export async function promoteSnapshot({
  env,
  userId,
  drawingId,
  clientRequestId,
  sequenceNumber,
  layerCount,
  totalBytes,
  formatVersion,
  fetcher = fetch,
  sleep = (ms) => new Promise((r) => setTimeout(r, ms)),
}) {
  if (!env?.SUPABASE_URL || !env?.SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error('promoteSnapshot env not configured');
  }
  const fromPrefix = `${userId}/${drawingId}/snapshots/_pending/${clientRequestId}`;
  const toPrefix = `${userId}/${drawingId}/snapshots/${sequenceNumber}`;

  // Sentinel: if destination manifest already exists, prior promote
  // completed (manifest is the last write so its presence implies the rest
  // landed). Treat as success — return the pointer and skip copy/delete.
  if (await headObject({ env, key: `${toPrefix}/manifest.json`, fetcher })) {
    return buildSnapshotPointer({ toPrefix, layerCount, totalBytes, formatVersion });
  }

  // Step 1: data files in parallel (manifest excluded). Each copy has its
  // own source-missing retry to tolerate slow uploads.
  const dataFiles = [
    ...Array.from({ length: layerCount }, (_, i) => `layer-${i}.png`),
    'composite.jpg',
    'thumb.jpg',
  ];
  await Promise.all(
    dataFiles.map((file) =>
      copyObjectWithRetry({
        env,
        sourceKey: `${fromPrefix}/${file}`,
        destKey: `${toPrefix}/${file}`,
        fetcher,
        sleep,
      })
    )
  );

  // Step 2: manifest LAST, sequential. Its presence at the destination is
  // the idempotency sentinel for retry.
  await copyObjectWithRetry({
    env,
    sourceKey: `${fromPrefix}/manifest.json`,
    destKey: `${toPrefix}/manifest.json`,
    fetcher,
    sleep,
  });

  // Step 3: delete sources in parallel. Order doesn't matter — the
  // destination is fully written by this point. Failures here are logged
  // but don't propagate: an orphan _pending bundle is harmless (a later
  // GC cron will clean it up) and shouldn't fail the promote.
  const allFiles = [...dataFiles, 'manifest.json'];
  await Promise.all(
    allFiles.map(async (file) => {
      try {
        await deleteObject({ env, key: `${fromPrefix}/${file}`, fetcher });
      } catch (err) {
        console.warn('[snapshot.promote] cleanup delete failed', {
          key: `${fromPrefix}/${file}`,
          error_message: err.message,
        });
      }
    })
  );

  return buildSnapshotPointer({ toPrefix, layerCount, totalBytes, formatVersion });
}

/**
 * Wraps copyObject with a source-missing retry. Tolerates the in-flight
 * upload case (3 attempts, 1s/2s/3s backoff = 6s total max wait). Other
 * errors (auth, network, etc.) propagate immediately.
 */
export async function copyObjectWithRetry({ env, sourceKey, destKey, fetcher = fetch, sleep = (ms) => new Promise((r) => setTimeout(r, ms)) }) {
  for (let attempt = 0; attempt <= RETRY_BACKOFF_MS.length; attempt++) {
    try {
      return await copyObject({ env, sourceKey, destKey, fetcher });
    } catch (err) {
      if (!isSourceMissing(err) || attempt === RETRY_BACKOFF_MS.length) {
        throw err;
      }
      await sleep(RETRY_BACKOFF_MS[attempt]);
    }
  }
}

/**
 * "Source object does not exist" detector. Supabase Storage returns 404
 * with a JSON error payload when the source key is missing; we accept any
 * 404 or a "not found" substring in the error message as the signal.
 *
 * Exported for tests; not part of the public API.
 */
export function isSourceMissing(err) {
  if (!err) return false;
  if (err.status === 404) return true;
  if (typeof err.code === 'string' && /not.?found/i.test(err.code)) return true;
  if (typeof err.message === 'string' && /not.?found|does not exist/i.test(err.message)) return true;
  return false;
}

/**
 * Storage object copy via Supabase Storage REST. Service-role auth.
 *
 * Throws an Error with `.status` set to the response status code on
 * failure (so isSourceMissing can detect 404).
 */
async function copyObject({ env, sourceKey, destKey, fetcher = fetch }) {
  const url = `${env.SUPABASE_URL}/storage/v1/object/copy`;
  const res = await fetcher(url, {
    method: 'POST',
    headers: {
      apikey: env.SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      bucketId: BUCKET_ID,
      sourceKey,
      destinationKey: destKey,
    }),
  });
  if (!res.ok) {
    const body = await safeReadText(res);
    const err = new Error(`copyObject HTTP ${res.status}: ${body}`);
    err.status = res.status;
    throw err;
  }
}

/**
 * Storage object delete via Supabase Storage REST. Service-role auth.
 *
 * Throws an Error with `.status` set on failure. Used in best-effort
 * source cleanup — callers are expected to catch + log rather than
 * propagate (orphan _pending objects are harmless).
 */
async function deleteObject({ env, key, fetcher = fetch }) {
  const url = `${env.SUPABASE_URL}/storage/v1/object/${BUCKET_ID}/${key}`;
  const res = await fetcher(url, {
    method: 'DELETE',
    headers: {
      apikey: env.SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
    },
  });
  if (!res.ok) {
    const body = await safeReadText(res);
    const err = new Error(`deleteObject HTTP ${res.status}: ${body}`);
    err.status = res.status;
    throw err;
  }
}

/**
 * HEAD-equivalent existence check via the Supabase Storage object info
 * endpoint. Returns true if the object exists, false on 404. Other
 * errors (auth, network) propagate.
 *
 * Used by promoteSnapshot's sentinel short-circuit. Service-role auth.
 */
async function headObject({ env, key, fetcher = fetch }) {
  const url = `${env.SUPABASE_URL}/storage/v1/object/info/authenticated/${BUCKET_ID}/${key}`;
  const res = await fetcher(url, {
    method: 'GET',
    headers: {
      apikey: env.SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
    },
  });
  if (res.status === 404) return false;
  if (!res.ok) {
    const body = await safeReadText(res);
    // Supabase storage info endpoint returns HTTP 400 wrapping a
    // 404-shaped JSON body for "object not found" — observed in
    // prod on 2026-05-21 with body
    //   {"statusCode":"404","error":"not_found","message":"Object not found"}
    // Accept both the clean 404 above and this wrapped form here.
    // Other non-ok statuses (auth, network, server) still propagate.
    if (/"statusCode"\s*:\s*"404"|"error"\s*:\s*"not_?found"|Object not found/i.test(body)) {
      return false;
    }
    const err = new Error(`headObject HTTP ${res.status}: ${body}`);
    err.status = res.status;
    throw err;
  }
  return true;
}

/**
 * Pure builder for the SnapshotPointer JSON that goes into a CritiqueEntry.
 * Exported for tests; called from promoteSnapshot.
 */
export function buildSnapshotPointer({ toPrefix, layerCount, totalBytes, formatVersion }) {
  return {
    manifest_path: `${toPrefix}/manifest.json`,
    composite_path: `${toPrefix}/composite.jpg`,
    thumb_path: `${toPrefix}/thumb.jpg`,
    format_version: formatVersion,
    layer_count: layerCount,
    total_bytes: totalBytes,
  };
}

// =============================================================================
// Telemetry — daily KV counters
// =============================================================================
//
// One pair of counters per UTC day: snapshot:success:YYYY-MM-DD and
// snapshot:failure:YYYY-MM-DD. Read via `wrangler kv key list
// --binding=QUOTA_KV --prefix=snapshot:` for a daily ops check.
//
// Read-then-write under contention can lose a few increments. Bounded
// undercount (a few percent at peak) is acceptable for a health signal.
// Migrate to Durable Objects if/when accuracy matters.

/**
 * Bump the daily snapshot success/failure counter in QUOTA_KV. Outcome is
 * either 'success' or 'failure'. Date is UTC. Caller typically wraps in
 * ctx.waitUntil — failures here must never propagate.
 */
export async function incrementSnapshotCounter(env, outcome, now = () => new Date()) {
  if (!env?.QUOTA_KV) return;
  if (outcome !== 'success' && outcome !== 'failure') return;
  try {
    const date = now().toISOString().slice(0, 10);
    const key = `snapshot:${outcome}:${date}`;
    const raw = await env.QUOTA_KV.get(key);
    const current = parseInt(raw || '0', 10);
    const next = Number.isFinite(current) ? current + 1 : 1;
    await env.QUOTA_KV.put(key, String(next), { expirationTtl: COUNTER_TTL_SECONDS });
  } catch (err) {
    // Telemetry write must never affect critique flow. Swallow + log.
    console.warn('[snapshot.counter] write failed', { outcome, error_message: err.message });
  }
}

async function safeReadText(res) {
  try {
    return await res.text();
  } catch {
    return '';
  }
}
