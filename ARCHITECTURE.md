# FrameStation — Architecture

A self-hosted photo and video library for a family, running on a Synology NAS,
with native clients for iOS, iPadOS, macOS, and tvOS.

Replaces Synology Photos entirely. Not a wrapper around it.

---

## 1. Scope and scale

| | |
|---|---|
| Users | 3–4 family members; 2 heavy contributors |
| Library | 500–800 GB → est. **~100,000 photos + ~3,000 videos** |
| NAS | Synology DS920+ (Celeron J4125, 4 cores, QuickSync), **8 GB RAM**, DSM 7.2+ |
| Deployment | Private. One NAS, one household. Not distributed to other people. |
| Clients | iOS + iPadOS (full), macOS (view-only), tvOS (view-only) |
| Remote access | Existing DDNS + port forward + Let's Encrypt cert, via DSM reverse proxy |

Deliberately **out of scope for v1**: face recognition, object/semantic search,
end-to-end encryption, sharing outside the household, web client.

---

## 2. Decisions locked

| Decision | Choice | Rationale |
|---|---|---|
| Backend | Swift/Vapor service + Postgres 16, in Container Manager | File Station API cannot express query, attribution, delta sync, or notifications at 100k scale |
| Storage | Content-addressed blobs (SHA-256), one DSM shared folder | Free dedupe, idempotent/resumable uploads, space membership is a DB row not a file path |
| Per-user folders | **No** | Would force every family member to be a DSM account and bake space membership into the filesystem |
| Filesystem | Btrfs volume | Snapshots + checksums; hardlinked browsable tree costs nothing |
| Images | libvips + libheif | 4–8× faster and far lower memory than ImageMagick |
| Derivative format | JPEG, not HEIC | Encoding HEIC needs an x265 encoder the container otherwise doesn't carry; at 256 px the saving is a few KB. HEIC *decode* still works — that's libheif |
| Metadata authority | Device wins on capture time and dimensions; server fills the rest | `PHAsset.creationDate` is reliable where EXIF is often absent, wrong, or timezone-naive |
| Video | Own ffmpeg build in container | DSM's HEVC licensing removal doesn't apply; QuickSync via `/dev/dri` when needed |
| Transcoding | Lazy, on first remote playback, cached | Most videos are never watched away from home |
| Auth | **DSM credentials exchanged server-side for a device token** | One password per person, managed in DSM. The app sends them once over TLS; the server validates against DSM on localhost and returns its own token. The Keychain stores the token, never the password — so a stolen phone is not a compromised NAS account, and DSM's API is never exposed |
| Per-user data | One database, one library per user, plus a browsable per-user folder tree | Separate databases per user would make Family Shared impossible — you cannot join across databases, so shared spaces, attribution, and cross-user dedup all break |
| Video playback | Direct play of the original over HTTP Range | AVPlayer streams and seeks natively at 1080p and 4K with no transcode and no quality loss. HLS ladders deferred until 4K-over-cellular actually hurts |
| Device deletions | NAS copy is **kept** | The NAS is the archive of record; that's the point |
| Push | APNs direct from container | Household deployment — the `.p8` key never leaves your NAS |
| Search v1 | Metadata only: date, place, camera, media type, uploader | Face/semantic search deferred; no ML runtime in the container |
| Reverse geocoding | Offline, GeoNames cities1000 baked into the image | The alternative is 100,000 API requests carrying the family's complete location history to a third party |

### DSM as the identity provider

The app collects a DSM username and password **once**, at sign-in, and posts
them to FrameStation over TLS. The server calls `SYNO.API.Auth` on
`127.0.0.1:5000` — never over the network — and on success creates or matches a
FrameStation user and returns a device token.

What this buys: family members use the password they already have, accounts are
managed in DSM's user list, and there is exactly one place to revoke access.

What it deliberately avoids: DSM credentials stored on the device, DSM's API
reachable from the internet, and a lost phone escalating into NAS access. The
Keychain holds only the FrameStation token, which is scoped to this app and
revocable server-side without touching the DSM account.

The invite-code flow stays for accounts that have no DSM user.

### Backend language

**Swift + Vapor 4.** One language across server and clients, authored and
debugged in Xcode, and — the real prize — a shared `FrameStationAPI` package of
request/response types imported by *both* the server and the apps, so an API
contract change becomes a compile error on both sides instead of a runtime
surprise.

Go was the earlier pick on the theory that its libvips bindings mattered. That
argument doesn't survive contact: video work is an `ffmpeg` shell-out in either
language, libvips is reachable from Swift through C interop, and a solo
maintainer being unable to set a breakpoint in their own server is a larger
ongoing cost than a slightly heavier runtime. On a J4125 serving four users,
neither the image size nor the runtime overhead is measurable.

