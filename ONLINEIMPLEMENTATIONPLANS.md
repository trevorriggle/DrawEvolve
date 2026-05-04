# DrawEvolve — Online / Social Features Implementation Plan

**Status:** Planning only. No code in this document is meant to be merged as-is.
**Scope:** Profiles, posts (publishing drawings), an extensible engagement system (today: likes; later: reactions / weighted signals), comments, follows, feed (following + discovery), profile search.
**Out of scope:** New auth flows, payments, DMs/chat, notifications delivery infrastructure, moderation tooling beyond MVP report-flag, web client.

---

## 0. Current-state recap (audit summary)

This plan **extends** the existing stack — it does not redesign auth, identity, or storage primitives.

- **Auth:** SIWA + magic-link → Supabase mints an ES256 JWT (`sub` = user UUID, `aud = "authenticated"`, `app_metadata.tier ∈ {free, pro}`). iOS holds the session via the Supabase SDK; Worker validates via JWKS at `cloudflare-worker/index.js:276–305`.
- **Single Worker endpoint** today: `POST /` for feedback. Validates JWT → idempotency → rate-limits → ownership → OpenAI → persistence. We will extend the Worker with new routes that reuse the same JWT validation + KV rate-limit primitives.
- **Postgres tables that touch users:** `drawings`, `feedback_requests`, `account_deletions`, `user_preferences`, `custom_prompts`. **There is no `profiles` table.** User display info today comes from `auth.users.email`. This is the foundational gap.
- **RLS pattern:** every user-scoped table has 4 policies (`auth.uid() = user_id` on select/insert/update/delete). Worker bypasses with service-role.
- **Storage:** `drawings` bucket, private, RLS by `storage.foldername(name)[1] = auth.uid()::text`. Reads via 1h-TTL signed URLs. **This pattern blocks public viewing of someone else's drawing**, so posts need a separate read path.
- **Account deletion:** hard cascade via edge function (Storage → drawings → audit → auth.users). New social tables must `ON DELETE CASCADE` from `auth.users(id)` and the edge function must learn about them.
- **Reusable primitives:** KV-backed per-user rate limits (`rate:`, `quota:`, `ip:`, `hourly:`), `feedback_requests` log shape, ES256 JWT validation, idempotency cache, signed-URL minting.

---

## 1. Design principles for this work

1. **Extend, don't fork.** Reuse `auth.users.id` as the universal user key. Don't introduce a parallel users table.
2. **Engagement is data, not booleans.** The like system MUST be schema-stable across "binary like" → "reactions" → "weighted engagement" without a migration. The abstraction is in the schema (`reactions` row shape), the Worker contract (`POST /reactions` accepting a `kind` + `weight`), and the iOS model (`Reaction` value type). UI rendering chooses what to expose; the storage shape doesn't change. **See §4 for the full design.**
3. **Public reads are different from private reads.** Today, Postgres RLS is "owner only." Social features add a "publicly visible" axis. Every new table makes that explicit (e.g. `posts.visibility`, `profiles.is_public`).
4. **Aggregations are caches, not source of truth.** Counts (followers, likes) are denormalized for read speed but always derivable from the source rows. Recompute on conflict; don't trust the cache during deletion or moderation.
5. **The Worker is for writes that need server policy.** Reads of public content can go directly from iOS to Supabase with a public RLS policy + anon key. Writes that need rate-limiting, abuse signals, or cross-table integrity go through the Worker.
6. **Cascade deletion is a feature.** Every new table with `user_id` references `auth.users(id) ON DELETE CASCADE`. The existing `delete-account` edge function gets extended to clean up Storage paths for posts and `account_deletions` audit picks up the count.

---

## 2. Phase 0 — Foundations (must land before any social feature)

### 2.1 `profiles` table

The single most important addition. Everything else depends on it.

**Schema** (new migration `0008_profiles.sql`):

```sql
create table public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  username citext not null unique,           -- case-insensitive, lowercase canonical
  display_name text not null,                -- free-form, ≤ 50 chars
  bio text,                                   -- ≤ 280 chars
  avatar_path text,                           -- storage path in 'avatars' bucket, nullable
  is_public boolean not null default true,    -- private profile = posts hidden from non-followers
  is_searchable boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- denormalized counts (recomputable; do NOT trust during deletes)
  follower_count int not null default 0,
  following_count int not null default 0,
  post_count int not null default 0,
  constraint username_format check (username ~ '^[a-z0-9_]{3,24}$'),
  constraint display_name_length check (char_length(display_name) between 1 and 50),
  constraint bio_length check (bio is null or char_length(bio) <= 280)
);

create index profiles_username_trgm on public.profiles using gin (username gin_trgm_ops);
create index profiles_display_name_trgm on public.profiles using gin (display_name gin_trgm_ops);
```

Requires `create extension if not exists citext;` and `create extension if not exists pg_trgm;` (both built into Supabase).

**RLS:**

