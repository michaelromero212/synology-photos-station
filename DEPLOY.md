# Deploying the server

The exact commands, with real values rather than placeholders. Every one of
these has been run against this NAS and worked.

First-time setup of a fresh box is a different job — see
[README.md](README.md) § "First-time setup". This file is the routine path:
a change is on `main` and needs to reach the NAS.

| | |
|---|---|
| SSH alias | `nas` → `192.168.1.17` (see below — it moves) |
| Stack | `/volume1/docker/framestation/` (compose, `.env`, `pgdata`, `blobs`) |
| Media | `/volume1/FrameStation/` (shared libraries only) |
| Docker | `/usr/local/bin/docker` — **not on `PATH`** |
| Health | `http://127.0.0.1:8080/health` on the NAS |
| Public | `https://mike-home-nas-920.synology.me:8443` |
| Image | `ghcr.io/michaelromero212/framestation-server:latest` |

---

## The usual case

Server code changed, nothing else. Four commands.

**1. Push.** CI builds `linux/amd64` and publishes `latest`.

```bash
git push origin main
```

**2. Wait for CI.** The image job takes ~8 minutes and runs after the Linux
build and tests. Pulling before it finishes gives `manifest unknown`.

```bash
gh run list --limit 1
```

**3. Pull and restart.**

```bash
ssh -t nas 'cd /volume1/docker/framestation && sudo /usr/local/bin/docker compose pull && sudo /usr/local/bin/docker compose up -d'
```

**4. Verify.**

```bash
ssh nas 'curl -s http://127.0.0.1:8080/health'
```

Expect `{"status":"ok","database":"up","migrationsApplied":N,...}`.

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

**The NAS is on DHCP, so its address moves.** It was `192.168.4.83` and is now
`192.168.1.17`. The symptom is not an error you can read: `ssh` sits there and
eventually times out, and because the session never opens, `sudo` never prompts —
so it looks like the password step is broken rather than the network. Check
before assuming anything else is wrong:

```bash
ping -c 2 192.168.1.17
```

If that fails, find the current address in DSM (Control Panel → Network →
Network Interface) or the router's client list, then fix `HostName` in
`~/.ssh/config` and the table above. A DHCP reservation on the router stops this
recurring; the alternative is rediscovering it every few months.

The public endpoint keeps working throughout, because it goes through DSM's
reverse proxy rather than the LAN address — which makes it a useful way to check
the server is alive, and what it thinks its migration count is, without SSH:

```bash
curl -s https://mike-home-nas-920.synology.me:8443/health
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

**`/health` cannot tell you the NAS is current.** `version` is
`Build.version` in `Configure.swift`, bumped by hand — a six-week-old image and
a current one both say `1.1.0-M9`. To actually tell:

```bash
ssh -t nas 'cd /volume1/docker/framestation && sudo /usr/local/bin/docker compose ps'
```

`STATUS` shows container age. Minutes means the pull took; hours means it
didn't. The pull output is evidence too — a layer reporting `Pull complete`
rather than `Already exists` means the image genuinely changed.

For the digest of what is running:

```bash
ssh -t nas 'cd /volume1/docker/framestation && sudo /usr/local/bin/docker compose images'
```

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
