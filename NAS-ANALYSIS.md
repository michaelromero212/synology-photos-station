# NAS analysis and faces: design and security

**Status:** shadow mode, running on the NAS since 2026-11-05. The NAS analyzes
and the server stores the results. Since phase 2 (§7), what the scenes mean can
be judged on the phone, photo by photo and as a preview of the whole Albums
page. Nothing changes for anyone until they switch it on.

This is the "separate explicit product/security design" that
[CURATED-ALBUMS-SPEC.md](CURATED-ALBUMS-SPEC.md) §36 requires before anything
identifies a person. It covers the analyzer, what is stored, and the rules for
face data.

The decisions behind it, from 2026-11-05:
- **Faces are in.** The user names people, the system learns who they are over
  time, and albums are renamed or created around them.
- **Photos and videos both.**
- **Identical on every device:** iPhone, iPad, Mac and Apple TV.
- **Low maintenance.**
- **Nothing on the Albums page breaks.**

The deciding half stays exactly as it is: `CurationVocabulary`, kept albums,
Over the Years and the featured row. What changes is what does the looking.

---

## 1. Why the NAS looks, not the phones

- **Faces need pixels.** The phones analyze the 512-pixel thumbnail, where a
  face in a group photo can be a couple dozen pixels across. Measured on the
  family library: looking at 640 pixels instead of 1,280 misses about one face
  in seven.
- **Videos need the file**, and the NAS already has every original on its own
  disks. Doing this on phones would mean downloading the library to them.
- **Apple offers apps no face identity API.** Vision in the iOS 27.2 SDK finds
  faces but can't say whose they are, and PhotoKit doesn't expose Photos'
  People.
- **One analyzer means one answer.** The NAS reads each file once, so every
  device draws the same page by construction, and the Mac and Apple TV never
  need an analyzer of their own.

## 2. Measured on the DS920+

Measured on 2026-11-05. The sample was 80 photos and 8 videos from one person's
own folders. The run used two threads at nice 10, while the stream-ladder
rebuild held about two cores at nice 17.

| Per photo, 2 threads | Time |
|---|---|
| Open and shrink to 1,280 px | 0.28 s |
| Find faces (YuNet, 1,280 px) | 0.23 s |
| Recognize faces (SFace, 0.09 s each, 2.3 per photo) | 0.21 s |
| Read the scene (SigLIP 2 B/32) | 0.69 s |
| **Total** | **about 1.4 s** |

- **A video takes about 13 s:** 12 keyframes at about 0.18 s each to decode,
  plus the per-frame work.
- **The first pass over all 69,241 files** (8,250 of them videos) takes about
  53 hours on one 2-thread lane. That's about 2.2 days, more than half of it
  videos.
- **New uploads:** 100 photos take about 2.5 minutes, and a one-minute 4K clip
  about 16 s.
- **Four threads ran slower than two** on the busy NAS. The analyzer uses two.
- **Same answer every time:** bit-for-bit identical across repeated runs and
  across 1, 2 and 4 threads, for every model.
- **Memory:** about 0.76 GB for the scene model's session (the weights plus a
  prepacked copy), and under 0.1 GB for the face models.
- **Not tried:** the J4125's graphics chip and its hardware video decoder. Both
  need root access to `/dev/dri`, and at these speeds neither is needed.

## 3. Models

| Role | Model | License | Pinned source | SHA-256 |
|---|---|---|---|---|
| Scene | SigLIP 2 base, patch 32, 256 px, vision tower | Apache 2.0 | `onnx-community/siglip2-base-patch32-256-ONNX` @ `7efccb86`, `onnx/vision_model.onnx` | `0ddb7507…cdcc9719` |
| Find faces | YuNet 2023mar | MIT | `opencv/face_detection_yunet` @ `3cc26e7f` | `8f2383e4…ed2552fa4` |
| Recognize faces | SFace 2021dec | Apache 2.0 | `opencv/face_recognition_sface` @ `3d708243` | `0ba9fbfa…87c34e79` |

The full hashes are in `Analyzer/models.json`.

- **Where the SigLIP 2 file comes from:** it's Hugging Face's own ONNX
  conversion of Google's checkpoint. It was checked against an export made
  here from Google's original weights (`google/siglip2-base-patch32-256` @
  `94dffa8c`, safetensors). On 12 synthetic inputs the worst cosine was
  1.00000000 and the worst difference 6.7e-6.
- **Integrity:** every file is checked against its SHA-256 when the image is
  built and again each time the analyzer starts. It refuses to run with
  anything else.
- **Accuracy claims:** SFace's 99.4% is on LFW, adult celebrity faces. That
  says little about young children or siblings. Those are judged on the
  family's own photos, in shadow mode.

