//
//  Drawing.swift
//  DrawEvolve
//
//  Phase 3 (cloud sync): image bytes no longer live on the model. The
//  cloud-truth row carries `storagePath` (`<user_id>/<id>.jpg`); the
//  pixels themselves live in Supabase Storage and the local disk cache.
//  Views fetch image bytes via CloudDrawingStorageManager (thumbnail
//  accessor for gallery cells, async loadFullImage for the detail/canvas
//  views).
//
//  Layered drawings (migration 0010, ONLINELAYERSTORE.md): the row may
//  also carry `manifestPath` pointing at `<user>/<id>/manifest.json`. A
//  drawing is "layered" iff `manifestPath != nil`. `storagePath` becomes
//  optional at the schema level but in our writer we always also upload
//  a composite, so `storagePath` is set on every row this client writes.
//
//  Codable is used both for the local metadata cache (Documents/
//  DrawEvolveCache/metadata/<id>.json) and for PostgREST round-trips
//  with the `drawings` table — column names and field names line up via
//  CodingKeys.
//

import Foundation

struct Drawing: Codable, Identifiable {
    let id: UUID
    let userId: UUID
    var title: String
    var storagePath: String?       // "<user_id>/<id>.jpg" (legacy) or "<user_id>/<id>/composite.jpg" (layered).
    let createdAt: Date
    var updatedAt: Date
    var feedback: String?          // Most recent feedback summary
    var context: DrawingContext?
    var critiqueHistory: [CritiqueEntry]

    // Layered storage (migration 0010, ONLINELAYERSTORE.md §5.2).
    var manifestPath: String?      // "<user>/<id>/manifest.json"; nil = legacy flat
    var formatVersion: Int?        // manifest schema version when this row was written
    var layerCount: Int?
    var totalBytes: Int64?         // sum of layer + composite + thumb bytes
    var version: Int               // optimistic-concurrency token (server bumps on UPDATE)

    // Composition / "Eye Test" intent marker (migration 0015). User's
    // intended focal point in normalized document coords, top-left
    // origin. Optional — most drawings will never have one. v1 stores
    // a single point; v2 may extend to a ranked list (`IntentMarker`'s
    // Codable shape would change).
    var intentMarker: IntentMarker?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case title
        case storagePath = "storage_path"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case feedback
        case context
        case critiqueHistory = "critique_history"
        case manifestPath = "manifest_path"
        case formatVersion = "format_version"
        case layerCount = "layer_count"
        case totalBytes = "total_bytes"
        case version
        case intentMarker = "intent_marker"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        userId = try container.decode(UUID.self, forKey: .userId)
        title = try container.decode(String.self, forKey: .title)
        // Normalize storage_path to lowercase on decode. Cloud responses are
        // already lowercase (the encoder writes lowercase, Postgres preserves
        // text exactly). This branch matters for stale local cache entries
        // written by pre-fix builds: they get auto-corrected the moment
        // they're hydrated, so subsequent uploads/downloads/deletes use the
        // RLS-compatible lowercase path without a manual cache flush.
        storagePath = try container.decodeIfPresent(String.self, forKey: .storagePath)?.lowercased()
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        feedback = try container.decodeIfPresent(String.self, forKey: .feedback)
        context = try container.decodeIfPresent(DrawingContext.self, forKey: .context)
        critiqueHistory = try container.decodeIfPresent([CritiqueEntry].self, forKey: .critiqueHistory) ?? []
        manifestPath = try container.decodeIfPresent(String.self, forKey: .manifestPath)?.lowercased()
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion)
        layerCount = try container.decodeIfPresent(Int.self, forKey: .layerCount)
        totalBytes = try container.decodeIfPresent(Int64.self, forKey: .totalBytes)
        // Pre-0010 cached rows have no `version`; default to 1 so optimistic-
        // concurrency comparisons against fresh server rows still make sense.
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        intentMarker = try container.decodeIfPresent(IntentMarker.self, forKey: .intentMarker)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Encode UUID columns as lowercase strings so the values written to
        // Postgres stay consistent with auth.uid()::text (lowercase) and with
        // the storage paths constructed elsewhere. Postgres uuid columns
        // normalize internally so case wouldn't break the comparison, but
        // keeping every wire-format UUID lowercase means the temporary
        // lower() wrappers in the RLS policies can be removed once iOS is
        // fully consistent.
        try container.encode(id.uuidString.lowercased(), forKey: .id)
        try container.encode(userId.uuidString.lowercased(), forKey: .userId)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(storagePath, forKey: .storagePath)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(feedback, forKey: .feedback)
        try container.encodeIfPresent(context, forKey: .context)
        try container.encode(critiqueHistory, forKey: .critiqueHistory)
        try container.encodeIfPresent(manifestPath, forKey: .manifestPath)
        try container.encodeIfPresent(formatVersion, forKey: .formatVersion)
        try container.encodeIfPresent(layerCount, forKey: .layerCount)
        try container.encodeIfPresent(totalBytes, forKey: .totalBytes)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(intentMarker, forKey: .intentMarker)
    }

    init(
        id: UUID,
        userId: UUID,
        title: String,
        storagePath: String?,
        createdAt: Date,
        updatedAt: Date,
        feedback: String? = nil,
        context: DrawingContext? = nil,
        critiqueHistory: [CritiqueEntry] = [],
        manifestPath: String? = nil,
        formatVersion: Int? = nil,
        layerCount: Int? = nil,
        totalBytes: Int64? = nil,
        version: Int = 1,
        intentMarker: IntentMarker? = nil
    ) {
        self.id = id
        self.userId = userId
        self.title = title
        self.storagePath = storagePath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.feedback = feedback
        self.context = context
        self.critiqueHistory = critiqueHistory
        self.manifestPath = manifestPath
        self.formatVersion = formatVersion
        self.layerCount = layerCount
        self.totalBytes = totalBytes
        self.version = version
        self.intentMarker = intentMarker
    }

    /// True iff this drawing has a layered representation (manifest + per-layer PNGs)
    /// available in cloud Storage. Legacy drawings only have a flat composite.
    var isLayered: Bool { manifestPath != nil }
}

