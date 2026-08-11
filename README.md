# FrameStation

A self-hosted photo and video library for a family, running on a Synology NAS,
with native clients for iOS, iPadOS, macOS, and tvOS. Replaces Synology Photos.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full design. This file covers
running and deploying what exists today.

**Status: M11.** The library works end to end — upload, media pipeline,
timeline with delta sync, shared spaces with attribution, albums, tags and
ratings, video playback, the iOS backup engine, and search by place. Push is
built and verified in the simulator but has never made a real APNs round trip —
that needs an Apple Developer account and a physical device.

It also behaves when the NAS doesn't: an unreachable server is named as such
rather than blamed on the phone, losing the network no longer burns the backup
queue's retry budget, and launching out of range shows the cached library
instead of a sign-in form.

Remaining: a `UICollectionView` grid for 100k scale, Recently Deleted, and the
view-only macOS/tvOS clients. One known defect — video auto-advance selects the
next clip but doesn't play it (ARCHITECTURE.md M12).

---

## Layout

```
FrameStation/
  ARCHITECTURE.md            Design of record
  project.yml                XcodeGen — regenerate with `xcodegen generate`
  docker-compose.yml         Postgres + server, for Container Manager
  .env.example               Copy to .env on the NAS

  Packages/
    FrameStationAPI/         Wire types + JSON contract. Foundation only.
    FrameStationKit/         API client, sync engine, cache. Shared by all apps.

  App/                       SwiftUI sources for iOS, macOS, tvOS
  Server/                    Vapor service + Dockerfile
    Sources/FrameStationServer/Migrations/SQL/
  Design/Icon/               Generated icon output (see Scripts/GenerateIcon.swift)
  Scripts/
```

**`FrameStationAPI` is a standalone package, not part of the Server package.**
That matters: if the apps depended on `Server/Package.swift`, SPM would try to
resolve Vapor, PostgresKit, and SwiftNIO for iOS and tvOS, which cannot build.
Keeping it separate is what lets one set of types be shared honestly — an API
change is a compile error on both sides rather than a runtime surprise.

`FrameStationKit` must never import SwiftUI; UI belongs in the app targets.

---

## Apps

```bash
xcodegen generate
```

Three targets: `FrameStation-iOS` (iPhone + iPad, the only one that backs up),
`FrameStation-macOS` and `FrameStation-tvOS` (both view-only).

`project.yml` is the source of truth for version, build number, and signing —
XcodeGen overwrites Xcode's General tab on every regeneration, so set them there.

### Icon

```bash
swift Scripts/GenerateIcon.swift Design/Icon
```

The icon is code rather than a binary, so it re-exports at every size
deterministically and a tweak is a diff. Emits the iOS 1024 master (square, no
alpha — the system applies the mask), the pre-rounded macOS ladder, tvOS
parallax layers, and small previews for checking legibility at Settings-row
size. Asset catalogs live under `App/Resources/<platform>/Assets.xcassets`.

**Still to do:** the tvOS layered `.imagestack` and the Xcode 26 Icon Composer
`.icon` document for Liquid Glass light/dark/tinted variants. Layer PNGs are
already generated.

### Tests

```bash
swift test --package-path Packages/FrameStationKit
```

Hermetic by default. Point them at a running server to include the integration
tests:

```bash
FRAMESTATION_LIVE_URL=http://127.0.0.1:8099 swift test --package-path Packages/FrameStationKit
```

21 tests. The two worth knowing about: `TransferFailureTests` pins which
failures may cost an item a retry, and `CacheLimitTests` writes past the disk
cap and asserts the newest entry survives while the oldest is evicted —
the eviction that ARCHITECTURE claimed for a while without it existing.

**Place search has no smoke script yet.** It was verified by hand against a
geocoded library in the simulator; the other milestones each have a
`Scripts/smoke-*.sh` and this one should get one.

---

## Running locally

You need Postgres 16. The server itself builds with the Xcode toolchain — no
Docker required for development.

```bash
brew install postgresql@16
```

Start a throwaway instance. `LC_ALL` must be set or the postmaster aborts with
"became multithreaded during startup", and the socket directory has to be short
because Unix socket paths cap at 103 bytes:

