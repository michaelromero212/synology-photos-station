# Deploying the server

The exact commands, ready to paste. Every one of these has been run against this
NAS and worked.

Two values are deliberately **not** in this file: the NAS's public hostname and
its LAN address. They live in `DEPLOY.local.md`, which is gitignored. This
repository is public, and a home NAS's DDNS name published beside a map of its
stack, its paths and its health endpoint is a targeting aid — there is no reason
to hand that over. Everything else here is real and literal: the paths, the
ports, the image, `127.0.0.1`.

> **Future sessions, read this.** The `<nas-host>` and `<nas-lan-ip>`
> placeholders below are not an unfilled template. The real values exist, in
> `DEPLOY.local.md` — read them from there and substitute as you go. Do not
> paste them back into this file, and do not "helpfully" fill them in.

First-time setup of a fresh box is a different job — see
[README.md](README.md) § "First-time setup". Moving media in from Synology
Photos is another — see [MIGRATION.md](MIGRATION.md). This file is the routine
path: a change is on `main` and needs to reach the NAS.

| | |
|---|---|
| SSH alias | `nas` → `<nas-lan-ip>` (see below — it moves; `DEPLOY.local.md`) |
| Stack | `/volume1/docker/framestation/` (compose, `.env`, `pgdata`, `blobs`) |
| Media | `/volume1/FrameStation/` (shared libraries only) |
| Clones | through a second mount of all of `/volume1` (see "Reflink works…" under Gotchas) |
| Docker | `/usr/local/bin/docker` — **not on `PATH`** |
| Health | `http://127.0.0.1:8080/health` on the NAS |
| Public | `https://<nas-host>:8443` (`DEPLOY.local.md`) |
| Image | `ghcr.io/michaelromero212/framestation-server:latest` |

---

## The usual case

Server code changed, nothing else. Four commands.

**1. Push.** CI builds `linux/amd64` and publishes `latest`.

```bash
git push origin main
```

**2. Wait for CI.** The image job runs after the Linux build and tests, and its
duration is bimodal: **~16 minutes** when anything under `Server/` or `Packages/`
changed, and **under a minute** when nothing did — buildx hits its GHA cache and
only republishes the manifest. Measured across six runs: 15.8, 15.1, 0.5, 0.5,
0.4, 0.4. Pulling before it finishes gives `manifest unknown`.

`Server/Dockerfile` copies only `./Packages/FrameStationAPI` into the build, so
an app-only commit (FrameStationKit, `App/`) never busts the compile layer. The
revision stamp sits in the last layer, so it changes on every commit without
costing a rebuild.

```bash
gh run list --limit 1
```

**3. Pull and restart.**

```bash
ssh -t nas 'cd /volume1/docker/framestation && sudo /usr/local/bin/docker compose pull && sudo /usr/local/bin/docker compose up -d'
```

**4. Verify it's alive.**

```bash
ssh nas 'curl -s http://127.0.0.1:8080/health'
```

Expect `{"status":"ok","database":"up","migrationsApplied":N,...}`.

**5. Verify it's the *new* build.** This is the step that catches a deploy which
quietly didn't take, and the same check answers "is the NAS up to date?" any
day. Paste it from anywhere: it reads nothing from this checkout, so it also
works in a terminal that isn't allowed into `~/Documents` — macOS refuses that
to some, and then `git` and `gh` fail with `Unable to read current working
directory: Operation not permitted`.