**No Fluent.** The schema in §5 is written as explicit DDL and the interesting
queries — timeline bucket aggregation, `change_log` deltas, advisory locks —
are ones an ORM actively obstructs. The server uses **PostgresKit/SQLKit**
directly with hand-written SQL migrations.

---

## 3. Sizing

Derived from ~103,000 assets:

| Item | Size | Notes |
|---|---|---|
| Originals | 500–800 GB | Stored verbatim, never re-encoded |
| `thumb-256` + `thumb-512` | **~7 GB** | Generated eagerly at ingest |
| `preview-2048` | up to ~40 GB | Generated **lazily** on first full-screen view, LRU-capped |
| Postgres | ~250 MB | ~2 KB/row including EXIF JSON, plus indexes |
| ThumbHash | 2.5 MB total | 25 bytes/asset, ships inside the timeline manifest |

**Import cost on the J4125:** the hashing pass is disk-bound — 800 GB at
~175 MB/s ≈ 75 minutes. Eager 256/512 thumbnails across 4 cores add roughly
1–2 hours. Deferring `preview-2048` is what keeps this an overnight job rather
than a multi-day one.

**Memory during import.** Four vips lanes thumbnailing 24 MP HEICs can reach
~400 MB each, plus Postgres and the Vapor process. The 8 GB in this machine
makes that comfortable; on the stock 4 GB it would have been a real OOM risk
and the lane count would have needed capping via
`FRAMESTATION_DERIVATION_LANES`.

---

## 4. Storage layout

One DSM shared folder, one service account. No per-user folders.

```
/volume1/framestation/
  blobs/ab/cd/abcd1234….heic          ← SHA-256 named, 2-level shard
  derivatives/ab/cd/abcd1234…/
      thumb-256.heic
      thumb-512.heic
      preview-2048.heic               ← lazy
      poster.jpg                      ← video first frame
      hls/                            ← lazy, LRU-evictable
  incoming/<uploadSessionId>/         ← chunk staging
  browse/<user>/2026/07/IMG_4821.heic ← hardlinks, zero extra space
  pgdata/
```

### Browsable trees

Each person sees their own library in DSM, and shared spaces separately:

```
/volume1/homes/<DSM user>/FrameStation/MobileBackup/<device>/2026/07/…   ← private
/volume1/FrameStation/Shared/<Space Name>/2026/07/…                      ← shared
```

These are **reflinks** (`cp --reflink`), not hardlinks. Measured on the DS920+:
`/volume1/FrameStation` and `/volume1/homes` report different device numbers
(49 vs 40) because Synology makes every shared folder its own Btrfs subvolume,
and **hardlinks cannot cross subvolumes** — `ln` fails with `Invalid cross-device
link`. Reflinks can, and were verified working there.

Reflinks are the better primitive anyway: they share extents so the space cost
is near zero, but they diverge on write. With a hardlink, editing the copy in
File Station would silently corrupt the canonical blob.

Privacy comes from DSM itself — `homes/<user>` is private to that user and to
administrators, the same mechanism Synology Photos uses for its personal space.
The trees are a view, not the source of truth: deleting a file in File Station
does not remove it from FrameStation.

**Originals are stored byte-for-byte.** Re-encoding destroys HDR gain maps,
ProRAW, depth data, and Live Photo pairing. There is no case where the server
rewrites an original.

---


### Capture timezone: EXIF first, device offset only as a fallback

`PHAsset.creationDate` is an absolute instant, not a wall clock. Photos builds it
by reading the file: when EXIF carries `OffsetTimeOriginal` that offset is
authoritative, and when it does not, Photos interprets the naive timestamp in the
*device's* timezone. So neither value alone is right for every asset.

The client therefore sends two fields. `capturedTZOffset` is the offset the file
itself records; `capturedTZOffsetFallback` is the uploading device's offset for
that date (`secondsFromGMT(for:)`, so DST is handled — a March 2011 photo resolves
to EST, not EDT). Derivation resolves them as
`COALESCE(captured_tz_off, <exif>, tz_off_fallback)` and recomputes
`local_captured_at` afterwards.

This matters because `local_captured_at` is what the timeline buckets on. An
earlier build sent the phone's current offset as if it were fact, which overwrote
real EXIF metadata: a Tokyo photo taken at 08:00 on May 20 landed under May 19
19:00 — the wrong day, not merely the wrong hour.


### Push: batching is the feature

Forty photos finishing their evening backup would be forty notifications, and a
family turns those off permanently after one night of it. `activity_sessions`
accumulates counts per (space, user) while uploads keep arriving; the sweeper
closes a session once it has been idle (default five minutes, `FRAMESTATION_ACTIVITY_IDLE_SECONDS`)
and sends exactly one summary. Past 200 items `is_bulk` trips and the message
collapses to "Morgan backed up 8,240 items" so a first-run device backup doesn't
announce itself photo by photo.