```bash
export PATH="/opt/homebrew/opt/postgresql@16/bin:$PATH" LC_ALL=C LANG=C
mkdir -p /tmp/pv/sock ~/.framestation-dev
initdb -D ~/.framestation-dev/pgdata -U framestation --auth=trust
pg_ctl -D ~/.framestation-dev/pgdata -o "-p 55432 -k /tmp/pv/sock -c listen_addresses=127.0.0.1" -l ~/.framestation-dev/pg.log start
createdb -h 127.0.0.1 -p 55432 -U framestation framestation
```

Run the server. Migrations apply automatically on boot:

```bash
cd Server && FRAMESTATION_DATABASE_URL="postgres://framestation:x@127.0.0.1:55432/framestation?sslmode=disable" FRAMESTATION_BLOB_ROOT="$HOME/.framestation-dev/blobs" swift run FrameStationServer serve --hostname 127.0.0.1 --port 8099
```

Mint an invite code in a second terminal (same env vars):

```bash
cd Server && swift run FrameStationServer invite
```

Redeem it. The returned `token` is shown exactly once — the server stores only
its SHA-256 hash — so a real client persists it to the Keychain immediately:

```bash
curl -s -X POST http://127.0.0.1:8099/v1/auth/redeem -H 'Content-Type: application/json' -d '{"code":"XXXX-XXXX","displayName":"Michael","deviceName":"iPhone","platform":"ios"}'
```

```bash
curl -s http://127.0.0.1:8099/v1/me -H "Authorization: Bearer <token>"
```

---

## Endpoints

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/health` | — | Status, version, DB reachability, migration count |
| POST | `/v1/auth/redeem` | — | Single-use invite → user + personal space + device token |
| GET | `/v1/me` | Bearer | Current user, device, and space memberships |
| POST | `/v1/devices/push-token` | Bearer | Register APNs token (consumed in M6) |
| POST | `/v1/uploads/probe` | Bearer | Hash-first: `have` (skip transfer) / `need` / `partial` (resume) |
| PUT | `/v1/uploads/:id/chunk/:n` | Bearer | Upload one 16 MB chunk |
| POST | `/v1/uploads/:id/commit` | Bearer | Verify hash, store blob, create asset + placement |
| POST | `/v1/spaces/:id/assets/:assetID` | Bearer | Link an existing blob into a space (no copy) |
| GET | `/v1/assets/:id/thumb?size=256\|512` | Bearer | Pre-generated thumbnail; `202` while still queued |
| GET | `/v1/assets/:id/preview` | Bearer | 2048 px, rendered on first request and cached |
| GET | `/v1/assets/:id/original` | Bearer | Byte-exact original, Range-capable |
| GET | `/v1/spaces/:id/timeline?zoom=` | Bearer | Bucket list + counts + places at year/month/day |
| GET | `/v1/spaces/:id/timeline/:bucket` | Bearer | Items for one bucket |
| GET | `/v1/spaces/:id/changes?since=` | Bearer | Delta sync, hydrated with full items |
| GET | `/v1/spaces/:id/assets/:id/detail` | Bearer | Information panel: camera card, map, attribution |
| DELETE | `/v1/spaces/:id/assets/:id` | Bearer | Soft delete; the file moves to File Station's `#recycle` |
| PUT/DELETE | `/v1/spaces/:id/assets/:id/favorite` | Bearer | Per-user favourite, not a shared boolean |
| PUT | `/v1/spaces/:id/assets/:id/rating` | Bearer | Stars 0–5. Shared, unlike favourites |
| POST | `/v1/spaces/:id/assets/:id/tags` | Bearer | Add and remove in one call; returns the result |
| GET | `/v1/spaces/:id/tags` | Bearer | Every tag in use, for the editor to offer |
| POST | `/v1/spaces/:id/assets/capture-time` | Bearer | Re-time a selection, moving files to match |
| POST | `/v1/spaces/:id/assets/orientation` | Bearer | Rotate; relative, not absolute |
| **GET** | **`/v1/spaces/:id/places`** | Bearer | Place names with counts, commonest first |
| **GET** | **`/v1/spaces/:id/search?place=`** | Bearer | Paged matches plus a total. Substring, case-insensitive |
| GET | `/v1/assets/:id/playback` | Bearer | Short-lived signed URL — AVPlayer fetches outside our session |
| GET | `/v1/stream/:assetID` | Signed | The bytes that signed URL points at |
| GET | `/v1/activity` | Bearer | Recent shared-space contributions, with an unread watermark |
| POST | `/v1/activity/read` | Bearer | Move the watermark |
| GET/POST | `/v1/albums` | Bearer | List, create. Albums are private and borrow their permissions |
| GET/PATCH/DELETE | `/v1/albums/:id` | Bearer | Detail, rename, remove |
| GET | `/v1/albums/:id/items` | Bearer | Contents |
| POST/DELETE | `/v1/albums/:id/assets` | Bearer | Add a selection, or remove one |
| GET | `/v1/household` | Bearer | Everyone with an account, for picking space members |
| POST | `/v1/spaces` | Bearer | Create a shared space; creator becomes owner |
| PATCH | `/v1/spaces/:id` | Bearer | Rename (owner only) |
| GET | `/v1/spaces/:id/members` | Bearer | Members, roles, and per-member contribution counts |
| PUT/DELETE | `/v1/spaces/:id/members/:userID` | Bearer | Add/remove (owner), or leave (self) |
| POST | `/v1/auth/dsm` | — | Sign in with a DSM account (the path family members use) |