Not used:
- **InsightFace's models:** their license is non-commercial research only.
- **Apple's MobileCLIP2 weights:** a research license.
- **OpenAI's CLIP:** SigLIP 2 is newer, Apache-licensed, and scores each label
  on its own yes/no scale. That fits how `CurationVocabulary`'s thresholds
  work.
- **The int8 versions:** they moved SigLIP's answers to a cosine of 0.74 from
  the full model's, and the int8 face models ran four to five times slower on a
  CPU without VNNI.
- **SigLIP 2 B/16:** about 3x slower here, so the first pass would take 4.6
  days. Because names attach to faces rather than to the scene model, moving to
  it later re-runs only the scene pass.

## 4. The analyzer

It has its own image (`ghcr.io/michaelromero212/framestation-analyzer`) and
its own container. It runs Python 3.12 with ONNX Runtime, OpenCV, PyAV, and
Pillow with pillow-heif. Every Python package is installed from a lock file,
checked by hash.

**Confinement:**
- **No network at all** (`network_mode: none`). It can't reach the internet,
  the LAN, the database, DSM or the server's port.
- **One way in:** a Unix socket in a Docker volume that only it and the server
  mount. The server asks "analyze this file" and the analyzer answers with
  numbers. It handles one request at a time.
- **Reads originals, never writes them.** The homes, the shared media folder
  and the blob store are each mounted read-only. A request names a path; the
  analyzer resolves it, symlinks included, and refuses anything that isn't a
  regular file under one of those roots.
- **Root, with only what it needs.** It runs as root, because DSM's home
  folders are private to each person, but with every capability dropped except
  the two that pass file permissions (`DAC_READ_SEARCH`, `DAC_OVERRIDE`). With
  every mount and the root filesystem read-only, that comes to reading. On top
  of that: `no-new-privileges`, a
  read-only root filesystem, a small tmpfs, a 2 GB memory cap, two threads,
  and nice 19, so the app, thumbnails and the stream ladder all come first.
- **Writes nothing.** Photos and frames are decoded in memory.
- **No telemetry.** ONNX Runtime ships Microsoft's telemetry, on by default:
  process, device and model details sent to
  `mobile.events.data.microsoft.com`. The analyzer switches it off before
  ONNX Runtime loads (`ORT_DISABLE_TELEMETRY`). The self-test fails if it
  keeps anything, and CI checks the container's log for it. On the NAS the
  container has no network to send on anyway. Found 2026-11-05 on the first
  deploy, from a line in the analyzer's log. The test runs before that fix, on
  the Mac and on the NAS host, had network, so they may have sent those
  details. Never photos or results: ONNX Runtime only ever sees tensors.
- **Fails closed.** If it crashes or is stopped, the server keeps serving, logs
  once that the analyzer is unreachable, and tries again with backoff.

**What it does:**
- **Photos:** decodes HEIC (iOS 18 HDR gain-map HEICs included), JPEG, PNG,
  TIFF, WebP and MPO, applies orientation, and shrinks the long side to 1,280.
  Faces: YuNet at 1,280 px, then SFace on each face, aligned to its five
  landmarks. Scene: the whole photo squashed to 256 × 256, which is how SigLIP
  was trained.
- **Videos:** keyframes only, about one every 5 seconds and at most 12 per
  clip, spread across longer clips, with the video's rotation applied. Each
  frame gets the same face and scene treatment. Decoding every frame of a 4K60
  clip runs at about 4 s per second of video on this CPU; a keyframe takes
  0.18 s.
- **What comes back, per frame:** a 768-number scene embedding. **Per face:**
  the box and five landmarks as fractions of the frame, the detector's score,
  the face's size in pixels, a sharpness measure, and a 128-number embedding.
- **Deterministic:** fixed model files, a fixed order, no randomness and a
  fixed thread count.

## 5. What the server stores

- **`nas_analysis`:** one row per person and file (`user_id`, `sha256`), like
  `media_observations`. It holds:
  - the analyzer version and model ids;
  - a status (done, failed or skipped), plus an error code that is never a path
    or anything about the contents;
  - the frame count, the scene embeddings as float32, the face count, and how
    long the analysis took.
- **`nas_faces`:** one row per face. It holds the frame, the time in the video,
  the box, landmarks, score, size and sharpness, and the embedding, sealed
  (§6).
- **`nas_observations`:** what the scenes mean, in the phones' words. It has
  the same columns as `media_observations`, so the page and search can read
  either. Derived, and made again when the concepts, the calibration or the
  vocabulary change. **`nas_calibration`:** a threshold per label, with the
  overlap it was measured on. See §7, phase 2.
- **`users.nas_analysis`:** `off`, `shadow` or `on`, off by default.
  - `shadow` analyzes and stores, and changes nothing anyone sees.
  - `on` is for when results start feeding the Albums page.