Closing and notifying are separate steps: the claiming `UPDATE` sets `closed_at`
so a second sweeper can't pick the session up, and `notified_at` records that the
push actually went out.

Push degrades rather than fails. With no `.p8` configured the client logs what it
would have sent and reports success, which is what lets the smoke tests verify
wording and fan-out without Apple credentials — and means a misconfigured NAS
drops notifications instead of wedging the sweeper.

Two things that are easy to get wrong and are handled explicitly: ES256 wants the
raw `r||s` signature (`rawRepresentation`), not the DER form Apple rejects; and a
sandbox token sent to the production host comes back `BadDeviceToken`, so the
environment travels with the token and the client reports it per build
configuration.


### Why playback URLs are signed rather than bearer-authenticated

AVPlayer fetches media itself, outside the `URLSession` the rest of the API uses,
so it cannot carry the bearer token. The documented alternative is an
`AVAssetResourceLoaderDelegate`, but a hand-written one has to reimplement byte
ranges correctly — and it still wouldn't help AirPlay, where an Apple TV fetches
the URL on its own and never sees a header we set. Since tvOS is a target and
AirPlay is the obvious way to watch these on a television, the URL has to stand
on its own.

So `GET /v1/assets/:id/playback` mints a URL carrying `u`, `exp` and an
HMAC-SHA256 `sig` over all three. The user is inside the signed message, so
substituting another id invalidates the signature rather than granting access,
and membership is re-checked when the URL is redeemed — revoking someone takes
effect immediately rather than at expiry.

The tradeoff, stated plainly: a signed URL appears in the server's access log. It
is scoped to one asset, expires in five minutes, and the log lives on the same
NAS as the blobs it points at.

Direct play only. `ffmpeg` transcoding 4K on a J4125 is not on the table, and on
a home network it isn't needed — the file streams as-is and a seek fetches only
the bytes being watched. HLS would slot in as a different `kind` in
`PlaybackURLResponse` without changing the call site.

## 5. Database

One Postgres instance, one schema, all users. The core idea is separating the
**immutable file** (`assets`) from **its placement in a space**
(`space_assets`).

```sql
CREATE TABLE users (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  display_name  text NOT NULL,
  avatar_sha256 text,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE devices (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name        text NOT NULL,             -- "Michael's iPhone"
  platform    text NOT NULL,             -- ios | ipados | macos | tvos
  apns_token  text,
  apns_env    text,                      -- sandbox | production
  token_hash  text NOT NULL,             -- auth token, hashed
  last_seen_at timestamptz
);

CREATE TABLE spaces (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind       text NOT NULL CHECK (kind IN ('personal','shared')),
  name       text NOT NULL,
  created_by uuid NOT NULL REFERENCES users(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE space_members (
  space_id  uuid NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
  user_id   uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role      text NOT NULL DEFAULT 'contributor',
  joined_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (space_id, user_id)
);

-- The file. Immutable, deduplicated, space-agnostic.
CREATE TABLE assets (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sha256          text NOT NULL UNIQUE,
  byte_size       bigint NOT NULL,
  media_type      text NOT NULL,          -- photo | video
  mime            text NOT NULL,
  width           int, height int,
  duration_ms     int,
  captured_at     timestamptz,            -- from EXIF, falls back to file mtime
  captured_tz_off int,                    -- seconds; preserves local wall time
  lat             double precision,
  lon             double precision,
  place_name      text,                   -- offline reverse geocode
  camera_make     text, camera_model text, lens text,
  iso             int, aperture real, shutter text, focal_len real,
  exposure_bias   real,                   -- the "0 ev" field
  dynamic_range   text,                   -- standard | hdr, from gain-map presence
  orientation     int,
  is_raw          boolean NOT NULL DEFAULT false,
  live_group_id   uuid,                   -- shared by the still + paired video
  burst_id        text,                   -- PHAsset.burstIdentifier; drives stacks
  burst_pick      boolean NOT NULL DEFAULT false,  -- user/auto-selected representative
  thumbhash       bytea,                  -- ~25 bytes
  exif            jsonb,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX ON assets (captured_at DESC);
CREATE INDEX ON assets (live_group_id) WHERE live_group_id IS NOT NULL;

-- The placement. This is where attribution lives.
CREATE TABLE space_assets (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  space_id            uuid NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
  asset_id            uuid NOT NULL REFERENCES assets(id),
  uploaded_by_user_id uuid NOT NULL REFERENCES users(id),
  uploaded_at         timestamptz NOT NULL DEFAULT now(),
  source_device_id    uuid REFERENCES devices(id),
  source_local_id     text,               -- PHAsset.localIdentifier, a hint only
  on_device           boolean NOT NULL DEFAULT true,
  description         text,
  rating              smallint CHECK (rating BETWEEN 0 AND 5),
  deleted_at          timestamptz,
  UNIQUE (space_id, asset_id)
);

CREATE INDEX ON space_assets (space_id, uploaded_at DESC);

-- Favorites are per-user, not per-item. In a shared space "Mom favorited this"
-- and "I favorited this" are different facts. Degenerates correctly in a
-- personal space, where there is only ever one member.
CREATE TABLE space_asset_favorites (
  space_asset_id uuid NOT NULL REFERENCES space_assets(id) ON DELETE CASCADE,
  user_id        uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  favorited_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (space_asset_id, user_id)
);

CREATE TABLE tags (
  id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  space_id uuid NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
  name     text NOT NULL,
  UNIQUE (space_id, name)
);

CREATE TABLE space_asset_tags (
  space_asset_id uuid NOT NULL REFERENCES space_assets(id) ON DELETE CASCADE,
  tag_id         uuid NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
  PRIMARY KEY (space_asset_id, tag_id)
);

CREATE TABLE change_log (
  seq        bigserial PRIMARY KEY,
  space_id   uuid NOT NULL,
  entity     text NOT NULL,               -- space_asset | space | member
  entity_id  uuid NOT NULL,
  op         text NOT NULL,               -- insert | update | delete
  at         timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX ON change_log (space_id, seq);

CREATE TABLE activity_sessions (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  space_id   uuid NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
  user_id    uuid NOT NULL REFERENCES users(id),
  photo_count int NOT NULL DEFAULT 0,
  video_count int NOT NULL DEFAULT 0,
  is_bulk    boolean NOT NULL DEFAULT false,
  opened_at  timestamptz NOT NULL DEFAULT now(),
  last_at    timestamptz NOT NULL DEFAULT now(),
  closed_at  timestamptz
);
```