```sql
alter table public.profiles enable row level security;

-- Anyone authenticated can read public profiles or their own.
create policy profiles_select on public.profiles for select to authenticated
  using (is_public or user_id = auth.uid());

-- Only the owner can write.
create policy profiles_insert on public.profiles for insert to authenticated
  with check (user_id = auth.uid());
create policy profiles_update on public.profiles for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy profiles_delete on public.profiles for delete to authenticated
  using (user_id = auth.uid());
```

**Auto-create on signup:** trigger on `auth.users` insert that creates a `profiles` row with `username = 'user_' || substr(id::text, 1, 8)` and `display_name = split_part(email, '@', 1)`. This guarantees every signed-in user has a profile (and removes a "what if profile is null" branch from every consumer). Pattern matches the existing `set_default_tier_on_signup` trigger.

**Avatars storage bucket:**

- New bucket `avatars`, **public-read**, write-RLS keyed off `storage.foldername(name)[1] = auth.uid()::text`.
- Path convention: `<user_id>/avatar.jpg`. ≤ 256 KB, JPEG only (mirrors existing JPEG-only commitment).
- Avatars are public-read so the iOS feed can load them with a non-signed URL — important because feed will batch-render dozens of avatars.

**MVP scope:** auto-create profile on signup, edit display_name + bio + avatar via Worker. Username is set once at first edit and immutable thereafter (rename handling is a post-MVP problem; flag below).

**Open question — flag for clarification:**
> Q1: Should username be **immutable** post-creation (simpler, no broken @-mentions/links) or **renamable with a redirect history table** (more user-friendly)? MVP plan assumes immutable. ⚠

> Q2: Username **claim flow**: do we let users pick at signup (extra UI step), or auto-generate `user_xxxxxxxx` and force a one-time rename in Settings before they can post? MVP plan assumes auto-generate + one-time rename gate before first post. ⚠

### 2.2 New Worker endpoint shape

The Worker today is single-route. Move to a router. Suggested shape:

```
POST /                       (legacy — feedback; unchanged)
GET  /v1/me                  → returns my profile + tier + counts
PATCH /v1/profiles/me        → update display_name/bio/avatar/is_public
POST /v1/profiles/me/avatar  → presigned upload URL or direct upload proxy
GET  /v1/profiles/:username  → public profile lookup
GET  /v1/profiles/search     → ?q=foo, paginated
POST /v1/posts               → publish a drawing
DELETE /v1/posts/:id         → unpublish (soft) or delete
GET  /v1/feed/following      → ?cursor=...
GET  /v1/feed/discover       → ?cursor=...
GET  /v1/posts/:id           → single post detail (incl. comments page)
POST /v1/posts/:id/reactions → add/update reaction (extensible — see §4)
DELETE /v1/posts/:id/reactions/:kind  → remove reaction
GET  /v1/posts/:id/comments  → paginated
POST /v1/posts/:id/comments  → create
DELETE /v1/comments/:id      → delete (owner or post owner)
POST /v1/follows             → { target_user_id }
DELETE /v1/follows/:target_user_id
GET  /v1/profiles/:username/followers
GET  /v1/profiles/:username/following
POST /v1/reports             → flag content (post/comment/profile)
```