### Importing an existing library

```bash
docker compose exec server ./FrameStationServer spaces
```

```bash
docker compose exec server ./FrameStationServer import --path /data/photo --space <space-id> --dry-run
```

Drop `--dry-run` to run it. Resumable — re-running skips anything already
imported and retries failures. `--mode hardlink` places blobs as hardlinks to
the source instead of copies: instant and zero extra space, but the blob then
shares an inode with the original, so editing the source in place would
silently change the stored asset. Requires both on the same volume.

### Media tools

The server shells out to three binaries. Without them the derivation worker
logs which are missing and stays off rather than failing every upload:

```bash
brew install vips exiftool ffmpeg
```

The container installs `libvips-tools`, `libheif1`, `exiftool`, and `ffmpeg`,
and the build **fails** if vips lacks a HEIF loader — most of an iPhone library
is HEIC, and that is not a thing to discover in production.

### Reverse geocoding

Day headers and the Information panel map show `Culpeper, Virginia` rather than
raw coordinates. Fully offline — the container bundles a trimmed GeoNames
dataset, so no coordinate ever leaves the NAS and lookups cost nothing.

For local development, build the dataset once:

```bash
./Scripts/fetch-geonames.sh
```

Then point the server at it with `FRAMESTATION_GEONAMES_DIR=./Data/geonames`.
Absent dataset is not an error — `place_name` stays null and clients fall back
to coordinates.

Backfill assets that predate geocoding, or re-run after a dataset update:

```bash
docker compose exec server ./FrameStationServer geocode
```

### Smoke test

With the server running against a **freshly migrated, empty** database:

```bash
FRAMESTATION_TEST_DIR=/tmp/framestation-test ./Scripts/smoke-m1a.sh
```

```bash
FRAMESTATION_TEST_DIR=/tmp/framestation-test ./Scripts/smoke-m1b.sh
```

Both need a **freshly migrated, empty** database and a server started with
`FRAMESTATION_BLOB_ROOT="$FRAMESTATION_TEST_DIR/blobroot"` — they assert against
files on disk. Run one, reset the database, run the other.

`smoke-m1a.sh` — 33 assertions: resume-after-interruption, truncated-chunk
rejection, hash-mismatch rejection, dedup, hardlink inode sharing, cross-user
access control.

`smoke-m1b.sh` — 33 assertions: EXIF fields, GPS hemisphere signs, capture time
against `OffsetTimeOriginal`, video duration and rotation-corrected dimensions,
queue drain, thumbnails and poster frames on disk, ThumbHash size, lazy preview
generation, byte-exact originals, and access control.