```bash
cd ~ && R=michaelromero212/synology-photos-station
want=$(gh run list --repo $R --branch main --status success --limit 1 --json headSha --jq '.[0].headSha')
want_migrations=$(gh api "repos/$R/contents/Server/Sources/FrameStationServer/Migrations/SQL?ref=$want" --jq '[.[] | select(.name | endswith(".sql"))] | length')
health=$(ssh -o ConnectTimeout=8 -o LogLevel=ERROR nas 'curl -s http://127.0.0.1:8080/health')
have=$(printf '%s' "$health" | sed -n 's/.*"revision"[[:space:]]*:[[:space:]]*"\([0-9a-f]*\)".*/\1/p')
have_migrations=$(printf '%s' "$health" | sed -n 's/.*"migrationsApplied"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')
if [ -z "$want" ]; then echo "❌ Couldn't ask GitHub for the newest build. Is gh signed in?"
elif [ -z "$health" ]; then echo "❌ Couldn't reach the NAS. Are you on the home network, and does 'ssh nas' work?"
elif [ -z "$have" ]; then echo "❌ The NAS runs an image from before it reported its commit. Pull and restart."
else
  echo "Newest build: ${want:0:7} · NAS runs: ${have:0:7} · migrations ${have_migrations:-?} of $want_migrations"
  changed=""
  if [ "$have" != "$want" ] && ! changed=$(gh api "repos/$R/compare/$have...$want" --jq '.files[].filename | select(startswith("Server/") or startswith("Packages/FrameStationAPI/") or . == "docker-compose.yml")'); then
    changed="(couldn't ask GitHub what changed)"
  fi
  if [ -n "$changed" ]; then
    echo "❌ The NAS is behind. Changed since its build ($(printf '%s\n' "$changed" | grep -c .) files):"
    printf '%s\n' "$changed" | head -15 | sed 's/^/     /'
    echo "   Pull and restart, then run this again. If docker-compose.yml is listed, see \"When the compose file changed\"."
  elif [ "$have_migrations" != "$want_migrations" ]; then
    echo "❌ The NAS runs the newest server but reports $have_migrations of $want_migrations migrations. Check its log."
  else
    echo "✅ The NAS is up to date."
    if [ "$have" != "$want" ]; then echo "   Newer commits on main don't change the server."; fi
  fi
fi
```

It asks GitHub for the newest commit on `main` that passed CI — the image a pull
fetches — and asks the NAS which commit it is running: `/health` reports it as
`revision`. The two needn't match for the NAS to be current. Every commit on
`main` publishes an image, a docs-only one included, so what counts is whether
anything changed under `Server/`, `Packages/FrameStationAPI/` or
`docker-compose.yml` in between — the same definition as "Checking what's
deployed without touching the NAS" below. It also compares the migrations the
NAS has applied with the ones in that commit. Tested against the NAS: current,
a build a week stale (it lists the 19 server files since), and one docs-only
commit behind (current).

By hand, right after a push, the running commit against the one pushed —
`/health` answers without SSH or sudo:

```bash
curl -s https://<nas-host>:8443/health      # "revision": "<full sha>"
git rev-parse HEAD
```

They match or they don't. Images built before `revision` existed don't report
one; for those, ask the image itself. CI stamps OCI labels through
`docker/metadata-action`, so it names its own source:

```bash
ssh -t nas "sudo /usr/local/bin/docker inspect ghcr.io/michaelromero212/framestation-server:latest --format '{{index .Config.Labels \"org.opencontainers.image.revision\"}}'"
```

Compare the first seven characters against what you pushed:

```bash
git rev-parse --short HEAD
```

They match or they don't; there is nothing to interpret. This is the only check
here that stays true a week later — every other signal below decays into "some
time ago" and stops distinguishing a deploy that worked from one that never
happened.

It reads the tag rather than the container on purpose. A pull that failed leaves
`:latest` pointing at the *old* image locally, so the label reports the old
commit — which is exactly the answer wanted.

**Corroborating signals.** Useful in the minutes after a deploy, and worth a
glance because they come free with the pull.

```bash
ssh -t nas 'cd /volume1/docker/framestation && sudo /usr/local/bin/docker compose ps && sudo /usr/local/bin/docker compose images'
```

Read the `STATUS` column for **`server`**:

```
NAME                    ...   CREATED          STATUS
framestation-db-1       ...   5 days ago       Up 5 days (healthy)
framestation-server-1   ...   2 minutes ago    Up 2 minutes
```

