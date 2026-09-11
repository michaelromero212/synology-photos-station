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
[README.md](README.md) § "First-time setup". This file is the routine path:
a change is on `main` and needs to reach the NAS.

| | |
|---|---|
| SSH alias | `nas` → `<nas-lan-ip>` (see below — it moves; `DEPLOY.local.md`) |
| Stack | `/volume1/docker/framestation/` (compose, `.env`, `pgdata`, `blobs`) |
| Media | `/volume1/FrameStation/` (shared libraries only) |
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

The cache key is coarser than it looks. `Server/Dockerfile` does
`COPY ./Packages ./Packages`, so editing FrameStationKit — which the server never
compiles — still busts the layer and forces the full release rebuild. Narrowing
that COPY to `./Packages/FrameStationAPI` would make app-only commits free.

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

**5. Verify it's the *new* build.** Step 4 cannot tell you this — see below — and
this is the step that catches a deploy which quietly didn't take.

Ask the image which commit it was built from. CI stamps OCI labels through
`docker/metadata-action`, so the running image names its own source:

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
than encrypted — normal Docker behaviour, but it means root on the NAS can read
the token. Give it the narrowest scope, and note the expiry date somewhere: this
failure returns on that day.

The alternative is making the package public, which removes the credential
entirely and cannot expire. The image holds the compiled server and its runtime
dependencies — no data, no secrets — so it is a defensible choice; it is simply a
decision about publishing rather than about deployment.

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

### A green local build is not a green CI build

CI runs **Xcode 16.4 (iOS SDK 18.5)** on `macos-15`. This Mac runs **Xcode
26.6 (SDK 26.5)**. That gap is wide enough to matter, and it fails in the
direction that wastes the most time: the local build passes, the push looks
safe, and the runner rejects it fifteen minutes later.

The way it bites is not obvious. Apple sometimes annotates a constant
`API_AVAILABLE(ios(13))` — meaning the OS has set that bit since iOS 13 — while
only *exposing* the name in a much newer SDK header.
`PHAssetMediaSubtypeVideoScreenRecording` is exactly that: available since iOS
13, absent from SDK 18.5, present in SDK 26. Xcode 26 compiles
`.videoScreenRecording` happily; Xcode 16.4 says the type has no such member.

When it happens, the fix is usually the raw bit value rather than the name —
the bits are public and ABI-stable, only the spelling is unportable. See
`PhotoLibraryScanner.subtypes(of:)`.

The cheap habit that avoids the round trip: when reaching for a PhotoKit or
SwiftUI symbol that looks recent, check its line in the SDK header. Constants
clustered at the *end* of an enum are the late additions, and the late
additions are the ones CI will not have.

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

*`/health`.* `version` is `Build.version` in `Configure.swift`, bumped by hand —
a six-week-old image and a current one both say `1.1.0-M9`. It tells you the
server is *up*, never which server.

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
That is the assumption the whole layout rests on: if a future DSM or volume
change breaks reflink, `link` falls through to `copyItem` and every tree entry
silently becomes a second full copy. It logs `browse tree: copied … this
duplicates the file on disk` when that happens — worth grepping for after any
volume work.

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