// MARK: - Cloud upsert payload (Phase 5d)

/// Wire shape for upserting a drawing row to PostgREST. **Worker is the sole
/// writer to `critique_history` after Phase 5d — do not PATCH this field
/// from the client.** Including it here would race with the Worker's
/// `append_critique` RPC and could clobber server-written entries on the next
/// save. The column has a `default '[]'::jsonb` in the schema, so omitting
/// it on INSERT initializes it correctly; omitting it on UPDATE leaves the
/// existing value alone, which is exactly what we want.
///
/// The optimistic-concurrency `version` column is also omitted: the
/// `bump_drawing_version` trigger increments it server-side on UPDATE, and
/// passing a value would either no-op (trigger overrides) or, if a future
/// version of the trigger respects client values, race with concurrent saves.
/// Conflict-detection is wired by adding a `where version = N` predicate at
/// the upsert call site, not by sending `version` in the body.
struct DrawingUpsertPayload: Encodable {
    let drawing: Drawing

    private enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case title
        case storagePath = "storage_path"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case feedback
        case context
        case manifestPath = "manifest_path"
        case formatVersion = "format_version"
        case layerCount = "layer_count"
        case totalBytes = "total_bytes"
        case intentMarker = "intent_marker"
        // critiqueHistory + version deliberately omitted — see doc comment above.
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(drawing.id.uuidString.lowercased(), forKey: .id)
        try container.encode(drawing.userId.uuidString.lowercased(), forKey: .userId)
        try container.encode(drawing.title, forKey: .title)
        try container.encodeIfPresent(drawing.storagePath, forKey: .storagePath)
        try container.encode(drawing.createdAt, forKey: .createdAt)
        try container.encode(drawing.updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(drawing.feedback, forKey: .feedback)
        try container.encodeIfPresent(drawing.context, forKey: .context)
        try container.encodeIfPresent(drawing.manifestPath, forKey: .manifestPath)
        try container.encodeIfPresent(drawing.formatVersion, forKey: .formatVersion)
        try container.encodeIfPresent(drawing.layerCount, forKey: .layerCount)
        try container.encodeIfPresent(drawing.totalBytes, forKey: .totalBytes)
        try container.encodeIfPresent(drawing.intentMarker, forKey: .intentMarker)
    }
}