- **The server is the only writer.** It hands the analyzer one file at a time:
  new uploads first, then the library from newest to oldest. A file waits until
  its thumbnails are made, and the video half of a Live Photo is skipped like
  everywhere else. A file that fails is tried three times, six hours apart.
  A file the analyzer stops on three times in a row is set aside
  (`analyzer-stopped`), so a crash can't hold up the rest of the library.
- **Keyed by the file's hash**, which the server reads from the asset row. The
  hash survives `rebuild`, and a client never supplies one.

## 6. Face data is biometric

The rules:

1. **It never leaves the NAS.** No endpoint returns a face embedding, now or
   later. In shadow mode no endpoint returns anything about faces, beyond the
   count of people the Information panel shows (the phones send one too). When
   People ships, apps receive names, counts and which photos, never an
   embedding, and only for the person's own library.
2. **Sealed at rest.** Every embedding is encrypted with AES-GCM under a key in
   `secrets/` (root-only, like the push key) and bound to its own row. A
   database dump, or a copy of `pgdata`, doesn't carry usable face templates.
   Losing the key loses nothing that can't be recomputed: the analyzer runs
   again.
3. **Per person, per library.** Faces from a person's library are compared only
   within that library. Nothing compares faces across two people's libraries,
   and nothing answers "who is this?" about an image from outside the NAS.
4. **Never logged.** Logs carry counts, timings and a hash prefix: never a box,
   a landmark, an embedding, a name or a path.
5. **Gone when the person says so.** "Delete AI data" deletes it along with the
   device labels, and so does deleting the account. A photo deleted for good
   takes its faces with it within the hour. Turning curation off stops
   analysis.
6. **Names, in the People phase, belong to the person who gave them.** One
   person's "Mom" is someone else's "Grandma".
   - A name attaches to a face in a photo (the file and the box), not to the
     model's numbers, so a model upgrade keeps it.
   - Two people the user named are never merged automatically.
7. **Consent before analysis.** Shadow mode starts with one library, the NAS
   owner's, switched on from the command line. No one else's library is read
   until the People switch is in the apps, so each person can turn it off
   before anything of theirs is analyzed. From then on it's on by default,
   like holidays.

**What this raises.** The `/volume1/docker` share gives Everyone read access
(found 2026-10-23). `pgdata`, `.env` and `secrets/` are private, but database
dumps saved beside them are not. Sealing keeps future dumps from carrying
usable templates. Removing Everyone from that share should still happen before
faces are used for anything.

**Threat model:**
- **A photo crafted to exploit a decoder:** whatever runs, runs in the
  analyzer. That process has no network, no writable files outside a tmpfs and
  no capabilities beyond reading. The server checks the shape and size of
  every answer before storing it.
- **A family member with a DSM account:** they can't read `pgdata` or
  `secrets/`. Once the share is fixed, they can't read dumps either.
- **The server itself, compromised:** it already holds every photograph.
  Sealing protects copies of the data, not the running server.
- **Someone using the app:** no endpoint exposes faces. People endpoints, when
  they come, are scoped to the caller's own library.

## 7. Rollout

1. **Shadow (now).** The analyzer runs and the server stores; the page doesn't
   change. One library first. `FrameStationServer analysis status` shows
   progress.