Minutes means the pull took. Hours or days means it didn't, and the old code is
still serving. **`db` being days old is correct** — nothing in a server-only
deploy touches it, and recreating it would be the surprise.

The pull output in step 3 is corroborating evidence. A server layer reporting
`Pull complete` rather than `Already exists` means the image genuinely changed:

```
✔ server 8 layers [⣿⣿⣿⣿⣿⣿⣿⣿]  Pulled
  ✔ d544298cabd5 Already exists      ← base OS and Swift runtime, unchanged
  ...
  ✔ 906865990182 Pull complete       ← the compiled server. This is the one to look for
```

Seven `Already exists` and one `Pull complete` is the normal shape of a code-only
deploy: same base, new binary.

---

## What else the change needs

Work out which row applies **before** step 3.

| Changed | Extra step |
|---|---|
| Server Swift only | none — the four commands above |
| A new `Migrations/SQL/*.sql` | snapshot `pgdata` first, then confirm the new `migrationsApplied` |
| `docker-compose.yml` or `.env.example` | copy the file up **before** pulling — see below |
| A new bind mount in compose | create the directory on the NAS first; Synology's Docker fails rather than creating it |
| App or `Packages/` only | nothing. That ships through Xcode, not the NAS |

`0025_placement_lookup` is a data migration as well as an index: it marks the
video half of every Live Photo that was deleted before deletions took both
halves as deleted with its still, so retention cleans them up. Snapshot
`pgdata` before the first deploy that carries it, as for any migration.

### Turning on push

Push — activity banners, and the silent push that wakes a phone whose backup
iOS has paused overnight — is off until the NAS has Apple's key. Create an
**APNs key** in the Apple Developer portal (Keys → +, Apple Push Notifications
service), download it, and copy it up **with its name unchanged**:

```bash
ssh nas 'mkdir -p /volume1/docker/framestation/secrets && chmod 700 /volume1/docker/framestation/secrets'
cat AuthKey_ABC123DEFG.p8 | ssh nas 'cat > /volume1/docker/framestation/secrets/AuthKey_ABC123DEFG.p8'
ssh -t nas 'cd /volume1/docker/framestation && sudo /usr/local/bin/docker compose up -d --force-recreate server'
```

The key ID is read from the file name, and the team and topic default to this
app's. The log confirms it: `push enabled — key ABC123DEFG, topic
com.michaelromero.FrameStation`. Debug builds are a separate app
(`….FrameStation.dev`) and register sandbox tokens; those are sent under the
`.dev` topic automatically. A key that can't be read turns push off — it is
logged — and never stops the server starting.

### The old `browse/` tree

Every upload used to hardlink its blob into `/volume1/docker/framestation/browse/`,
and nothing removed those links, so purged photos kept their bytes on disk. The
server now takes that tree apart by itself on its first start, logging a
`legacy browse tree:` summary: extra names removed, space freed, any missing
blob restored from it, and anything it doesn't recognize left in place. To see
what it will do first, ask the new image before it serves: pull, a one-off
run, then step 3 as usual.

```bash
ssh -t nas 'cd /volume1/docker/framestation && sudo /usr/local/bin/docker compose pull && sudo /usr/local/bin/docker compose run --rm server retire-legacy-browse --dry-run'
```

Not `exec`: the old container doesn't have the command, and the new one has
already done the work by the time you can exec into it. The one-off run applies
the image's migrations, as every start does, so take the `pgdata` snapshot
before it rather than after.

Two failures arrive without changing anything yourself, because they are about
the NAS rather than the commit: the **address moving** (DHCP — see Gotchas) and
the **registry token expiring** (see below). Neither announces itself until a
deploy is already half done.

### When the compose file changed

`docker compose pull` updates the **image**, never the file that names it. Skip
this and you get new code running under old configuration, silently.

```bash
cat docker-compose.yml | ssh nas 'cat > /volume1/docker/framestation/docker-compose.yml'
```

> If that fails with `cat: docker-compose.yml: Operation not permitted`, macOS
> is blocking your terminal from reading `~/Documents`. Either grant it
> **System Settings → Privacy & Security → Full Disk Access** and restart it,
> or ask Claude to push the file up — its tooling has its own grant.

### When the pull says `unauthorized`

The server image is a **private** GHCR package, so the NAS has to be logged in to
fetch it. The credential is a GitHub personal access token, and tokens expire —
so this breaks on a date nobody wrote down, in the middle of a deploy.

The symptom is specific and easy to misread:

```
✔ db 11 layers [⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿] Pulled
WARNING: Some service image(s) must be built from source by running:
    docker compose build server