`smoke-m4.sh` — 34 assertions: creating shared spaces, household directory,
role enforcement (non-owners can't add, owners can't be removed, members can
leave), rename rules, personal spaces refusing to be shared, cross-space linking
without duplicating bytes, attribution, and non-members being locked out.

`smoke-geocode.sh` — 13 assertions: real coordinates across five continents
resolving to real place names, mid-ocean correctly staying unnamed, day headers,
asset detail, and the backfill command.

`smoke-m3.sh` — 34 assertions: bucket counts at all three zooms, local-timezone
bucketing, aspect ratios, ThumbHash delivery, delta sync cursors, asset detail,
and shared-space attribution.

### Driving the app headlessly

The simulator can be scripted without any UI automation — useful for
screenshots and for checking a change actually renders:

```bash
xcrun simctl launch <udid> com.michaelromero.FrameStation -FSServerURL http://127.0.0.1:8099 -FSInviteCode ABCD-1234 -FSAutoConnect YES
```

`simctl` turns `-key value` pairs into UserDefaults, which `AppSession` reads
under `#if DEBUG`. Credentials persist to the Keychain, so later launches need
no invite code. Capture with `xcrun simctl io <udid> screenshot out.png`.

---

## Building the image

The DS920+ is x86-64, so the image must be **linux/amd64**.

**CI builds and publishes it.** [`.github/workflows/ci.yml`](.github/workflows/ci.yml)
builds for `linux/amd64` on an amd64 runner and pushes to GHCR. On the NAS:

```bash
docker compose pull && docker compose up -d
```

That needs only `docker-compose.yml` and `.env` on the NAS — no source
checkout, no Docker on your Mac.

CI also does something local development cannot: **it compiles the server on
Linux.** Everything else is built on macOS, and Foundation is a different
implementation on Linux — `Process`, `FileHandle` callbacks, and `FileManager`
attributes all diverge. A green Mac build is not evidence the container will
compile.

**Building on the NAS works** (8 GB RAM, ~2–4 GB peak for a Swift release
build) but is slow — a cold build of the Vapor/PostgresKit/NIO graph on a
J4125 is 20–45 minutes:

```bash
docker compose build
```

Cross-building on an Apple-silicon Mac under qemu is the slowest option and
isn't recommended.

The `swift:6.0-jammy` base tags in [Server/Dockerfile](Server/Dockerfile) are
pinned conservatively; bump them if you want a newer toolchain.

---

## Deploying to the NAS

CI publishes a `linux/amd64` image to GHCR on every push to `main`. The NAS
needs only `docker-compose.yml` and `.env` — no source checkout, no build.