2. **Scenes into albums (built).** What a scene means is put in the phones'
   own words, so every rule, search word and suggestion works unchanged.
   - **Concepts.** `Analyzer/concepts.json` holds the 224 Vision labels the
     vocabulary and search use, each as a phrase SigLIP reads after "This is
     a photo of". `Analyzer/tools/make_concepts.py` runs SigLIP 2's text side
     on them once, on a Mac, into
     `Server/Sources/FrameStationServer/Resources/scene-concepts.json`. It
     uses the same pinned conversion as the vision tower, with Google's
     original `logit_scale` and `logit_bias`, read from the checkpoint by
     byte range. Before writing, it checks that its pieces give the full
     model's logits: the worst difference was 6e-6 over 36 pairs.
   - **Scores.** For each stored scene the server computes SigLIP's own
     logit per label (`scale × cos + bias`). A video counts as showing what
     its strongest keyframe shows. The labels then go through the same
     `CurationVocabulary` rules into `nas_observations`, which has the same
     columns as the phones' `media_observations`. `people_count` is the
     faces in the frame with the most, counting only faces of at least 24 px.
   - **Calibration.** The vocabulary's thresholds were written for Vision's
     confidences, and SigLIP's are on another scale.
     - Per label, the server finds the logit at which the NAS tags as many
       photos as Vision did, on photos both a phone and the NAS analyzed. That
       logit reads as 0.3. Vision decides how many; SigLIP decides which.
     - It's held between SigLIP probabilities of 0.0005 and 0.02. A label too
       rare to measure takes 0.002.
     - Those numbers are low because SigLIP 2's are: on the dev library's 105
       photos, the best probability per photo had a median of 0.002. At 0.002,
       half the photos had a label, 1.2 on average and 7 at most.
     - Calibration runs on the NAS once 300 photos overlap, and again as the
       overlap grows by a quarter, at most every 6 hours.
   - **Judging.**
     - The Information panel shows "Seen by your NAS" under "Detected on your
       device", for the person's own analysis only. It gives labels, tags and
       a count of people, never anything about faces.
     - Curated Albums settings show the NAS's progress and a **Preview Albums
       from Your NAS** switch (`users.nas_preview`). While it's on, the Albums
       page and search are built from the NAS's analysis, on every one of the
       person's devices, and nothing is saved or renamed (`CuratedAlbums
       .persists`). Off, the page is exactly as it was.
     - Covers, highlights and featured photos keep Vision's aesthetic scores
       throughout.
   - **On.** `users.nas_analysis = 'on'` makes the NAS's analysis the page's
     source for good, saving as usual. No switch in the app sets it yet.
   - **Tests.** `Scripts/smoke-nas-scoring.sh`: 30 checks, with a stand-in
     analyzer whose scene vectors are solved to match one concept each.
     Scaling a concept's own vector instead would match dozens of others,
     because the 224 share a median cosine of 0.84.
3. **People.** This phase brings:
   - face groups per library;
   - naming on iPhone and iPad, shown everywhere;
   - an occasional "Is this Emma?";
   - titles that know who was there;
   - albums from patterns, such as two people often together.

   It arrives as a new optional section, the way Over the Years did, so older
   apps ignore it.
4. **Phones stop.** Once the NAS covers a library, the server stops handing
   that person's phones analysis work. No app update is needed.

## 8. Operating it

- **Compose:** an `analyzer` service and an `analyzer-run` volume for its
  socket. The server finds it through `FRAMESTATION_ANALYZER_SOCKET`; unset,
  analysis is off. Deploy steps are in [DEPLOY.md](DEPLOY.md).
- **Commands:**
  - `FrameStationServer analysis status`: who is enrolled, progress, and the
    analyzer's models.
  - `analysis enroll <person>`: starts shadow mode for one library.
  - `analysis remove <person>`: stops it and deletes what was stored.
  - `analysis verify <person>`: counts how many of the person's faces open
    with the key in `secrets/`, for after a restore.
- **Stopping it:** `docker compose stop analyzer`. The server waits for it.
- **A model change:** bump `ANALYZER_VERSION` in `Analyzer/analyzer/core.py`.
  The server re-analyzes older rows in the background, newest first.

## 9. Security checklist (spec §56), for this pipeline

1. **Can an original photo leave?** No. The analyzer has no network, and the
   server sends it paths, not bytes.
2. **Can a video frame leave?** No. Frames are decoded in memory inside the
   analyzer.
3. **Can OCR text leave?** There is no OCR.
4. **Can face information leave?** No endpoint returns it, it's sealed at
   rest, and it's never logged.
5. **Can GPS leave?** The analyzer never reads location. Nothing changes for
   GPS.
6. **Can embeddings leave?** No endpoint returns one.
7. **Can AI descriptions leave?** None are generated.
8. **Can AI album metadata leave?** As today: only to the person's own
   devices.
9. **Does a third-party SDK receive media?** No. ONNX Runtime, OpenCV, PyAV and
   Pillow run inside the container, offline.
10. **Does an analytics framework receive anything?** ONNX Runtime has one,
    Microsoft's telemetry, and it's switched off before it loads. The
    self-test proves it keeps nothing, and the container has no network
    besides. See §4.
11. **Does inference need the internet?** No. The container has no network.
12. **Does it work with networking disabled?** That's the only way it runs. CI
    runs its self-test with `--network none`.
13. **Are temporary files handled safely?** None are written. The root
    filesystem is read-only, with a small tmpfs.
14. **Can people disable it?** The curation switch today, the People switch in
    the People phase, and `analysis remove` during rollout.
15. **Can people delete it?** Yes: "Delete AI data", account deletion, and the
    hourly sweep after a permanent delete.
16. **Are user overrides preserved?** Shadow mode changes nothing. Later,
    names and edits always win.
17. **Are logs privacy-safe?** Yes: counts, timings and hash prefixes only.
18. **Are model downloads trusted and integrity-checked?** Yes. They're pinned
    to commits from the model authors' or Hugging Face's own repositories, and
    the SHA-256 is checked at build and at every start.
19. **Can one person's AI data leak to another?** No. Rows are keyed by person,
    and faces are never compared across libraries.