1 error occurred:
	* Error response from daemon: Head "https://ghcr.io/v2/.../manifests/latest": unauthorized
```

`db` pulls happily — it comes from Docker Hub and is public — so the output looks
mostly successful, and every one of those completed layers is postgres. Only the
`server` line failed. The "must be built from source" warning is compose saying
it gave up fetching, not a suggestion worth taking: building the Vapor graph on a
J4125 takes far longer than fixing the login.

**Fixing it.** Take the two steps separately rather than as one `ssh -t nas '…'`,
because you are asked for two different secrets in a row and *both prompts say
`Password:`*:

```bash
ssh -t nas
```

```bash
sudo /usr/local/bin/docker login ghcr.io -u michaelromero212
```

1. First `Password:` — the NAS account password, for `sudo`
2. Then `Password:` — the GitHub PAT, for `docker login`

Pasting the token into the first prompt is the obvious mistake, and a one-liner
puts the two prompts back to back with nothing to distinguish them.

Expect `Login Succeeded`, then re-run step 3.

**The token needs package read.** A classic PAT needs `read:packages`; a
fine-grained one needs Packages → Read. Without it `docker login` still reports
`Login Succeeded` and the *pull* fails with the same `unauthorized` — the login
proves who you are, not what you may read.

**Where it lands.** `/root/.docker/config.json` on the NAS, base64-encoded rather
than encrypted — normal Docker behavior, but it means root on the NAS can read
the token. Give it the narrowest scope, and note the expiry date somewhere: this
failure returns on that day.

The alternative is making the package public, which removes the credential
entirely and cannot expire. The image holds the compiled server and its runtime
dependencies — no data, no secrets — so it is a defensible choice; it is simply a
decision about publishing rather than about deployment.

### When the pull says `denied` and the package is public

A different failure with a nearly identical look, and the fix is the opposite
one: log *out*.

`unauthorized` means no credentials. **`denied` means credentials that are not
permitted** — so Docker is logged in and being refused, which on a public package
can only mean the stored login has gone stale. A token whose `read:packages`
scope lapsed, or that expired, is *worse than no token at all*: Docker sends it,
GHCR judges the authenticated request and refuses, and the anonymous path a
public package would otherwise offer is never tried.

Check whether the package is actually public before touching the NAS, from your
Mac, with no credentials involved:

```bash
T=$(curl -s "https://ghcr.io/token?scope=repository:michaelromero212/framestation-server:pull&service=ghcr.io" \
    | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")
curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $T" \
    https://ghcr.io/v2/michaelromero212/framestation-server/manifests/latest
```

`200` means the image is anonymously pullable and the NAS is the problem:

```bash
ssh -t nas 'sudo /usr/local/bin/docker logout ghcr.io'
```

`sudo`, because the credential is in `/root/.docker/config.json` — a logout as
your own user clears a different file and changes nothing. Then re-run step 3.

Worth knowing that repository visibility and **package** visibility are separate
settings. Making the repo public does not touch a container package, and a
public repo can publish a private image indefinitely without saying so.

### When a migration is pending

Migrations apply automatically on first boot of the new image, atomically and
in filename order. They do not run backwards. Compare before deciding:

```bash
ls Server/Sources/FrameStationServer/Migrations/SQL/*.sql | wc -l   # on your Mac
ssh nas 'curl -s http://127.0.0.1:8080/health'                      # migrationsApplied
```

Snapshot `pgdata` if those differ. Btrfs snapshots are why the shared folder is
on Btrfs.

---

## Gotchas, each one earned

### One toolchain everywhere

CI builds with the same tools as this Mac: **Xcode 27** for the apps and the
Kit tests, on GitHub's `xcode-27` runner image, and the Swift it ships,
**6.4.0**, for the server on Linux. Nothing moves on its own, and where a pin
can drift CI checks it:

| What | Pinned in |
|---|---|
| Xcode for the apps and Kit tests | `DEVELOPER_DIR` in both macOS jobs of `.github/workflows/ci.yml` — by path, so GitHub changing its runner's default Xcode changes nothing here |
| Swift for the server | `.swift-version`, `ARG SWIFT_VERSION` in `Server/Dockerfile`, and the `server-linux` container in `ci.yml` — that job's first step fails if the three disagree |
| Swift in cloud sessions | `SWIFT_VERSION` in `Scripts/cloud-setup.sh`, the environment's setup script — paste it into the environment settings again after changing it |
| Server dependencies | `Server/Package.resolved` — CI and the Dockerfile build with `--force-resolved-versions` and fail rather than deviate |

Why the server's Swift follows the Mac's: `Package.resolved` is written by
whatever Swift resolved it, and that's Xcode's. A Linux toolchain older than
the lockfile doesn't fail — SwiftPM quietly re-resolves to older versions it
*can* build. While the image was on Swift 6.0 it shipped older `swift-nio-ssl`,
`swift-asn1`, `swift-nio-http2` and `postgres-kit` than the lockfile named, and
every build was green.

**Moving to a new Xcode:** install it on the Mac, point `DEVELOPER_DIR` at it,
move the three Swift pins and `cloud-setup.sh` to the Linux release of the Swift
it ships (`swift --version` in its toolchain), re-resolve in `Server/` if
dependencies should move too, and push it as one commit. CI says whether it all
fits before anything is published.

Until October 2026 CI ran Xcode 16.4 while this Mac moved through 26 to 27, and
the gap showed up two ways. Code was bent to fit the older SDK — raw PhotoKit
bit values where the names were missing from SDK 18.5, and `#if compiler(>=6.2)`
around everything Liquid Glass — and, worse, everything behind those guards went
uncompiled by CI. `PHAsset.adjustmentTimestamp` is in the iOS 27 SDK and not in
26.5, so the app needs Xcode 27 to build; CI couldn't have said so. It can now,
and none of the bending is needed any more.

**The NAS is on DHCP, so its address moves.** It has changed once already;
`DEPLOY.local.md` carries the current one. The symptom is not an error you can
read: `ssh` sits there and eventually times out, and because the session never
opens, `sudo` never prompts —
so it looks like the password step is broken rather than the network. Check
before assuming anything else is wrong:

```bash
ping -c 2 <nas-lan-ip>
```

If that fails, find the current address in DSM (Control Panel → Network →
Network Interface) or the router's client list, then fix `HostName` in
`~/.ssh/config` and `DEPLOY.local.md`. A DHCP reservation on the router stops
this recurring; the alternative is rediscovering it every few months.

The public endpoint keeps working throughout, because it goes through DSM's
reverse proxy rather than the LAN address — which makes it a useful way to check
the server is alive, and what it thinks its migration count is, without SSH:

```bash
curl -s https://<nas-host>:8443/health
```

**`ssh -t`, not `ssh`.** `sudo` needs a TTY. Without `-t`:

```
sudo: a terminal is required to read the password
```

**`/usr/local/bin/docker`.** Docker isn't on the default `PATH` on DSM, and it
needs `sudo` — the daemon socket refuses ordinary users.

**Don't pass Go template escapes through `ssh`.** `--format "{{.Service}}\t..."`
arrives with a literal backslash and Docker rejects it with
`could not be parsed`. Plain `docker compose ps` shows the same columns.

**Three ways of checking the NAS is current that don't work.** Each looks
convincing, which is the problem. Step 5 above is the one that does.

*`/health`'s `version`.* `Build.version` in `Configure.swift` is bumped by hand —
a six-week-old image and a current one both say `1.1.0-M9`. Read `revision`
beside it instead, which CI stamps into every image.

*The image tag in `compose images`.* It reads `latest`, always, because that is
what `docker-compose.yml` asks for. CI does publish a `sha-<short>` tag, but
nothing on the NAS is pulling by it, so the `TAG` column can never identify a
commit. The `IMAGE ID` does distinguish builds — it just doesn't say which. Read
the `org.opencontainers.image.revision` label instead (step 5), which does.

*Probing for a route the new code added.* The obvious idea, and it silently
always passes:

```bash
# Both return 401. So does a route that has never existed.
curl -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:8080/v1/spaces/$S/assets/share
curl -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:8080/v1/spaces/$S/assets/invented-nonsense
```

The auth middleware answers before routing resolves, so everything under
`/v1/spaces/…` is `401` whether the endpoint exists or not. A 404 only comes back
from paths outside that group. Calibrate any probe against a made-up route first;
this one read as a clean pass on a server that had not been updated at all.

**Pinning a known-good build.** CI publishes a `sha-<short>` tag alongside
`latest`, so a bad deploy can be rolled back without reverting anything:

```bash
# in /volume1/docker/framestation/.env on the NAS
FRAMESTATION_IMAGE=ghcr.io/michaelromero212/framestation-server:sha-abc1234
```

Then `pull && up -d` as usual. Remove the line to follow `latest` again. Note
this pins the *code* — a pinned image whose migrations have already been applied
does not un-apply them, so rolling back across a migration needs the `pgdata`
snapshot, not just the tag.

**Cleaning up images.** After a few deploys, Container Manager fills with
untagged copies. Select the `<none>` rows and Delete. **Don't** use "Remove
Unused Images" without looking: it also takes `ghcr.io/diaoul/subliminal`,
which a nightly DSM task uses, and `alpine`. Neither breaks — both re-pull on
next use — but it's pointless churn.

**The project name is fixed.** `docker-compose.yml` sets `name: framestation`,
so `down` in one directory and `up` in another address the same stack rather
than leaving two.

---

**The browse tree's two defaults disagree.** `BrowseTree.Configuration`
falls back to `"0"` in Swift; `docker-compose.yml` sets
`FRAMESTATION_BROWSE_TREE: ${FRAMESTATION_BROWSE_TREE:-1}`. Compose wins, so
the tree is **on** unless `.env` says otherwise — reading the Swift default
alone gives you the opposite answer, which cost an hour of reasoning from the
wrong premise. Check what is actually in effect:

```bash
ssh -t nas 'sudo grep -E "BROWSE_TREE|FRAMESTATION_(DATA|MEDIA|HOMES)=" /volume1/docker/framestation/.env'
```

Absent means the compose default applies, not the Swift one.

**Reflink works across shared folders on this NAS; hardlink does not.**
Measured, not assumed:

```
cp --reflink=always /volume1/docker/... /volume1/homes/...   → OK
ln                  /volume1/docker/... /volume1/homes/...   → FAILED
```

Each DSM shared folder is its own Btrfs subvolume, so hardlinks cannot cross
between them — but reflinks can. `BrowseTree.link` tries reflink first, so tree
entries share extents with the blob store and cost close to nothing on disk.
That is the assumption the whole layout rests on.

**On the host, that is. In a container a clone must also stay inside one
mount.** DSM's kernel refuses a clone between two separately mounted folders,
even on one volume, and the server reaches `/data` and `/homes` through two. The
2026-10-06 import hit it first, and mounting `/volume1` once fixed that. The
same day showed the tree had always hit it: every entry was an empty file, 2,791
of them, while `browse_entries.link_kind` said `reflink` for all. GNU
`cp --reflink=always` creates its destination before cloning into it and leaves
it empty when the clone fails, and `link` then counted the file already at the
path as placed. Photos were never at risk, because the app serves from the blob
store. But the File Station tree held nothing, and a `rebuild` from it would
have recovered nothing.

What changed, so it can't recur:

- **One mount for clones.** Compose also mounts all of `/volume1` at its own
  path and names the blob store and the homes inside it
  (`FRAMESTATION_CLONE_BLOB_ROOT`, `FRAMESTATION_CLONE_HOMES_ROOT`). Clones go
  through those paths (`CloneRoute`). Everything else, and every path stored in
  the database, still uses `/data` and `/homes`. The price is reach: the root
  container can now see every shared folder.
- **Nothing half-made at the real path.** `link` clones under a temporary name
  and renames into place. If the clone fails it tries a hardlink, and never a
  full copy. A copy per member of every shared photo would be hundreds of
  gigabytes, and once a failed clone stopped leaving an empty file, that
  fallback would have started running.
- **A check before placing.** Each start, the tree links one small file into the
  homes root first. Until that works it places nothing, and logs once:
  `browse tree: … File Station copies are paused rather than made as full
  copies`. When it works: `File Station copies can be made here`.
- **Empty copies refill themselves.** Each sweep checks 500 entries, round and
  round, and clones the photo over any empty file standing in for one. The log
  says `browse tree: refilled N empty File Station copies`.

The check that tells: the empty-file count in [MIGRATION.md](MIGRATION.md)
§ "Before any import" should be 0. `link_kind` alone can't show this.

Disk usage is one copy. Whether Synology's *per-user quota* accounting also
counts shared extents once is not established; watch `homes` usage after the
first large batch rather than assuming.

**Never let a group grant access to media shares.** The `docker` share was
found granting Read Only to a group that every household account belongs to,
which meant every member — and every member added in future — could read
`/volume1/docker/framestation/blobs` directly and browse the entire library,
personal spaces included. Group grants are inherited by accounts that do not
exist yet, so they are correct on the day they are set and wrong the moment
somebody joins. Access to `docker`, `FrameStation` and `homes` is per-user or
by home directory only.

---

### Every job failing in under ~15 seconds is billing, not code

The signature is unmistakable once seen: all jobs `failure`, each with no steps
executed. `gh run view <id>` gives the real reason, which the run list never
shows:

```
The job was not started because recent account payments have failed or your
spending limit needs to be increased.
```

That is **not** an exhausted free allotment, and it does not heal when the month
rolls over — it failed on 2026-09-09 and again on the 10th. It is a payment
method or spending limit, fixed only in Settings → Billing & plans.

**This repository is public as of 2026-09-10**, so its CI now runs on free
standard runners and never touches the spending limit. The wall still stands for
any *private* repo — `synology-nas-video-station` is the other one here with a
workflow.

The deploy consequence is the part that bites: a blocked run publishes no image,
so `:latest` silently stays where it was while `main` moves on. Nothing announces
it. Use the § above to measure the gap rather than assuming a push implies a
build.

---

## Checking what's deployed without touching the NAS

```bash
git log --oneline -1 origin/main                                  # what CI last built
git log --oneline <deployed-sha>..main -- Server/ Packages/FrameStationAPI docker-compose.yml
```

An empty second result means the NAS is current for server purposes, whatever
else has landed on `main`. This matters more than it sounds: the NAS once sat
**47 commits behind** — including an unpatched cross-user read — with nothing
surfacing it, because the app was being tested against a local server on
`:8099` and `/health` reported the same version throughout.