Every user gets exactly one `personal` space at creation. "Family Shared" is
just a `shared` space — which means additional shared spaces (Trip 2026, Kids)
cost nothing structurally, even if the UI only exposes one for now.

**`space_assets.uploaded_by_user_id` is the "who uploaded this" requirement.**
It's correctly per-placement: if you add a photo I took to Family Shared, the
*placement* is attributed to you.

### change_log ordering gotcha

`bigserial` values are handed out at INSERT time, not COMMIT time. Two
concurrent uploads can commit out of sequence order, so a client polling
`since=N` can permanently miss a row that committed after a higher `seq` was
already visible — which shows up as photos that mysteriously never appear.

Fix: take a Postgres **advisory lock keyed on `space_id`** around the
change_log insert so sequence assignment and commit are serialized per space.
Contention is irrelevant at 4 users. Clients must also apply changes
**idempotently** so replaying a range is harmless.

---

## 6. HTTP API

All under `/v1`, bearer token auth, JSON except blob transfer.

```
POST   /v1/auth/redeem            { inviteCode, deviceName, platform } → token
POST   /v1/devices/push-token     { apnsToken, env }

GET    /v1/spaces                                    → spaces + membership
GET    /v1/spaces/:id/timeline?zoom=year|month|day   → bucket list + counts + places
GET    /v1/spaces/:id/timeline/:bucket               → packed item array
GET    /v1/spaces/:id/changes?since=<seq>            → delta + newCursor

GET    /v1/assets/:id                                → full metadata + uploader
GET    /v1/assets/:id/thumb?size=256|512
GET    /v1/assets/:id/preview
GET    /v1/assets/:id/original                       → Range-capable
GET    /v1/assets/:id/hls/master.m3u8                → lazy transcode

POST   /v1/uploads/probe          { sha256, byteSize } → have | need | partial
PUT    /v1/uploads/:sid/chunk/:n                       → raw bytes
POST   /v1/uploads/:sid/commit    { spaceId, metadata } → assetId

POST   /v1/spaces/:id/assets/:assetId                  → link existing blob (share)
DELETE /v1/spaces/:id/assets/:assetId                  → soft delete
POST   /v1/assets/:id/verify      { sha256 }           → gate for Free Up Space
```

### Timeline manifest

The scale driver. `GET /v1/spaces/:id/timeline` returns only buckets and counts
— a few KB — which is enough for the client to compute the **entire** scroll
geometry and a correct fast-scrubber without loading one image. Buckets are then
fetched on demand as the user scrolls.

`zoom` returns the same shape at year, month, or day granularity, which is what
backs the Year / Month / Day segmented control. Day buckets also carry a
`place` string (the dominant reverse-geocoded location for that day) so section
headers can read `Jul 18 · Culpeper County, Virginia` without a second request.

Each item in a bucket is packed small:

```
id (16B) | capturedAt (8B) | aspectRatio (f32) | mediaType (1B) | thumbhash (25B)
```

≈ 55 bytes/item, so a 400-photo month is ~22 KB. ThumbHash renders an instant
colored placeholder with zero additional network.