**The NAS is already running.** [Routine updates](#routine-updates) is the path
you want. [First-time setup](#first-time-setup) below is for a fresh box.

### Routine updates

Every change reaches the NAS the same way. The whole loop is:

```bash
git push                                    # on your Mac; CI rebuilds `latest`
```

then on the NAS, once CI is green:

```bash
docker compose pull && docker compose up -d
curl -s http://127.0.0.1:8080/health
```

Two things make that insufficient, and both are silent when you skip them.

**A new migration is a one-way step on real data.** Snapshot `pgdata` first —
Btrfs snapshots are why the shared folder is on Btrfs. Compare what you have
against what the NAS has applied:

```bash
ls Server/Sources/FrameStationServer/Migrations/SQL/*.sql | wc -l   # on your Mac
curl -s http://127.0.0.1:8080/health                                # migrationsApplied
```

Migrations run automatically on first boot of the new image, atomically and in
filename order. They do not run backwards.

**`docker compose pull` does not update `docker-compose.yml`.** It updates the
image the file names. If the compose file or `.env.example` changed, copy them
up *before* pulling, or you get the new code running under the old
configuration — new server, none of the new behaviour, and nothing says so:

```bash
cat docker-compose.yml | ssh nas 'cat > /volume1/docker/framestation/docker-compose.yml'
```

#### What to check, by what changed

| Changed | The NAS needs |
|---|---|
| Server Swift only | `pull && up -d` |
| A new `Migrations/SQL/*.sql` | Snapshot `pgdata` first, then confirm `migrationsApplied` |
| `docker-compose.yml` or `.env.example` | Copy both up **before** pulling |
| A new bind mount in compose | Create the directory on the NAS first — Synology's Docker fails rather than creating it |
| App or `Packages/` only | Nothing. That ships through Xcode, not the NAS |

#### Which build is actually running

`/health` reports `version`, but that is `Build.version` in
[Configure.swift](Server/Sources/FrameStationServer/Configure.swift) and is
bumped by hand — it tells you the milestone, not the commit. For the commit,
CI also publishes a `sha-<short>` tag alongside `latest`, so:

```bash
docker compose images        # digest of what is running
```

Pin a known-good build by setting `FRAMESTATION_IMAGE` in `.env` to
`ghcr.io/michaelromero212/framestation-server:sha-abc1234`, and unset it to
follow `latest` again. Container Manager → Image shows the same thing with a
build date, which is the quickest way to spot a NAS that has quietly not been
pulled in weeks.

### First-time setup

#### 1. Authenticate to GHCR

The package inherits the repository's visibility, and this repo is private, so
the NAS needs a pull credential. Create a GitHub personal access token
(classic) with **`read:packages`** scope, then over SSH on the NAS:

```bash
echo "<TOKEN>" | sudo docker login ghcr.io -u michaelromero212 --password-stdin
```

Docker on DSM requires `sudo`, and `docker` is not on the default PATH — use
`/usr/local/bin/docker` or add it to PATH. Note also that modern `scp` relies on
the SFTP subsystem, which DSM does not enable by default; pipe files instead:

```bash
cat docker-compose.yml | ssh nas 'cat > /volume1/docker/framestation/docker-compose.yml'
```

#### 2. Enable the user home service

Control Panel → User & Group → Advanced → User Home → **Enable user home
service**. This is what creates `/volume1/homes`, which compose bind-mounts so
each person's photos land in their own DSM-private tree (ARCHITECTURE.md §3a).

Not optional: Synology's Docker fails a container whose bind-mount source is
missing, so with home service off the server will not start at all.

#### 3. Create the shared folder

Control Panel → Shared Folder → Create, named `FrameStation`, on a **Btrfs**
volume. Btrfs matters here: once this replaces Synology Photos it holds the
family's only copy, and snapshots plus checksums are the difference between a
bad day and a lost decade.

**Then set `FRAMESTATION_ROOT` in `.env` to match, exactly.** The path is
case-sensitive, and `docker-compose.yml` defaults to lowercase
`/volume1/framestation` — so a `.env` that omits the key, or spells it
differently to the shared folder, does not error. Docker creates a second
directory at the other spelling and writes there instead, which looks like a
working deployment with an empty library. This NAS uses `/volume1/FrameStation`;
whatever you choose, it goes in `.env` rather than being left to the default.

#### 4. Create the bind-mount directories

**Synology's Docker will not auto-create missing bind-mount sources** the way
standard Docker does — it fails the container with
`Bind mount failed: '…/pgdata' does not exist`. Make them first:

```bash
mkdir -p /volume1/docker/framestation/{pgdata,blobs,derivatives,incoming}
```

`Shared` holds shared-space libraries (`FRAMESTATION_SHARED_ROOT`, mounted at
`/data/Shared`). Postgres chowns `pgdata` to its own user on first boot, so no
permissions work is needed.

#### 5. Configure and start

Copy `docker-compose.yml` and `.env` (from `.env.example`) to the NAS. Generate
the Postgres password with `openssl rand -base64 32`, then:

```bash
docker compose pull && docker compose up -d
```

```bash
curl -s http://127.0.0.1:8080/health
```

Expect `{"status":"ok","database":"up",...}`. Migrations apply automatically on
first boot.

The container runs as **root** (`FRAMESTATION_USER` in `.env`). Writing into
`/volume1/homes` and handing each file to its DSM owner with `chown` are both
things a non-root process cannot do, and without them photos never leave the
blob store. Set `FRAMESTATION_USER=vapor:vapor` to decline — uploads still
work, they just stay content-addressed.

#### 6. Expose it through the DSM reverse proxy

Control Panel → Login Portal → Advanced → Reverse Proxy. Source
`yourhost.synology.me:8443` → destination `localhost:8080`, with your existing
Let's Encrypt certificate assigned. Add the matching router port forward.

The container binds to `127.0.0.1` only, so the proxy is the sole entry point.
Leave DSM auto-block and the firewall on.

#### 7. Split-horizon DNS

Resolve `yourhost.synology.me` to the NAS's **LAN IP** from inside the house —
DSM's DNS Server package, or a router DNS override. One hostname everywhere:
valid TLS, full LAN speed at home, no NAT hairpin, no second certificate.

This is a prerequisite for M5, not a nicety. Background `URLSession` uploads
run out-of-process in `nsurlsessiond`, where custom server-trust overrides are
unreliable — the app may not even be running to answer the challenge. Without a
publicly-valid certificate the backup engine fails intermittently and opaquely.

#### 8. Sign in — with DSM, not an invite

Family members sign in with their **DSM account**, in the app. That is what
records `dsm_username` and `dsm_uid`, and those are what put someone's photos
in their own home directory.

An invite-created account has neither, so `BrowseTree.directory` cannot place
its files: they stay in the content-addressed blob store, `storage_path` stays
NULL, and that person silently runs the pre-§3a model while everyone else does
not. Invites remain the fallback for someone with no DSM account at all:

```bash
docker compose exec server ./FrameStationServer invite
```

Signing in with DSM later adopts an existing row by username (matched
case-insensitively), so an invite account can be upgraded — but only if the
DSM username matches.

### Verifying the library layout

The check that proves ARCHITECTURE.md §3a is actually in force, rather than the
server having quietly fallen back to the blob store. Back up one photo from the
app, then:

```bash
ls -R /volume1/homes/<dsm-user>/Photos/
```

A `YYYY/MM/IMG_*.heic` there is the whole decision working. Nothing
there means the layout is off, the account has no DSM link, or the container is
not root — in that order of likelihood.

Then confirm the index can be rebuilt from those files alone:

```bash
docker compose exec server ./FrameStationServer rebuild --dry-run
```

It reports the files, people and shared libraries it found, and writes nothing.

---

## Design notes worth knowing before editing

- **SQLKit, not Fluent.** The schema is hand-written DDL and the queries that
  matter later — timeline bucket aggregation, `change_log` deltas, advisory
  locks — are ones an ORM obstructs.
- **`withPinnedConnection` for anything transactional.** The pooled `sql`
  property hands out a potentially different connection per query, so
  `BEGIN`/`COMMIT` issued through it would not bracket the work.
- **Migrations are split into individual statements** before execution, because
  PostgresNIO's extended query protocol rejects multi-statement queries.
- **`change_log` writers must hold `pg_advisory_xact_lock`** on the space.
  `bigserial` is assigned at INSERT, not COMMIT, so concurrent uploads can
  commit out of sequence order and a client polling `since=N` would permanently
  miss rows. See ARCHITECTURE.md §5.
- **A failed transfer is classified before it is counted.** `TransferFailure`
  decides whether a failure was the network's fault, the token's, or the item's,
  and only the last spends one of an item's three retries. Anything that adds a
  new failure path should classify it — treating an outage as an item failure is
  how a whole queue ends up parked behind a Retry button.
- **The image cache is bounded, and that is not optional.** `ThumbnailLoader`
  evicts least-recently-used down to 80% of its cap. The read path touches each
  file's modification date on a hit, which is what makes "least recently *used*"
  true rather than "oldest" — don't remove it as a stray write.
- **The timeline snapshot lives in Application Support, not `Caches/`.** iOS
  empties `Caches/` under storage pressure, which is exactly the moment someone
  needs their library to still open. Images may be evicted; the metadata that
  lets the grid draw at all may not.
- **Sign-out clears three things,** not one: credentials, the timeline snapshot,
  and the image cache. The snapshot holds a family's dates and places and has no
  business surviving into the next person's session.
