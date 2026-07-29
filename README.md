# FrameStation

A self-hosted photo and video library for a family, running on a Synology NAS,
with native clients for iOS, iPadOS, macOS, and tvOS. Replaces Synology Photos.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full design. This file covers
running and deploying what exists today.

**Status: M2 + M3 (in progress).** Everything through the media pipeline,
plus the timeline manifest, delta sync, asset detail, and a working sectioned
grid on iOS with ThumbHash placeholders and a two-tier thumbnail cache.
Remaining in M3: a `UICollectionView` grid for 100k scale, and offline reverse
geocoding.

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
| PUT/DELETE | `/v1/spaces/:id/assets/:id/favorite` | Bearer | Per-user favourite, not a shared boolean |

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

### 1. Authenticate to GHCR

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
cat docker-compose.yml | ssh nas 'cat > /volume1/FrameStation/docker-compose.yml'
```

### 2. Create the shared folder

Control Panel → Shared Folder → Create, named `framestation`, on a **Btrfs**
volume. Btrfs matters here: once this replaces Synology Photos it holds the
family's only copy, and snapshots plus checksums are the difference between a
bad day and a lost decade.

### 3. Create the bind-mount directories

**Synology's Docker will not auto-create missing bind-mount sources** the way
standard Docker does — it fails the container with
`Bind mount failed: '…/pgdata' does not exist`. Make them first:

```bash
mkdir -p /volume1/FrameStation/{pgdata,blobs,derivatives,incoming,browse}
```

Postgres chowns `pgdata` to its own user on first boot, so no permissions work
is needed.

Note the path is case-sensitive and must match `FRAMESTATION_ROOT` in `.env`
exactly. A mismatch does not error — Docker silently creates a second directory
at the other spelling and writes there instead.

### 4. Configure and start

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

### 5. Expose it through the DSM reverse proxy

Control Panel → Login Portal → Advanced → Reverse Proxy. Source
`yourhost.synology.me:8443` → destination `localhost:8080`, with your existing
Let's Encrypt certificate assigned. Add the matching router port forward.

The container binds to `127.0.0.1` only, so the proxy is the sole entry point.
Leave DSM auto-block and the firewall on.

### 6. Split-horizon DNS

Resolve `yourhost.synology.me` to the NAS's **LAN IP** from inside the house —
DSM's DNS Server package, or a router DNS override. One hostname everywhere:
valid TLS, full LAN speed at home, no NAT hairpin, no second certificate.

This is a prerequisite for M5, not a nicety. Background `URLSession` uploads
run out-of-process in `nsurlsessiond`, where custom server-trust overrides are
unreliable — the app may not even be running to answer the challenge. Without a
publicly-valid certificate the backup engine fails intermittently and opaquely.

### 7. Create invites

Create an invite for each family member:

```bash
docker compose exec server ./FrameStationServer invite
```

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