### Upload protocol

1. Client hashes the original → `POST /uploads/probe`.
2. `have` → skip straight to a `POST /spaces/:id/assets/:assetId` link. This is
   what makes duplicate family photos and retries nearly free.
3. `need` / `partial` → upload chunks from the returned offset.
4. `commit` → server re-verifies the hash, moves `incoming/` → `blobs/`,
   extracts EXIF, enqueues thumbnails, inserts `assets` + `space_assets` +
   `change_log` in one transaction.

**Large files must be client-chunked.** iOS background `URLSession` upload
tasks cannot resume mid-file — a failed transfer restarts from zero, which
means a 350 MB video on a flaky connection may never complete. Files are split
into uniform **16 MB chunks**, each its own background task, reassembled
server-side. This is not optional at 3,000 videos. Chunking is uniform rather
than threshold-gated: a small photo is simply a one-chunk upload, so there is no
second code path to get wrong.

Chunk receipt is tracked as a **bitmap in `upload_sessions.received_mask`**,
updated with Postgres `set_bit()` so parallel chunk PUTs cannot lose bits to a
read-modify-write race. A resumed `probe` returns exactly the missing indices.

### JSON coding contract

`FrameStationAPI.FrameStationCoding` supplies the encoder and decoder for **both**
sides. Neither the server nor a client may construct a bare `JSONEncoder`.

The defaults disagree in a way that fails silently: Vapor encodes `Date` as
ISO8601, a stock `JSONDecoder` uses `.deferredToDate` (seconds since 2001). A
client built on defaults sends `774662400` where the server expects
`"2026-07-24T19:28:00Z"`, and the only symptom is a 400 on every commit carrying
a capture date.

---

## 7. Push notifications

Never push per-asset.

On each successful commit, upsert an `activity_sessions` row keyed
`(space_id, user_id)` and bump the counts. A sweeper closes any session idle
for **5 minutes**, then sends **one** APNs push to every member of the space
except the actor:

> Morgan added 10 photos and 2 videos to Family Shared

Use `apns-collapse-id` per session and a `thread-id` per space so repeat pushes
coalesce in Notification Center rather than stacking.

Sessions flagged `is_bulk` (initial import, or count over ~200) collapse to a
single summary — otherwise the first device backup notifies the whole family
about 8,000 photos.

APNs is outbound-only on 443, so this works fine behind NAT with no inbound
exposure.

---

## 8. iOS backup engine

The hardest part of the project. Constraints, not preferences:

- **`URLSession` with a background configuration** is the only mechanism that
  survives app termination, and background uploads must be **file-based**
  (`uploadTask(with:fromFile:)`). Each asset is exported to temp storage via
  `PHAssetResourceManager.writeData(for:toFile:)` before it can be sent, which
  costs disk and time. Reserve headroom and clean up aggressively.
- **`BGProcessingTaskRequest`** for catch-up scans — opportunistic, typically
  on charger + Wi-Fi. Not guaranteed. `BGAppRefreshTask` for short checks.
- **`PHPhotoLibrary.fetchPersistentChanges(since:)`** (iOS 16+) with a persisted
  `PHPersistentChangeToken` is what detects edits, deletions, and additions that
  happened **while the app was dead**. Handle `persistentChangeTokenExpired` by
  falling back to a full rescan.
- **Optimize iPhone Storage** means originals may not be local. Set
  `PHAssetResourceRequestOptions.isNetworkAccessAllowed = true` and expect slow,
  metered downloads from iCloud before you can upload anything.
- **Limited photo library access breaks backup entirely.** Detect it and say so
  plainly in the UI rather than silently backing up 12 photos.
- **`PHAsset.localIdentifier` is not stable** across restores or device
  migrations. Content hash is the real identity; `localIdentifier` is a local
  cache hint only.
- **Live Photos are two `PHAssetResource`s.** Upload both, join with
  `live_group_id`.

A durable queue in SwiftData holds pending work across launches: asset local id,
content hash, export state, chunk progress, retry count, last error. The engine
is a state machine over that table, not an in-memory pipeline — it must survive
being killed mid-upload at any point.

**Settings:** master backup toggle, Wi-Fi only, charging only, include videos,
which space is the backup target.

### Asset states shown in the UI

| State | Meaning |
|---|---|
| Backed up | On device **and** on NAS |
| Archived | On NAS only — removed from device, deliberately kept here |
| Pending | On device, not yet uploaded |

### Free Up Space

Select backed-up assets → server confirms hash match via `/verify` → batched
`PHAssetChangeRequest.deleteAssets` shows the system confirmation sheet. Items
sit in Recently Deleted for 30 days and still occupy space until then; say so in
the UI.