All routes use the same JWT validator (`validateJWT`) already in `cloudflare-worker/index.js:276–305`. New file structure suggestion: split `index.js` into `auth.js`, `kv.js`, `routes/feedback.js`, `routes/profiles.js`, etc. — current 1623-line `index.js` will get unwieldy fast otherwise. (Flag: this is a refactor cost we're paying once.)

**Reads-direct option:** for `GET /v1/feed/discover`, `GET /v1/profiles/:username`, `GET /v1/posts/:id`, we *can* let iOS hit Supabase REST directly with the user's JWT and rely on RLS. **Tradeoff:** simpler Worker, no caching layer, but every read traffic increase hits Postgres. **Recommendation for MVP:** route all reads through the Worker so we get a single chokepoint for caching, abuse signals, and request shape stability. Revisit at scale.

---

## 3. Posts (publishing drawings)

**Decision: separate `posts` table that references `drawings(id)`.** Do **not** mutate `drawings` to add `is_public`. Reasons:

- `drawings` is on the critique hot path; keeping it small and owner-scoped keeps RLS cheap.
- Drawings can be unpublished without losing the underlying drawing.
- A drawing could (later) be shared into multiple contexts (collections, reposts) — easier with a join table.
- Critique history JSONB stays private to the artist by default; a separate `posts` row makes the visibility boundary explicit.

### 3.1 Schema

```sql
create type post_visibility as enum ('public', 'followers', 'unlisted');
-- 'unlisted' = link-shareable but not in feeds/search.

create table public.posts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  drawing_id uuid not null references public.drawings(id) on delete cascade,
  caption text,                                    -- ≤ 500 chars
  visibility post_visibility not null default 'public',
  -- snapshot of the image at publish time, so editing the drawing later doesn't mutate the post
  image_path text not null,                        -- storage path in 'posts' bucket
  thumb_path text not null,
  width int not null,
  height int not null,
  -- denormalized counts (caches)
  reaction_count int not null default 0,
  comment_count int not null default 0,
  -- moderation
  is_deleted boolean not null default false,
  deleted_reason text,
  published_at timestamptz not null default now(),
  unique (user_id, drawing_id)                     -- one post per drawing per user
);

create index posts_published_feed on public.posts (visibility, published_at desc)
  where is_deleted = false and visibility = 'public';
create index posts_user_published on public.posts (user_id, published_at desc)
  where is_deleted = false;
create index posts_drawing on public.posts (drawing_id);
```

**RLS:**

```sql
alter table public.posts enable row level security;

-- Public posts: anyone authenticated. Followers-only: only followers (and owner).
-- Unlisted: only via direct id (RLS doesn't gate that — Worker enforces it via WHERE).
-- Owner always sees their own.
create policy posts_select on public.posts for select to authenticated
  using (
    is_deleted = false and (
      user_id = auth.uid()
      or visibility = 'public'
      or (visibility = 'unlisted')   -- relies on Worker not exposing in feeds
      or (visibility = 'followers' and exists (
        select 1 from public.follows f
         where f.follower_id = auth.uid() and f.following_id = posts.user_id
      ))
    )
  );

create policy posts_insert on public.posts for insert to authenticated
  with check (user_id = auth.uid());

create policy posts_update on public.posts for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy posts_delete on public.posts for delete to authenticated
  using (user_id = auth.uid());
```

> ⚠ **Privacy gotcha:** the `unlisted` clause in select RLS is permissive. We rely on the Worker (and any direct-RLS reads) to never list `unlisted` posts in feeds. If iOS ever reads directly via Supabase REST and queries `posts` without a visibility filter, unlisted content leaks. Mitigation: either (a) split into `feed_posts` view that filters out unlisted, or (b) keep all post reads behind the Worker. Recommend (b) for MVP.

### 3.2 Storage

New bucket `posts`, **public-read**:

- Posts are public-by-design (or followers-only). Public-read on the bucket simplifies feed rendering — no signed-URL refresh, CDN-cacheable.
- Path convention: `<user_id>/<post_id>.jpg` (full) and `<user_id>/<post_id>_thumb.jpg`.
- **Snapshot-on-publish:** when a post is created, the Worker copies (server-side) the current `drawings` storage object into the `posts` bucket. This decouples the post image from future edits to the drawing. (If we instead pointed `posts` at the `drawings` path, every drawing edit would silently rewrite the published post.)
- For `followers`-visibility posts: trickier. Two options:
  1. Keep image in **private** bucket, sign URLs in the Worker after RLS check. (Slower feed, but actually private.)
  2. Keep image in public bucket and accept "obscure URL" privacy. **Not recommended** — anyone with the URL can view.
  - **MVP recommendation:** support `public` and `unlisted` only. Defer `followers` visibility to v2 because it requires a private-image flow we don't need on day one.

### 3.3 Worker endpoints

- `POST /v1/posts` — body: `{ drawing_id, caption?, visibility }`. Worker:
  1. Validate JWT, extract user_id.
  2. Verify `drawings.id = drawing_id AND user_id = me` (existing ownership check pattern from feedback endpoint).
  3. Server-side copy of drawing image + thumb into `posts` bucket.
  4. Insert `posts` row.
  5. Increment `profiles.post_count` (in same transaction or via trigger).
  6. Return the post.
- `DELETE /v1/posts/:id` — soft delete (`is_deleted = true`). Cascades to hide reactions/comments via RLS join. Hard-delete is a separate background job that purges Storage objects after 30 days.
- `GET /v1/posts/:id` — fetch single post + first page of reactions + comments.

### 3.4 iOS UI surfaces

- **Modify `DrawingDetailView`:** add a "Publish" button that opens a publish sheet (caption + visibility picker). After publish, show a "Published" pill and link to the post.
- **Modify `GalleryView`:** show a small badge on drawings that have a post, with a long-press "Unpublish" action.
- **New `PostDetailView`:** the public-facing view of a post. Image + caption + reactions tray + comments. This is reused by the feed and by deep-links.
- **New `PublishSheet`:** SwiftUI sheet, presented over `DrawingDetailView`.

### 3.5 Privacy

- A drawing's critique history is **never** exposed via `posts`. Posts only carry the snapshotted image, caption, and counts.
- "Followers-only" deferred to v2 (see §3.2).
- Unlisted = link-shareable. Make this clear in UI copy.

### 3.6 MVP scope vs later

**MVP:** public + unlisted posts, caption, snapshot-on-publish, soft-delete.
**Later:** followers-visibility, edit caption, post collections/albums, reposts, scheduled publish, watermarking.

---

## 4. Engagement system (the extensible "likes")

**This is the most important schema decision in this plan. Get it wrong and we're migrating.**

### 4.1 Goal

Today: a binary "like" on a post.
Tomorrow: emoji reactions (👏, 🎨, 🔥, 💡).
Later: weighted engagement (a "feature" reaction worth more than a "like" in feed ranking; a "save to learn from" reaction that signals deep interest; per-tier weight modifiers).

### 4.2 Design — single `reactions` table, polymorphic by `(kind, weight, payload)`

```sql
create table public.reactions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  -- target: which entity is being reacted to
  target_type text not null check (target_type in ('post', 'comment')),
  target_id uuid not null,
  -- the reaction itself
  kind text not null default 'like',           -- 'like' | 'fire' | 'palette' | 'idea' | ... (free text, app-defined)
  weight numeric not null default 1.0,          -- ranking signal; 1.0 today, future kinds may differ
  payload jsonb,                                -- forward-compat: emoji metadata, custom values, A/B data
  created_at timestamptz not null default now(),
  -- one reaction-of-a-kind per user per target. Changing kind = update.
  unique (user_id, target_type, target_id, kind)
);

create index reactions_target on public.reactions (target_type, target_id);
create index reactions_user on public.reactions (user_id, created_at desc);
```

**Why this shape works for all three eras:**

- **Era 1 (binary like):** every row has `kind = 'like'`, `weight = 1`. Counting likes = `count(*) where target_id = ? and kind = 'like'`. UI shows a heart.
- **Era 2 (reactions):** `kind` becomes one of N values. UI swaps a heart for a tray. **Schema unchanged.** Feed code that previously did `where kind = 'like'` either drops that filter or uses `where kind in (...)`. The unique constraint (`user_id, target_type, target_id, kind`) means a user can leave one of each *kind* — matches Slack/Facebook pattern.
- **Era 3 (weighted engagement):** rankers query `sum(weight)` instead of `count(*)`. New kinds get higher/lower weights via the `kind` → weight mapping (kept in **Worker config**, not the DB, so we can A/B without migrations). The `payload` JSONB absorbs anything we didn't predict (per-tier multipliers, time decay markers, experiment IDs).
- **Idempotency:** the unique constraint makes "react twice with the same kind" a no-op via `INSERT ... ON CONFLICT DO NOTHING`. "Switch reactions" is `UPDATE` or "delete + insert."

### 4.3 The abstraction layer that makes future changes safe (this is the part to flag)

> 🔑 **The abstraction lives in three places. Every future change to engagement semantics goes through these and these only:**
>
> 1. **Worker `kind_registry`** — a config map in the Worker (not in DB) of `{ kind: { weight, allowed_targets, max_per_user, ui_hint } }`. Changing the set of valid kinds, their weights, or their rate limits is a Worker deploy, not a migration.
> 2. **Worker `POST /v1/posts/:id/reactions`** — accepts `{ kind }`, looks up weight from registry, writes the row. The endpoint is the **only** writer; iOS never writes reactions directly to Supabase.
> 3. **iOS `Reaction` value type** — encodes `kind` as a Swift `enum` with an `.unknown(String)` case so older clients survive a server-side kind addition. UI components key off `Reaction.uiHint` (provided by Worker), not a hardcoded list.

**This means:**
- Adding a new reaction kind: update Worker `kind_registry`, push iOS update with new emoji asset (or fetch from server). **No migration. No table change. No RLS change.**
- Changing a weight: Worker config flip.
- Adding "reaction with custom emoji" or "reaction with note": uses the existing `payload` column.
- Changing ranking math: Worker reads the same rows differently. Aggregations are unchanged.

### 4.4 Counts cache

`posts.reaction_count` is a denormalized count maintained by trigger:

```sql
create function tg_reactions_bump_count() returns trigger as $$
begin
  if tg_op = 'INSERT' and new.target_type = 'post' then
    update public.posts set reaction_count = reaction_count + 1 where id = new.target_id;
  elsif tg_op = 'DELETE' and old.target_type = 'post' then
    update public.posts set reaction_count = reaction_count - 1 where id = old.target_id;
  end if;
  return null;
end $$ language plpgsql;
```

(Same pattern for comments.) Era-3 weighted engagement won't use this count for ranking — it'll query `sum(weight)` live or via a periodically-refreshed materialized view. The count is for "27 reactions" UI labels only.

### 4.5 RLS

```sql
alter table public.reactions enable row level security;

-- Anyone authenticated can read reactions on content they can see.
-- (We don't enforce visibility-of-target here; we trust that target's RLS hides invisible posts upstream.
--  Worker should join through posts to filter, but this is a defense-in-depth gap to flag.)
create policy reactions_select on public.reactions for select to authenticated using (true);
create policy reactions_insert on public.reactions for insert to authenticated
  with check (user_id = auth.uid());
create policy reactions_delete on public.reactions for delete to authenticated
  using (user_id = auth.uid());
-- Update kind: allowed; effectively "switch reaction"
create policy reactions_update on public.reactions for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
```

> ⚠ **Privacy note:** `reactions_select` is permissive. If we ever introduce private posts (followers-only), reaction reads will leak the existence of reactions even when the post itself is invisible. Mitigation: either tighten the RLS to join through `posts`, or only expose reactions through the Worker. For MVP (public/unlisted only), this is acceptable.

### 4.6 Worker endpoints

- `POST /v1/posts/:id/reactions` — body: `{ kind }`. Validates kind against registry, upserts. Rate-limited per (user, post) — KV key `reactlimit:<user_id>:<post_id>`. Returns updated counts.
- `DELETE /v1/posts/:id/reactions/:kind` — removes the user's reaction of that kind.
- `GET /v1/posts/:id/reactions` — paginated. Returns `{ kind_summary: { 'like': 27, 'fire': 4 }, my_reactions: ['like'] }` for the requesting user, plus optional list of recent reactors.

### 4.7 iOS UI surfaces

- **MVP rendering:** a heart button + count under each post. Tapping = toggle `kind='like'`.
- **Forward-compat:** the Swift `Reaction` model already carries `kind` and `weight`. The reaction button view renders **whatever kinds the server says exist** for that user/post — so a future Worker rollout enabling reactions doesn't require a client release. (Practically this means: server returns `available_kinds: ["like", "fire"]` on `GET /v1/posts/:id` and the client renders that list.)

### 4.8 Comments use the same engine

Reactions on comments work for free because `reactions.target_type` already supports `'comment'`. No additional table.

---

## 5. Comments

### 5.1 Schema

```sql
create table public.comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  parent_comment_id uuid references public.comments(id) on delete cascade,  -- threading; null = top-level
  body text not null check (char_length(body) between 1 and 1000),
  is_deleted boolean not null default false,
  edited_at timestamptz,
  created_at timestamptz not null default now()
);

create index comments_post on public.comments (post_id, created_at);
create index comments_user on public.comments (user_id, created_at desc);
create index comments_parent on public.comments (parent_comment_id) where parent_comment_id is not null;
```

### 5.2 RLS

```sql
alter table public.comments enable row level security;

-- Read: anyone who can see the post can see its comments.
create policy comments_select on public.comments for select to authenticated using (
  is_deleted = false and exists (
    select 1 from public.posts p where p.id = comments.post_id
  )  -- posts RLS already filters; if the post is invisible, this returns 0.
);

-- Insert: any authenticated user, on any post they can see.
create policy comments_insert on public.comments for insert to authenticated
  with check (
    user_id = auth.uid() and exists (select 1 from public.posts p where p.id = post_id)
  );

-- Update: comment owner only (used for edits — MVP: edit your own body).
create policy comments_update on public.comments for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Delete: comment owner OR post owner (post owner can remove abusive comments on their post).
create policy comments_delete on public.comments for delete to authenticated using (
  user_id = auth.uid()
  or exists (select 1 from public.posts p where p.id = post_id and p.user_id = auth.uid())
);
```

### 5.3 Worker endpoints

- `GET /v1/posts/:id/comments?cursor=...` — keyset-paginated, oldest-first or newest-first (TBD; flag).
- `POST /v1/posts/:id/comments` — body: `{ body, parent_comment_id? }`. Rate-limited per user (`commentlimit:<user_id>`, e.g. 10/min, 100/day).
- `DELETE /v1/comments/:id` — soft-delete (preserves thread shape; renders as "[deleted]").

### 5.4 iOS UI surfaces

- **Modify `PostDetailView`:** comments section under the image (paginated, infinite scroll).
- **New `CommentComposerView`:** inline composer at bottom of `PostDetailView`. Optional reply target.
- **New `ThreadView`:** when a top-level comment has replies, tap-through opens the thread.

### 5.5 Privacy

- Comments inherit visibility from the parent post (RLS join).
- Mentions (`@username`) are MVP-deferred. Notification subsystem doesn't exist yet (see §10).
- Comment notifications: post owner gets notified, parent-commenter gets notified on reply. **Notifications delivery is out of scope; in-app inbox is MVP. Push is later.**

### 5.6 MVP scope

**MVP:** flat comments + one level of replies, soft delete, post-owner-can-delete.
**Later:** edit, full threading, mentions, rich text, image-in-comment.

---

## 6. Follow / follower system

### 6.1 Schema

```sql
create table public.follows (
  follower_id uuid not null references auth.users(id) on delete cascade,
  following_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (follower_id, following_id),
  check (follower_id <> following_id)
);

create index follows_following on public.follows (following_id, created_at desc);
create index follows_follower on public.follows (follower_id, created_at desc);
```

### 6.2 RLS

```sql
alter table public.follows enable row level security;

-- Reads: anyone authenticated can see who follows whom (Twitter-like).
-- If we later want private follower lists, gate on profiles.is_public.
create policy follows_select on public.follows for select to authenticated using (true);
create policy follows_insert on public.follows for insert to authenticated
  with check (follower_id = auth.uid());
create policy follows_delete on public.follows for delete to authenticated
  using (follower_id = auth.uid());
```

> ⚠ **Privacy question:** should follower lists be hideable? Some users may not want their follower list public. **MVP plan:** all follows are publicly readable. Flag for clarification:
> Q3: Hide follower/following lists for `profiles.is_public = false`? Or treat is_public only as "hide my posts from non-followers" (i.e. private = approved-followers gating)? ⚠

### 6.3 Counts

`profiles.follower_count` and `profiles.following_count` maintained by a trigger on `follows` (same pattern as reaction counts).

### 6.4 Worker endpoints

- `POST /v1/follows` — body: `{ target_user_id }`. Validates not-self, inserts. Rate-limited per user (`followlimit:<user_id>`, e.g. 100/day) to deter follow-spam.
- `DELETE /v1/follows/:target_user_id`
- `GET /v1/profiles/:username/followers?cursor=...`
- `GET /v1/profiles/:username/following?cursor=...`

### 6.5 iOS UI surfaces

- **New `ProfileView`:** shows display name, avatar, bio, follower/following counts (tap-through to lists), grid of posts. "Follow" button if not me.
- **New `FollowListView`:** paginated list of profiles.
- **Modify `SettingsView`:** add "Block list" entry (flag — see §10).

### 6.6 Privacy

- Block list is required from day one if posts are public. A blocked user shouldn't see your posts/profile, can't follow you, can't comment.
- Block enforcement is a join on every read — adds cost. MVP: block table + Worker enforcement on key endpoints (post detail, profile, comment create). Postgres RLS joins to `blocks` are a v2 optimization.

> ⚠ **Block table is not in this schema yet — flag for explicit add-in:** before any public posting goes live, we need a `blocks` table (`blocker_id`, `blocked_id`) and Worker enforcement on `GET /v1/profiles/:username`, `GET /v1/posts/:id`, `POST /v1/follows`, `POST /v1/posts/:id/comments`, `POST /v1/posts/:id/reactions`. Treat this as part of the posts MVP, not a later phase.

---

## 7. Feed (following + discovery)

### 7.1 Following feed

**Query** (executed in Worker):

```sql
select p.*, prof.username, prof.display_name, prof.avatar_path
from public.posts p
join public.profiles prof on prof.user_id = p.user_id
join public.follows f on f.following_id = p.user_id
where f.follower_id = $me
  and p.is_deleted = false
  and p.visibility in ('public', 'followers')
  and p.published_at < $cursor
order by p.published_at desc
limit 20;
```

Keyset pagination on `(published_at, id)`. Index `posts_user_published` covers the per-user lookup; the join to `follows` does fan-in.

**Scale flag:** for users following many accounts, this query stays cheap because `follows` lookups are indexed. At very large scale (10k+ follows × hot posters), we'd want a materialized fan-out. **Not MVP-relevant.**

### 7.2 Discovery feed

**MVP:** simple recent-public-posts feed.

```sql
select p.*, prof.username, prof.display_name, prof.avatar_path
from public.posts p
join public.profiles prof on prof.user_id = p.user_id
where p.is_deleted = false
  and p.visibility = 'public'
  and prof.is_searchable = true
  and p.published_at < $cursor
order by p.published_at desc
limit 20;
```

Index `posts_published_feed` covers this directly.

**Later (v2):** ranked discovery using `sum(reactions.weight)` over a time window. The reactions abstraction (§4) was designed for this — when we move from chronological to ranked, no schema change is needed; we just add a ranking SQL or a periodic materialized view.

### 7.3 Worker endpoints

- `GET /v1/feed/following?cursor=...` (200 rows/min/user rate limit)
- `GET /v1/feed/discover?cursor=...`

Cache discover-feed responses in KV for ~30s (every user sees the same feed for that window). Following-feed is per-user — not worth caching server-side.

### 7.4 iOS UI surfaces

- **New `FeedView`:** segmented control between "Following" and "Discover." Infinite scroll. Pull-to-refresh.
- **Modify `ContentView`:** new tab/sidebar entry for the feed.
- **New `FeedCellView`:** reusable card with avatar / name / image / caption / reactions / comments preview.

### 7.5 Privacy

- Discover never includes `is_searchable = false` profiles' posts.
- Following feed respects `posts.visibility` (so a `followers`-visibility post only shows if the viewer follows).

### 7.6 MVP scope

**MVP:** chronological following + chronological discovery, public + unlisted post types only.
**Later:** ranked discovery (using reaction weights), topic discovery (style/subject tags), "mentor" feed (posts from followed accounts whose tier is pro).

---

## 8. Profile search

### 8.1 Approach

Postgres `pg_trgm` GIN indexes on `username` and `display_name` (already created in §2.1).

```sql
select user_id, username, display_name, avatar_path, follower_count
from public.profiles
where is_searchable = true
  and (username % $q or display_name % $q
       or username ilike $q || '%' or display_name ilike '%' || $q || '%')
order by greatest(similarity(username, $q), similarity(display_name, $q)) desc
limit 20;
```

Trigram works well for typo-tolerance. For exact `@username` lookups, the unique citext index handles it directly.

### 8.2 Worker endpoint

`GET /v1/profiles/search?q=foo&cursor=...` — rate-limited per user (`searchlimit:<user_id>`, e.g. 60/min).

### 8.3 iOS UI surfaces

- **New `SearchView`:** search bar + result list. Reachable from a tab bar entry.

### 8.4 Privacy

- `is_searchable = false` profiles never appear (even on exact username match? — flag).

> Q4: When `is_searchable = false`, should `GET /v1/profiles/:username` (direct lookup by exact username) **still resolve**? Tradeoff: full unsearchable = invisible (you must already know their handle from elsewhere); partial unsearchable = "you can be linked to but not discovered." MVP plan: partial — exact lookup works, search hides. ⚠

### 8.5 MVP scope

**MVP:** username + display_name trigram search.
**Later:** bio search, search by tags/style, search-by-art-style (image embedding similarity — much later).

---

## 9. Integration with existing auth (extend, don't redesign)

This section spells out exactly what changes about the **auth flow itself**: nothing.

- **JWT validation reused as-is.** Every new Worker route calls the existing `validateJWT(token, env)` (`cloudflare-worker/index.js:276–305`). No new validators.
- **iOS session reuse.** `OpenAIManager` already pattern-attaches `Authorization: Bearer <jwt>` (`OpenAIManager.swift:161`). New API client (`SocialAPIClient`) follows the same pattern — single shared accessor for the JWT, single retry-on-refresh logic.
- **`AuthManager` unchanged externally.** It gains an internal "ensure profile exists" check on first `signedIn` transition (defensive — the trigger should have created one, but iOS treats it as a postcondition). On miss, calls `GET /v1/me` which lazily creates the profile.
- **Tier read from JWT, unchanged.** Free vs pro tier today gates feedback rate limits. For social features, tier may later gate things like "max posts per day" or "weighted reactions." For MVP, **no tier gating on social.**
- **DEBUG bypass user.** The bypass user has no Supabase session and won't hit any Worker route. Social features are inaccessible to bypass users — same as feedback today. No special handling.
- **Magic-link / SIWA branching.** Both produce the same JWT shape post-signin. Social code never inspects the auth method.

**No new auth schema, no new login surface, no new tokens.** The only new auth-adjacent thing is the profile auto-create trigger, which fires on `auth.users` insert.

---

## 10. Cross-cutting concerns

### 10.1 Notifications (in-app inbox)

Out of scope for the social-features MVP, but the data model needs a hook. Recommend adding a `notifications` table now (even if iOS doesn't render it) so events accumulate from day one:

```sql
create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null,                     -- 'follow', 'reaction', 'comment', 'reply', 'mention'
  actor_id uuid references auth.users(id) on delete set null,
  target_type text,                       -- 'post' | 'comment' | 'profile'
  target_id uuid,
  payload jsonb,
  read_at timestamptz,
  created_at timestamptz not null default now()
);

create index notifications_unread on public.notifications (user_id, created_at desc) where read_at is null;
```

- Worker writes notifications on follow / react / comment / reply.
- iOS reads via `GET /v1/notifications?cursor=...` (post-MVP UI).
- Push delivery (APNs) is a separate later effort.

### 10.2 Moderation / abuse

Public social = abuse vector. Minimums for MVP launch:

- **Block table** (see §6.6) — required, not optional.
- **Report endpoint:** `POST /v1/reports` — body `{ target_type, target_id, reason }`. Writes to `public.reports` (admin-only RLS). Reviewed manually for MVP.
- **Hard rate limits** on every write endpoint (using the existing KV primitive).
- **Image content scan:** posts upload an image. We currently rely on PencilKit-generated content (low risk of CSAM/etc.) but **once posts exist, anyone can publish anything they drew**. Flag: do we want to gate `POST /v1/posts` on a content-scan call (e.g. a moderation API)? **MVP recommendation:** skip pre-scan, log all post events to `feedback_requests`-style audit table, ship with manual report-review, add automated scanning if abuse appears. ⚠
- **Account-deletion edge function update:** must learn to clean up (or not) the new tables. With `ON DELETE CASCADE` from `auth.users`, the function doesn't need new code — but it should also nuke the new Storage paths (`posts` bucket, `avatars` bucket) and bump `account_deletions` audit row to include counts of posts/comments/reactions deleted.

### 10.3 Rate limits — reuse existing primitive

Pattern from `cloudflare-worker/index.js` (KV-backed counters with TTL). Reuse for:

| Action | KV key | Limit |
|---|---|---|
| Follow | `followlimit:<user>` | 100/day |
| Comment create | `commentlimit:<user>` | 10/min, 100/day |
| Reaction add | `reactlimit:<user>:<post>` | 10/post, 60/min |
| Post create | `postlimit:<user>` | 5/hour, 20/day (MVP — adjustable) |
| Search | `searchlimit:<user>` | 60/min |
| Report | `reportlimit:<user>` | 5/min, 50/day |

Tier-aware (pro = 2× free) following the existing `TIER_LIMITS` pattern at `cloudflare-worker/index.js:565–568`.

### 10.4 Account deletion (extend existing edge function)

Today the edge function does Storage(drawings) → drawings → audit → auth.users. With cascades in place, social tables purge automatically. New required steps:

1. Delete `avatars/<user_id>/avatar.jpg`.
2. Delete `posts/<user_id>/*.jpg` and `posts/<user_id>/*_thumb.jpg`.
3. Audit row gets new fields: `post_count_at_deletion`, `comment_count_at_deletion`, `follower_count_at_deletion` (from `profiles` cache before cascade). For abuse forensics.
4. `notifications` rows authored by the user become `actor_id = null` via `ON DELETE SET NULL` (already in schema) — preserves the recipient's history.

### 10.5 Observability

Add a `social_events` log table (or extend `feedback_requests` shape) so we can see post/comment/follow rates per user. Same write-on-success-non-blocking pattern as `feedback_requests` (`cloudflare-worker/index.js` already has the shape). MVP can be just structured `console.log` lines from the Worker → Cloudflare Logs / Logpush.

### 10.6 Storage RLS reminder

The existing `drawings` bucket policy (`storage.foldername(name)[1] = auth.uid()::text`) **does not** apply to new buckets. The `avatars` and `posts` buckets are public-read. Document this clearly. The current bucket's policy is still correct — it stays private.

### 10.7 UUID-vs-username in URLs

For deep-linking to a profile or post, decide:
- Profile URL: `drawevolve://profile/<username>` — readable, breaks if username changes (mitigated by §2.1 immutability decision).
- Post URL: `drawevolve://post/<post_id_uuid>` — always opaque; OK because posts are referenced rarely in conversation.

---

## 11. MVP rollout phases

Ordered by dependency. Each phase is shippable and testable.

**Phase A — Foundations (no user-visible change)**
- Migration `0008_profiles.sql` + auto-create trigger.
- `avatars` bucket.
- Worker: `GET /v1/me`, `PATCH /v1/profiles/me`, avatar upload.
- iOS: backfill auto-create check in `AuthManager`.

**Phase B — Profile editing UI**
- `ProfileEditView` in iOS Settings.
- Username one-time-set gate.
- New `ProfileView` (read-only, your own profile only).

**Phase C — Posts (public + unlisted only)**
- Migration `0009_posts.sql` + `posts` bucket.
- Worker: `POST /v1/posts`, `DELETE /v1/posts/:id`, `GET /v1/posts/:id`.
- iOS: `PublishSheet`, `PostDetailView`, "Publish" entry from `DrawingDetailView`.
- Soft-delete + 30-day Storage purge job.

**Phase D — Reactions (binary like only at this stage)**
- Migration `0010_reactions.sql` + counts trigger.
- Worker: `POST /v1/posts/:id/reactions`, delete, registry-config with `kind='like'` only.
- iOS: heart button on `PostDetailView`.

**Phase E — Comments**
- Migration `0011_comments.sql`.
- Worker: comment CRUD endpoints.
- iOS: `CommentComposerView`, comments in `PostDetailView`.

**Phase F — Follows + feeds + search**
- Migration `0012_follows.sql` + counts triggers.
- Migration `0013_blocks_and_reports.sql` (block list + report endpoint — required before this phase ships).
- Worker: follow CRUD, feed endpoints, search endpoint, report endpoint.
- iOS: `FeedView`, `SearchView`, `ProfileView` (others'), `FollowListView`.

**Phase G — Notifications inbox (MVP)**
- Migration `0014_notifications.sql` + Worker writes from B/D/E/F.
- iOS: simple unread-count badge + inbox view.
- No push yet.

**Post-MVP iterations**
- Reactions beyond `like` (Worker `kind_registry` change + iOS UI swap; **no schema change**).
- Followers-only post visibility (requires private-image read flow).
- Ranked discovery feed (sum of reaction weights).
- Threading depth > 1, mentions, edit comments, edit captions.
- Push notifications (APNs).
- Image moderation pipeline if abuse appears.
- Materialized fan-out for very high-follow accounts.

---

## 12. Open questions to clarify before Phase A

Collected from inline ⚠ flags above:

- **Q1.** Username immutable or renamable-with-history? (§2.1)
- **Q2.** Username chosen at signup vs auto-generated + one-time rename gate? (§2.1)
- **Q3.** Should follower/following lists be hideable for `is_public = false` profiles? (§6.2)
- **Q4.** Should `is_searchable = false` profiles still resolve via direct username lookup? (§8.4)
- **Q5.** Pre-publish content-scan on post images, or audit-only with manual report review for MVP? (§10.2)
- **Q6.** Do we want `followers`-visibility posts in MVP or defer to v2? Plan currently defers. (§3.2)
- **Q7.** Comment ordering default — oldest-first or newest-first? (§5.3)
- **Q8.** Should the existing single-route Worker be refactored into multi-route now (alongside Phase A) or grow organically? Plan recommends now to avoid `index.js` bloat. (§2.2)
- **Q9.** Is there an appetite for the Worker to broker some reads (cacheable), or do we want iOS → Supabase REST direct for reads via RLS? Plan recommends Worker-brokered for MVP to keep one chokepoint. (§2.2)
- **Q10.** Tier-gating on social writes (post limits per day, max followers, etc.) — none in MVP, but is there a product intent? Flag if pro should get something here. (§10.3)

---

## 13. What is explicitly NOT being designed here

So we don't accidentally drift into them:

- **DMs / chat.** Different infra (real-time, encryption questions).
- **Live drawing collaboration.** Out of scope.
- **Web client.** This plan is iOS-only.
- **Mentor matching / paid critiques.** That's a payments + matchmaking product on top of social — separate plan.
- **Public API for third parties.** Worker endpoints are app-only.
- **Cross-app sharing / Activity sheet.** Trivial later add-on.
- **Anonymous posting.** Every post requires a profile.

---

*End of plan. Awaiting answers to Q1–Q10 before starting Phase A.*
