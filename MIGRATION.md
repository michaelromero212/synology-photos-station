# Moving media in from Synology Photos

How the family's Synology Photos libraries come into FrameStation without
downloading or re-uploading anything. The import reads each file where it
already lies on the NAS and clones it into the blob store. The Synology copy is
left exactly as it was, and the clone takes no extra space.

Synology Photos' Shared Space came across on 2026-10-06; the [log](#log) has the
numbers. Each person's own library is still to do, and
[the plan for it](#next-everyones-personal-library) is at the end.

Every command goes through the `ssh nas` alias, so no hostname or address
appears here (see [DEPLOY.md](DEPLOY.md)). `<space-id>`, `<user>` and `<device>`
are placeholders: type the value without the angle brackets. `--space <id>` with
brackets is a shell redirect, and the command fails before it starts.

## Where Synology Photos keeps things

| In Synology Photos | On the NAS | Comes into |
|---|---|---|
| Shared Space | `/volume1/photo/`, uploads under `PhotoLibrary/YYYY/MM/` | Family Shared, **done 2026-10-06** |
| A person's phone backups | `/volume1/homes/<user>/Photos/MobileBackup/<device>/YYYY/MM/` | that person's personal library |
| A person's browser uploads | `/volume1/homes/<user>/Photos/PhotoLibrary/YYYY/MM/` | that person's personal library |

A folder in the Synology Photos app is a folder on disk: the Shared Space's
`PhotoLibrary/2026/09` is `/volume1/photo/PhotoLibrary/2026/09`.

**The app's own folders sit beside Synology's.** Each person's `Photos` folder
also holds `Personal/` and `Shared/<Space>/`, FrameStation's File Station mirror.
Never point an import at `Photos/` itself: the walk would go into `Shared/` as
well and file every family photo in that person's personal library. Import
`MobileBackup` and `PhotoLibrary` separately.

## Before any import

1. **Snapshot `docker` and `homes`** in DSM's Snapshot Replication. The import
   writes the database and blob store under `docker`, and the File Station
   mirrors land in `homes`. The source is only read.
2. **Have the server on the newest image** ([DEPLOY.md](DEPLOY.md)). The import's
   one-off container runs whatever image the NAS holds and applies its
   migrations on start, so it should be the build the server is already running.
3. **Check that the mirrors hold the photos.** Each imported photo also appears
   in File Station: in every member's home for a shared library, in the owner's
   for a personal one. Count the empty files there. It should be 0:

   ```bash
   ssh -t nas "sudo sh -c 'find /volume1/homes/*/Photos/Personal /volume1/homes/*/Photos/Shared -path \"*/@eaDir\" -prune -o -type f -size 0 -print 2>/dev/null | wc -l'"
   ```

   **On 2026-10-06 every one was empty, 2,791 of 2,791.** The server reached the
   blob store and the homes through two separate mounts, the arrangement that
   also failed the import's own clone check ([below](#the-import)). `cp` left an
   empty file behind each time, and the tree counted it as placed, so the
   database's `link_kind` said `reflink` for all of them. That's why this check
   counts files instead. No photo was affected, because the app serves from the
   blob store. The same day, clones began going through one mount of the whole
   volume, and the server refills empty copies itself. Its log says
   `browse tree: refilled N empty File Station copies` (DEPLOY.md, "Reflink
   works…").
4. **Dry run.** It walks and counts without hashing or writing, and its count is
   the one to trust. `du` overstates, because Synology keeps thumbnails in an
   `@eaDir` folder beside every photo: it said 316 GB for a Shared Space holding
   277.7 GB of media.

## Finding the destination

```bash
ssh -t nas 'cd /volume1/docker/framestation && sudo /usr/local/bin/docker compose exec server ./FrameStationServer spaces'
```

Each library prints its name, its kind (`personal` or `shared`), how many items
it holds, a `space:` id and its owner. The `space:` id is what `--space` takes.

## The import

Dry run first, then the same command without `--dry-run`:

```bash
ssh -t nas 'cd /volume1/docker/framestation && sudo /usr/local/bin/docker compose run --rm server import --path /volume1/photo --space <space-id> --dry-run'
```

**Why it reads `/volume1/...` directly.** DSM's kernel won't clone a file
between two separately mounted folders, even two on the same volume. The first
attempt mounted the library on its own (`-v /volume1/photo:/import/photo:ro`),
and the import's one-file clone check stopped it before anything was written.
On the NAS itself the same clone worked, because there `/volume1` is a single
mount. The compose file now mounts all of `/volume1` once, and the import
clones into the blob store through that mount (`FRAMESTATION_CLONE_BLOB_ROOT`),
so the library and the blob store are one mount to the kernel. The Shared Space
went in before compose had that, so its run added the mount by hand:
`-v /volume1:/volume1 -e FRAMESTATION_BLOB_ROOT=/volume1/docker/framestation`.
Don't add those any more, since compose already mounts `/volume1`.

**While it runs,** a progress line every 64 files gives the count, bytes, files
per second and time left. Most of the time goes on reading every byte to
fingerprint it. The clones themselves are instant and take no space.

**When it finishes:**

| Summary line | Means |
|---|---|
| `Imported` | New to the app. Thumbnails queued. |
| `Stored once already` | The app already held these bytes, say a photo someone also backed up to their own library. It gets a row of its own over the same stored bytes, so an edit in one library never changes the other, and its thumbnails come along. |
| `Already in library` | The destination already has it, in Recently Deleted or deleted for good included. Skipped: a removal isn't the import's to undo. |
| `Failed` | Run the same command again to retry them. Everything that succeeded is skipped. |

**Afterward:**

- **The same background work as an upload:** thumbnails first, four at a
  time, then the full metadata the Information panel shows, and for each video
  a smaller copy for streaming on cellular. A photo shows up in File Station
  once its thumbnails exist. Place names are filled in during the import
  itself, from each file's GPS, so a day can name and group its places from
  the start.
- **One notification.** An import is one bulk session, so a shared library's
  members get a single summary push. Personal libraries never push.
- **Credit** goes to the destination's owner, since files don't record who added
  them. `--user <id>` credits another member instead.
- **Names and dates.** Original filenames are kept. A file whose metadata has no
  capture date is dated by its modification time. Live Photos pair by name
  within a folder: `IMG_1234.HEIC` with `IMG_1234.MOV`.

## When it goes wrong

- **A refusal prints its reason as one `[ WARNING ]` line** and exits with
  status 1. Every check runs before the first write, so a run that stops this
  way imported nothing. A server image from before 2026-10-06 printed the
  reason twice and then "Fatal error … Program crashed" with a backtrace; that
  meant the same thing.
- **"Couldn't make a reflink copy of …"** means the clone check failed. On this
  NAS, first check that the compose file in use mounts `/volume1` and sets
  `FRAMESTATION_CLONE_BLOB_ROOT`, and that `--path` starts with `/volume1/`.
  Fall back to `--mode copy` only if the clone fails outside the container too:

  ```bash
  ssh -t nas 'sudo cp --reflink=always "<a file under the source>" /volume1/docker/framestation/.reflink-test && echo "HOST REFLINK WORKS"; sudo rm -f /volume1/docker/framestation/.reflink-test'
  ```

  `--mode copy` needs free space equal to the library and stores it twice.
  `--mode hardlink` can't link across shared folders, each being its own Btrfs
  subvolume, so it quietly copies too.
- **The connection dropped.** Before running it again, make sure the first run
  isn't still going. Two imports at once can add the same photo twice.

  ```bash
  ssh -t nas 'sudo /usr/local/bin/docker ps --filter name=server-run'
  ```

  An empty list means it's safe. The same command carries on where it stopped.
- **Runs are remembered by path.** The import records each file by the path the
  container saw, across every library. Keep the mount and `--path` the same from
  run to run: a different spelling walks and hashes everything again, adding
  nothing but taking the full time. It also means a folder imports into one
  library only. A second import of `/volume1/photo`, into any library, reports
  every file as already imported.

## Log

| Date | From | Into | Files | Size | Imported | Stored once already | Already in library | Failed | Took |
|---|---|---|---|---|---|---|---|---|---|
| 2026-10-06 | Shared Space, `/volume1/photo` | Family Shared | 2,734 | 277.7 GB | 2,616 | 110 | 8 | 0 | 1h 5m |

That's about 70 MB/s, or 250 GB an hour, for files averaging about 100 MB.
ARCHITECTURE.md's ~175 MB/s estimate was for hashing alone, so plan with the
measured pace.

**What that import missed, fixed afterward.** It ran before the import named
places or queued anything but thumbnails. Its new photos had their GPS
coordinates but no place name, so a day with photos from Ohio and Virginia
read "Reston, Virginia" and didn't split. The full metadata and the cellular
video copies came later, from catch-up passes that run each time the server
starts. The place names were filled in by hand, once:

```bash
ssh -t nas 'cd /volume1/docker/framestation && sudo /usr/local/bin/docker compose exec server ./FrameStationServer geocode'
```

It names every photo that has coordinates and no place, and leaves the rest
alone. Imports since don't need it.

## Next: everyone's personal library

Not started. It waits until the family is ready to switch. Counted in August
2026: about 67,000 files and 662 GB in three people's `MobileBackup` folders,
plus about 2,500 files under `PhotoLibrary`. There will be more by now.

**Use `import`, not `rebuild`.** `rebuild` is disaster recovery: it rebuilds the
whole database from the folders after losing `pgdata`, and favorites, albums
and photo ids don't survive it. `import` adds to the running library. It also
takes the destination by id, so a DSM login that doesn't match its home folder's
name, a problem for `rebuild`, doesn't matter here.

For each person:

1. **Find their library** in `spaces`: kind `personal`, owned by them. Someone
   who has never signed in to the app has no library yet. Signing in once
   creates it.
2. **See what their `Photos` folder holds:**

   ```bash
   ssh -t nas 'sudo ls -la "/volume1/homes/<user>/Photos"'
   ```

   Expect Synology's `MobileBackup` and `PhotoLibrary` beside the app's
   `Personal` and `Shared`. Anything else is a folder they made, so ask them.
3. **Try one month first.** Their phone has probably been backing up to the app
   already. That overlap is skipped only where the bytes are identical, and
   Synology's backup may have kept a different version of the same picture,
   such as an edited or Portrait photo. Import a month they know well and look
   at it in the app:

   ```bash
   ssh -t nas 'cd /volume1/docker/framestation && sudo /usr/local/bin/docker compose run --rm server import --path "/volume1/homes/<user>/Photos/MobileBackup/<device>/2025/06" --space <space-id>'
   ```

   If it shows doubles, stop and work out why before the rest. The full run
   skips that month by itself.
4. **Then each folder whole,** dry run first: `--path
   "/volume1/homes/<user>/Photos/MobileBackup"`, then `.../PhotoLibrary`. At the
   Shared Space's pace, 662 GB is about 2¾ hours of reading for all three, but
   these files are a tenth the size on average, so per-file work counts for
   more. Allow an evening for the biggest library, with the Mac awake and on the
   home network.
5. **Afterward,** thumbnails fill in over the following hours. Their iPhone then
   works through the imported photos for curated albums and search, a batch at
   a time while the app is open, pausing for Low Power Mode, heat and backups.
   With tens of thousands of photos that takes a while. Nothing needs doing.

**Leaving Synology Photos.** Once someone is happy with their library in the
app: turn off Synology Photos' backup on their phone, run their import once
more to catch what arrived in between, and then they can delete `MobileBackup`
and `PhotoLibrary`. That never touches the app's copies. Files the import
cloned free no space when deleted, since the two share blocks; files the app
already had from a phone backup free their full size. The Shared Space goes the
same way: one last import once the family stops adding there, then Synology's
copies can go. With nobody left on it, Synology Photos can be stopped in
Package Center.