Gate this feature behind an existing NAS backup. Once this app replaces Synology
Photos, the NAS holds the family's only copy, and RAID is not a backup —
Btrfs snapshots plus Hyper Backup to an external drive or B2 before this ships.

---

## 9. Clients

One Swift package, `FrameStationKit`: models, API client, sync engine, blob cache,
ThumbHash decoding. XcodeGen project layout, same as ReelStation.

| Platform | Role |
|---|---|
| iOS | Full — backup, browse, upload, share, free up space |
| iPadOS | Full, sidebar layout |
| macOS | **View-only.** Same sidebar layout as iPadOS. No Photos backup. |
| tvOS | View-only, 10-foot layout, slideshow. Reuse ReelStation's focus handling. |

### Grid performance

At 100k items, `LazyVGrid` still stutters. Use a `UICollectionView` with
compositional layout wrapped in `UIViewControllerRepresentable`:

- Justified-grid layout computed from aspect ratios in the manifest, before any
  image loads.
- ThumbHash placeholder painted immediately; real thumbnail swaps in on arrival.
- Two-tier cache: `NSCache` of decoded images + bounded LRU on disk.
- Downsample at decode with `CGImageSourceCreateThumbnailAtIndex` +
  `kCGImageSourceThumbnailMaxPixelSize` — never decode full-size into memory.
- Cancel in-flight requests on cell reuse. HTTP/2 keep-alive to the NAS.

### Search v1

Metadata only, and it's nearly free: date ranges, place name, camera/lens,
media type, and uploader. Place names come from an **offline** GeoNames
`cities1000` lookup (~10 MB in the container) — no external geocoding API, so
the family's location history never leaves the NAS.

---

## 9a. UI reference

Two reference points: Apple Photos for the detail/info experience, Synology
Photos for the library and backup shell. Where they disagree, Apple wins.

### Library shell

- **Space switcher in the nav title** — `Photos ⌄ / Personal Space`. Tapping the
  chevron switches Personal ↔ Family Shared. This is Synology's pattern and it
  maps exactly onto our `spaces` model.
- **Backup status banner** pinned above the grid — `Photo Backup Complete` with a
  disclosure chevron into a detail screen. Live state during a run
  (`Backing up 1,204 of 8,331`), and it is where per-item failures and retries
  surface. Synology's vanishes and offers no error detail; ours must not.
- **Section headers carry date + place** — `Jul 18 · Culpeper County, Virginia`.
  Served by the `place` field on day buckets, so no extra request.
- **Year / Month / Day / Folders** segmented control. Backed by
  `timeline?zoom=`; each zoom is a different bucket granularity and grid density.
- **Grid overlays** — video duration with a play glyph (`12:08 ▶`), stack count
  badge (`9 ▤`) for bursts.
- **Tabs** — Photos, Albums, Sharing, More.

### Photo detail

Full-bleed image on black. Top bar carries back, **AirPlay/cast** (we ship a
tvOS app — casting a photo to the living room is a first-class use), and
overflow. Bottom action bar: Share, Favorite, Info, **Add to Family Shared**,
Delete. That fourth action is the one neither reference app has and it is the
whole point of this product.

Bursts render as a filmstrip above the action bar with a stack-count button,
matching Synology's stack browser.

### Information panel

Modeled on Apple Photos, which is far richer than Synology's (theirs shows no
camera, no lens, no exposure, and no map at all). Top to bottom:

| Block | Source | Notes |
|---|---|---|
| Face bubbles over image | *deferred* | Leave the slot so adding faces later isn't a redesign |
| Caption | `space_assets.description` | Inline "Add a Caption", not a modal |
| Look Up / Live Text | VisionKit `ImageAnalysisInteraction` | On-device, public API, zero server work — near-free parity with a marquee Apple feature |
| Date · time + filename | `assets.captured_at` + tz offset | `Saturday • Jul 4, 2026 • 3:55 PM`, editable |
| **Added by** | `space_assets.uploaded_by_user_id`, `uploaded_at` | **Shared spaces only.** Avatar + name + relative time |
| Camera card | `assets` EXIF columns | See below |
| Map card | `assets.lat/lon/place_name` | MapKit snapshot, photo as the annotation pin, place name |
| Storage status | `space_assets.on_device` | Backed up / Archived / Pending, plus the `browse/` path |

The camera card, rendered from columns we already store:

```
Apple iPhone 16 Pro Max                          JPEG
Main Camera — 24 mm ƒ1.78
24 MP • 4284 × 5712 • 6.2 MB                 STANDARD
ISO 64  |  24 mm  |  0 ev  |  ƒ1.78  |  1/268 s
```

The **Added by** row is the requirement that motivated this whole project and
neither reference app has it. In Personal Space it is suppressed; in Family
Shared it sits directly under the date block, above the camera card, because in
a shared library "who put this here" outranks "what lens shot it."

### Settings

Adopted from Synology, with the gaps filled:

| Setting | Notes |
|---|---|
| Backup enable | Master toggle |
| Backup destination | Which space. Synology hardcodes Personal; we allow Family Shared |
| Wi-Fi only | Adopt |
| Back up videos | Synology's "Photos Only" inverted — no double negative |
| **Charging only** | Missing from Synology. Matters at 800 GB |
| Favorites sync | Two-way with Apple Photos via `PHAsset.isFavorite`; last-write-wins by timestamp |
| Sort order | Ascending/descending by date taken |
| Show dates and locations | Overlay toggle for full-screen browsing |
| Playback quality | Auto / Original / High / Medium → the lazy HLS ladder |
| Cache management | Size readout, cap, clear. Backs the bounded LRU disk cache |
| Deletion settings | See below — **two axes, not one** |

**Not adopting: "Play Content Over HTTP."** Synology offers it as a workaround
for self-signed certificates, but it is a security downgrade dressed as a
convenience toggle. We have a real Let's Encrypt certificate through the DSM
reverse proxy, and ReelStation's existing fingerprint-pinning trust flow is a
strictly better fallback.

### Deletion has two independent axes

We only decided one of these. Synology's single "Deletion Settings" screen
conflates them:

- **Axis A — user deletes in Apple Photos.** *Decided:* the NAS copy is kept and
  the item becomes `Archived`.
- **Axis B — user deletes inside our app.** *Undecided.* Options are NAS only
  (default, mirrors Axis A), device only, or both. Synology defaults to
  "Delete from NAS only."

---

## 10. Deployment

`docker-compose.yml` in Container Manager: `framestation` (Swift/Vapor) +
`postgres:16`. The service binds to `127.0.0.1:8080` only.

The server is built for **linux/amd64** (the DS920+ is x86-64) via a multi-stage
Dockerfile, from an arm64 Mac. Buildx handles the cross-compile; expect the
Swift build stage to be slow under emulation, so build on the NAS itself or
enable a native amd64 builder.

Expose it through **DSM's reverse proxy** (Control Panel → Login Portal →
Advanced → Reverse Proxy): source `yourhost.synology.me:8443` → destination
`localhost:8080`, with the **existing Let's Encrypt certificate** assigned. One
additional router port forward, no new cert, no self-signed trust prompt.
Keep DSM auto-block and the firewall on.

Secrets (Postgres password, APNs `.p8`, key id, team id) live in a gitignored
`.env` beside the compose file, never in the repo.

### TLS: one hostname, valid everywhere

**There is no plain-HTTP path in this app**, on LAN or remote. That is a harder
line than ReelStation draws — `NASCredentials.streamOverHTTP` defaults to `true`
and sends LAN media bytes over port 5000 in the clear, because VLCKit and
AVPlayer use their own TLS stacks, never see `CertificateTrustDelegate`, and
reject DSM's self-signed certificate. That is the same workaround as Synology's
"Play Content Over HTTP" toggle, for the same reason.

FrameStation avoids it structurally: traffic terminates at the DSM reverse proxy
on a real Let's Encrypt certificate, which AVPlayer accepts natively.

This is not optional polish. **Background `URLSession` uploads run
out-of-process in `nsurlsessiond`**, where custom server-trust overrides are
unreliable — the app may not even be running to answer the challenge. A
self-signed certificate would make the backup engine fail intermittently and
opaquely. A publicly-valid certificate is a hard requirement for M5.

**Use split-horizon DNS so the same hostname works at home.** A LAN connection
to `nas.local` or a bare IP will not match a certificate issued for
`yourhost.synology.me`. Resolve that public hostname to the NAS's LAN IP from
inside the house — via DSM's DNS Server package or a router DNS override — so
clients use one hostname everywhere: valid TLS, full LAN speed at home, no NAT
hairpin, no second certificate.

NAT loopback is the fallback if split-horizon isn't available, but many consumer
routers don't support it and it caps throughput by bouncing traffic through the
router. ReelStation already hit this: a `.synology.me` login broke previews and
playback at home while API calls worked.

`CertificateTrustDelegate` and `CertificateTrustStore` still port over as the
foreground fallback for a misconfigured or expired certificate — host-scoped,
fingerprint-shown, ATS never globally disabled. They should just never fire in a
correctly configured install.

---

## 11. Milestones

Ordered so the library is populated **before** the mobile backup engine exists —
the phones then only ever push the delta. Building backup first would mean weeks
of watching progress bars before anything is evaluable.

| # | Milestone | Outcome |
|---|---|---|
| **M0** ✅ | Container skeleton | Postgres + Vapor + invite/token auth + health check. Schema, migration runner, and `/health`, `/v1/auth/redeem`, `/v1/me`, `/v1/devices/push-token` built and verified against a live Postgres 16. Remaining: deploy to the NAS behind the reverse proxy. |
| **M1a** ✅ | Upload protocol | Content-addressed blob store, hash-first idempotent probe, resumable 16 MB chunking, hash-verified commit, dedup, browse-tree hardlinks, advisory-locked `change_log`, activity rollup. 33 end-to-end assertions green. |
| **M1b** ✅ | Media pipeline | EXIF (exiftool), video probe + poster frames (ffmpeg/ffprobe), thumbnails (libvips), ThumbHash, resumable derivation queue, thumb/preview/original serving. 33 end-to-end assertions green. **Offline reverse geocode deferred** — `place_name` is still null. |
| **M2** ✅ | Import existing library | `import` CLI: resumable walk, `@eaDir`/`#recycle` exclusion, batched exiftool, Live Photo pairing, dedup, copy or hardlink placement. 29 assertions green. |
| **M3** 🟡 | Timeline | **Server done** — manifest at year/month/day zoom, per-bucket items, delta sync, asset detail with camera card + attribution. 34 assertions green. **Client** — sectioned grid with ThumbHash placeholders, two-tier thumbnail cache, Keychain credentials, space switcher, full-screen viewer, and the Information panel (camera card, MapKit location, per-user favourites, Added-by attribution). Offline reverse geocoding via a bundled GeoNames dataset. **Remaining:** `UICollectionView` swap for 100k scale. |
| **M4** ✅ | Spaces | Create shared spaces, household directory, owner-gated membership and rename, "Add to Family Shared" from the viewer, per-member contribution counts. 34 assertions green. |
| **M5** 🟡 | iOS backup engine | **Foreground pass done** — Photos authorisation (including an explicit limited-access warning), full library scan, durable SwiftData queue that survives termination, export → streamed SHA-256 → probe → chunked send → commit, dedup via content hash, retry cap, settings screen and grid status banner. Verified in the simulator: 11 library items → 10 blobs (a duplicate linked rather than re-sent), EXIF/GPS/place names/ThumbHashes/attribution all intact. **Remaining:** background `URLSession` + `BGTaskScheduler`, `PHPersistentChangeToken` incremental rescan, Live Photo pairing, and server-side reflink placement into `/volume1/homes/<user>/…` (needs the container running as root). |
| **M5b** ✅ | DSM login | Server-side credential exchange against `SYNO.API.Auth`, account + personal space created on first sign-in, `dsm_uid` recorded for home-directory placement. Invite flow retained as fallback. |
| **M5c** ✅ | Picker + share | Multi-select grid of recent library items with numbered badges and video durations, uploading straight into the current space. Shares the M5 upload path (`AssetUploader`) rather than duplicating it, so both routes commit identical metadata. Verified end to end: 3 items into Family Shared with attribution, place names, and the timeline refreshing behind the sheet. |
| **M7** ✅ | Video playback | Direct play of the stored file over HTTP Range — no transcode, so a J4125 serves 4K without breaking a sweat. Signed short-lived playback URLs (HMAC-SHA256), because AVPlayer fetches media outside our URLSession and an AirPlay receiver fetches it from another device entirely. `Accept-Ranges` now advertised. AVKit `VideoPlayer` on all three platforms, autoplaying like Photos. 26 assertions. |
| **M8** | Fast scroller | Apple Photos-style scrubber with a month/year pill while dragging, resting indicator that tracks scroll position |
| **M6** 🟡 | Push | **Built and verified without Apple credentials.** Token registration on the device row, ES256 JWT signing via swift-crypto (no new dependency), a sweeper that closes idle `activity_sessions` and sends one summary per burst, uploader excluded, personal spaces silent, dead tokens dropped on 410. Notification delivery, copy, and tap-to-open-space verified in the simulator with `simctl push`. 28 assertions green. **Remaining:** a real `.p8` key and an actual APNs round-trip, which needs an Apple Developer account and a physical device. |
| **M6b** ✅ | Activity inbox | Bell in the top-left with an unread badge, recent shared-space contributions with relative times, tap-to-open the space, and Clear All. Reads the same `activity_sessions` rows the sweeper closes, so the inbox works even when push is unconfigured or declined. Per-user read watermark on `users.activity_read_at`. 15 further assertions. |
| **M7** | Free Up Space | Verified-then-delete, gated on NAS backup existing |
| **M8** | macOS / iPadOS / tvOS | Shared package, view-only clients |

---

## 12. Deferred

- Face recognition and grouping — the sharpest regression from replacing
  Synology Photos. Revisit as a setting; on-device Vision is cheap, CLIP
  embeddings on the NAS enable natural-language search but add an ML runtime.
- Semantic/object search.
- Albums and curated collections.
- Memories / on-this-day.
- Sharing outside the household (public links).
- Web client.
- End-to-end encryption — would eliminate server-side thumbnails and search.
