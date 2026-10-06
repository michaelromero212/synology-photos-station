# Curated albums: investigation and plan

**Status:** in progress. The investigation below was done before any code was
written. Implementation started 2026-10-05, after the answers recorded in §8.

| Commit | What shipped |
|---|---|
| `dd31905` | Phase 1. The Albums page drops cards it can't read instead of failing. |
| `78616ea` | The NAS side of phases 2–3. `media_observations`, the curation endpoints and settings, `CurationVocabulary`, and in `CollectionsController`: event days, trip kinds and holiday evidence. |
| `55eb718` | The phone side of phase 2. The `FrameStationAnalysis` target, `CurationRunner`, the Curated Albums settings, and "Detected on your device" in the Information panel. |

**Built differently from the sketch in §6.2:**
- Observations are keyed by (person, file) alone. A newer analysis version
  replaces the row rather than sitting beside it.
- No album rows are stored yet. Detected events reuse the existing day and
  trip cards, which keeps every older app able to open them.
- Saved albums with per-photo edits are the next phase (phase 4).

The current design is in ARCHITECTURE.md, "Curated albums".

The product spec is [CURATED-ALBUMS-SPEC.md](CURATED-ALBUMS-SPEC.md), cited
here as "spec §N". This document answers its first task (spec §61) against the
actual codebase, recommends an architecture, and lays out the phases. Every
claim about the platform SDKs was checked against the installed Xcode 27.0
SDKs, not recalled.

---

## 1. The short version

- **The NAS already curates, deterministically, for every device.** Trips,
  Holidays & Occasions, On This Day, seasons and revisits are computed on the
  server from dates and coordinates. Each is keyed by `kind:key`, where the key
  is derived from the data, and iPhone, iPad, Mac and Apple TV all render the
  same `/collections` response. Curated albums should extend that system rather
  than sit beside it.
- **Recommended architecture: devices observe, the NAS decides.** iPhone, iPad
  and Mac run Apple's Vision framework on images they can already see. They send
  small observations (labels, scores, counts) to the family's own NAS. One
  resolver on the NAS turns those observations, plus dates, places and the
  person's own edits, into canonical curated albums. Apple TV only reads. This is
  spec Option D, in this project's shape. It makes "no duplicate albums" and
  "deterministic generation" (spec §16–18) true by construction, because only
  one thing ever writes an album.
- **No new sync system.** Canonical state travels on the existing `change_log`,
  delta sync and push nudges. CloudKit (Option C) is not recommended. Family
  members have separate Apple IDs, it would create a second source of truth, and
  it would put AI-derived data in a cloud.
- **Vision only, for v1.** That means scene classification, aesthetics (which
  also flags screenshots and documents) and people and animal counts. There is
  no Core ML model, no Foundation Models, no OCR, no faces and no stored
  embeddings in v1.
- **Two hazards to design around from the first day.**
  - **Old builds can break the page.** An app that receives a collection kind it
    doesn't know fails to decode the *entire* Albums page. Lenient decoding has
    to ship to every family device first.
  - **There's a cloud model in the SDK.** The iOS 27 SDK includes
    `PrivateCloudComputeLanguageModel`, which runs on Apple's servers. It must
    never be used.

---

## 2. What exists today (spec §61, "Existing Architecture")

| Question | Answer | Where |
|---|---|---|
| Architecture | Vapor + Postgres 16 in Docker on the NAS (DS920+, Celeron J4125, 8 GB). SwiftUI apps share two packages: `FrameStationAPI` holds the wire types, compiled into both server and apps, and `FrameStationKit` holds the client, stores and thumbnail loader. SQL is hand-written; there's no ORM. | ARCHITECTURE.md §2 |
| Platforms | iOS and iPadOS are full clients. macOS and tvOS are view-only. | ARCHITECTURE.md §1, `project.yml` |
| Deployment targets | iOS 17.0, macOS 14.0, tvOS 17.0, built with Xcode 27.0 against the 27 SDKs. | `project.yml` |
| NAS access | HTTPS only, through DSM's reverse proxy on a Let's Encrypt certificate; there's no plain-HTTP path on the LAN or remotely. Requests carry a bearer device token. The NAS makes `thumb-256` and `thumb-512` eagerly and `preview-2048` lazily, and serves them through the API. Uploads are chunked over a background `URLSession`. | ARCHITECTURE.md §10, `Derivatives.swift` |
| Media identity | `assets.id` (UUID) is the file. `space_assets.id` is that file's placement in one library. `assets.sha256` is computed for every file and indexed, but it isn't unique, because a shared copy is its own row. **Asset ids don't survive an index `rebuild`; SHA-256 does.** | ARCHITECTURE.md §3a and §5, migration 0014 |
| Albums | Private to one person (`albums.owner_user_id`). An album's contents are placements (`album_assets.space_asset_id`), and membership is re-checked on every read. Computed collections aren't stored at all: `GET /v1/spaces/{id}/collections` builds them on each request. The only override today is naming an occasion (`occasion_names`: per person, per library, per date, once or every year). | migrations 0010, 0011, 0017; `CollectionsController.swift` |
| Persistence | Server: Postgres. Device: SwiftData for the backup and manual-upload queues, plus timeline snapshots and an LRU image cache in Application Support. | `BackupQueue.swift`, ARCHITECTURE.md M10 |
| Sync | A per-library `change_log` with an advisory-locked sequence, `GET …/changes?since=`, APNs nudges, and offline snapshots. | ARCHITECTURE.md §5 and §6 |
| Authentication | DSM credentials are exchanged on the server for a device token, stored hashed in `devices.token_hash`. The Keychain holds only the token. Invite codes are the fallback. | ARCHITECTURE.md §2 |
| Multi-user | Yes: 3–4 people, one personal library each, plus shared libraries with roles. Holding an id is never enough to read the thing it names. Every read re-derives access from `space_members`, and non-members get a 404. | ARCHITECTURE.md §4 |

**Scale to plan for.** ARCHITECTURE.md sizes the library at about 100,000 photos
and 3,000 videos. About 67,000 files are still waiting in Synology Photos; that
migration is deferred.

**The Albums page today.** It shows a hero card (On This Day, a recent trip or
last season, for example), Recently Added, Favorites, Trips, Holidays &
Occasions, the person's own albums, Shared Albums, Places and Media Types.

---

## 3. Where the spec meets existing decisions

None of these blocks the work. They're places where the plan has to make a
choice on purpose.

1. **"The person supplies the meaning."** Migration 0017 records the current
   philosophy. The app finds the occasion and the person names it, because a
   model "would guess … and be confidently beside the point." The spec reverses
   half of that. A proposed middle path:
   - the model *proposes* ("Birthday?");
   - a confident proposal becomes the title;
   - a person's name always wins.

   `occasion_names` is already the override store for titles.
2. **Holidays come from the date alone.** `Holidays.swift` holds a fixed US list
   plus computed dates (Easter, Mother's Day, Thanksgiving and so on), and the
   bar is low: "a quiet Christmas with six photographs is still Christmas."
   Spec §6.2 and §30 ask for visual evidence and an off switch. This needs a
   decision (Q3).
3. **`CollectionKind` is a closed set.** `CollectionSummary.kind` is a
   non-optional enum. A server sending a kind an older app doesn't know fails the
   *whole* Albums page, not just one shelf; the type's own comment says so. New
   kinds can only ship after every family device runs a build that skips
   unknown kinds.
4. **Asset ids don't survive `rebuild`.** Observations keyed only by asset id
   would be lost in a rebuild, as albums are today (ARCHITECTURE.md §3a). Keying
   them by the file's SHA-256 lets a rebuild re-attach them.
5. **The deferred list.** ARCHITECTURE.md §12 defers semantic search and faces,
   with this note: "on-device Vision is cheap, CLIP embeddings on the NAS … add
   an ML runtime." This plan keeps the NAS free of an ML runtime.
6. **Overrides are per person.** Occasion names are per person even in a shared
   library ("neither should be able to rename it for the other"). Curated albums
   in shared libraries should follow the same rule unless decided otherwise (Q7).
7. **Hiding and removing are new.** No computed collection can be hidden, have
   a photo removed, or be suppressed today; the only edit is naming. Spec §2,
   §15 and §47 need all three, so curated albums need stored state where today's
   collections have none.

---

## 4. AI feasibility (spec §61, "AI Feasibility")

### Vision (tier 1)

Vision is in all three SDKs. Its Swift API needs **iOS 18, macOS 15 or
tvOS 18**, one release above the app's current minimums.

| Request | Minimum OS | Use here |
|---|---|---|
| `ClassifyImageRequest` | iOS 18 | Scene and object labels with confidences, from a fixed taxonomy of over a thousand labels (beach, cake, fireworks, stage and so on). The main semantic signal. |
| `CalculateImageAestheticsScoresRequest` | iOS 18 | `overallScore` for covers and "Best of". `isUtility` to drop screenshots, receipts and documents. |
| `DetectHumanRectanglesRequest`, `DetectFaceRectanglesRequest` | iOS 18 | A people *count* only, such as "9 people". No identity. |
| `RecognizeAnimalsRequest` | iOS 18 | Pets. |
| `GenerateImageFeaturePrintRequest` | iOS 18 | Visual similarity, for near-duplicates and splitting a day into sub-events. This is v2: a feature print is an embedding (spec §35). |
| `DetectLensSmudgeRequest` | iOS 26 | A quality signal for covers. |
| `RecognizeTextRequest`, `RecognizeDocumentsRequest` | iOS 18 / iOS 26 | OCR. **Not in v1**: it carries the spec §37 risks, and 512 px thumbnails read poorly anyway. |

The older `VN…` API reaches back to iOS 13 for classification, but aesthetics
needs iOS 18 either way. The simplest path is to run the analyzer only on iOS 18
and macOS 15 or later. Older devices still *display* curated albums (Q6).

### Core ML (tier 2)

Not needed for v1. A custom model, such as a CLIP-style image and text encoder
converted to Core ML and shipped inside the app bundle, is the route to
natural-language search and to categories the built-in classifier lacks. Defer
it until Phase 0 measurements show a real gap.

### Foundation Models (tier 3)

- **Where it runs.** `SystemLanguageModel` needs iOS 26 or macOS 26 and is
  **unavailable on tvOS**. It also needs an Apple Intelligence–eligible device
  with the feature turned on.
- **New in iOS 27.** The SDK adds image attachments
  (`Transcript.ImageAttachment`) and a `capabilities` check that can include
  `.vision`, so on some devices the on-device model may be able to look at a
  photo.
- **Not for v1.** Availability differs across the family's devices, its output
  isn't guaranteed identical across devices or OS versions (spec §18), and the
  classifier covers the MVP.
- **A plausible later use.** A "second opinion" on a few representative photos
  of a candidate event, recorded as one more observation, on eligible devices
  only.

### Never: `PrivateCloudComputeLanguageModel`

This is new in the iOS 27 SDK and runs on Apple's servers. That is remote
inference, which spec §3 and §52 rule out. A CI check should fail the build if
the symbol ever appears.

### What's achievable

- **Without training:** scenes and objects, people and animal counts, quality
  and screenshot/document filtering, holiday evidence (a tree, fireworks, a
  costume, a cake), trips (already done with coordinates), and events built from
  time, place and labels.
- **Needs a custom model or more:** fine distinctions (a wedding versus a formal
  party, a graduation versus another ceremony), natural-language search, and
  anything identity-based, which is out of scope (spec §36).

---

## 5. Cross-device architecture (spec §12 and §61)

| | A: NAS canonical | B: device AI + shared layer | C: iCloud / CloudKit | D: hybrid |
|---|---|---|---|---|
| Fits what exists | Yes. Everything people create already lives on the NAS. | Depends on the layer. | No. It would be a second source of truth. | Yes, if the shared layer is the NAS. |
| Family / multi-user | Built in: libraries, roles, 404 isolation. | Has to be rebuilt. | Separate Apple IDs; shared libraries would need CloudKit sharing. | Built in. |
| Where inference runs | The NAS can't run Vision (Linux, a J4125, no ML runtime). | Devices. | Devices. | Devices. |
| Duplicate albums | Can't happen if only the server writes. | Needs merge rules. | Needs merge rules. | Can't happen: devices only submit observations. |
| Third parties | None. | Depends. | Apple's cloud holds AI-derived data. | None. |
| Apple TV | Reads. | Reads. | Reads. | Reads. |

**Recommendation: D, as "devices observe, the NAS decides."**

```text
 iPhone / iPad                    Mac (optional)             Apple TV
 its own Photos copy,             thumb-512                  reads only
 or thumb-512                     over the LAN                   │
      │ Vision, on device              │ Vision                  │
      ▼                                ▼                         │
 observations ──────────► NAS, over TLS with the device token ◄──┘
                                       │
                          media_observations (per person)
                                       │
                          resolver: one writer, deterministic
                          dates + places + labels + the person's edits
                                       │
                          curated albums ──► change_log ──► every device
```

Why this fits the project:

- **The resolver mostly exists already.** It's `CollectionsController`'s runs,
  trips and occasions.
- **One writer means no conflicts.** Devices never create albums, so there's
  nothing to merge between them.
- **Delivery already works.** `change_log` and push nudges already deliver
  changes to every device.
- **The rules carry over.** The isolation rules apply unchanged.
- **Devices stay simple.** All a device keeps locally is a work queue and a
  cache.

---

## 6. Proposed design

### 6.1 Identity (spec §10, §16–19)

- **Media.**
  - **What the API uses:** `space_assets.id`, which is what the caller is
    allowed to see.
  - **How the server stores it:** observations are stored against the file's
    SHA-256. The server derives the hash from the asset row and never accepts
    one from the client. A rebuild re-attaches observations, and identical bytes
    are analyzed once.
  - **What clients can't do:** look observations up by hash, because that would
    be an existence oracle (ARCHITECTURE.md §4).
- **Curated album.**
  - **Key:** a deterministic key from the resolver (library + kind + date range,
    such as `event:2026-07-18..2026-07-24`). That's the same shape today's
    `kind:key` collections use.
  - **Stable id:** the album is saved with a UUID the first time it's shown or
    edited.
  - **Resolver changes:** when a later resolver version produces a different key
    for the same event, it maps to the existing album by member overlap, with a
    deterministic tie-break.
- **Versions** (spec §19): each observation records `model_version` (the Vision
  request revisions) and `analysis_version` (our pipeline). Each album records
  `generation_version` (the resolver).

### 6.2 New server data

A sketch; names are to be settled.

- **`media_observations`**
  - Columns: `user_id`, `sha256`, `analysis_version`, `model_version`,
    `labels jsonb` (the top N label/confidence pairs), `aesthetic`,
    `is_utility`, `people_count`, `animal_count`, `device_id`, `observed_at`.
  - One row per (person, file, analysis version). A second device's identical
    observation is ignored.
  - Scoped per person, so "my AI data" is exactly mine to delete (spec §25, §35).
- **`curated_albums`**
  - Columns: `id`, `user_id`, `space_id`, `key`, `kind`, `title`, `start_date`,
    `end_date`, `cover_space_asset_id`, `generation_version`, `confidence`,
    `state` (suggested | shown | hidden | deleted).
  - `deleted` keeps the row, so the resolver never recreates it (spec §47).
- **`curated_album_members`**
  - Columns: `album_id`, `space_asset_id`, `source` (ai | user), `confidence`,
    `removed_at`.
  - The resolver rewrites only `ai` rows that aren't removed. A person's removal
    (`removed_at`) and additions (`source = user`) are never touched again
    (spec §15, §46).
- **Settings:** curation on or off, holidays on or off, per person, held on the
  server so every device follows (spec §2).
- **Sync:** a new `change_log` entity, `curated_album`, and new **optional**
  fields on `CollectionsResponse`. Those are additive, so older apps are safe
  once Phase 1 has shipped.

### 6.3 Resolver (server)

A worker in the style of `DerivationWorker` and `RetentionWorker`.

- **When it runs:** it wakes on new observations or edits, debounced, and runs
  per library.
- **Deterministic:** sorted inputs, fixed thresholds, no randomness. Covers
  already use a seeded order.
- **Pipeline:**
  1. Start from the existing day runs and trips.
  2. Split days by time gaps.
  3. Score each candidate for each category: label evidence × fit of time and
     place.
  4. Turn the score into a confidence.
  5. Apply thresholds: high is shown, medium is suggested, low is dropped
     (spec §8).
  6. Apply the person's edits and deletions.
  7. Write the albums and append to `change_log`.
- **Titles come from templates** (spec §29), in this order: the person's name for
  it, then category + place, then category + date, then season. No model writes
  titles.
- **Holidays need evidence** (Q3): a date plus decorations, a tree or fireworks,
  never the date alone (spec §30).

### 6.4 Devices (spec §21–23, §32–34, §44, §50)

- **iPhone and iPad**
  - **The phone's own photos:** analyze its own copy through Photos with a
    512 px request, so nothing is downloaded. The backup engine already reads
    every asset and computes its SHA-256.
  - **Items that live only on the NAS** (shared libraries, migrated files):
    analyze `thumb-512`, and only when conditions allow. That means charging, on
    Wi-Fi, not in Low Power Mode and thermal state nominal, or inside a
    `BGProcessingTask` with `requiresExternalPower`.
  - **Priority** follows spec §50: what's being viewed, then new items, then the
    rest.
- **Mac:** an optional bulk analyzer for the backlog, reading `thumb-512` over
  the LAN. It's never required. The 256 and 512 px thumbnails together are
  about 7 GB for 103k files (ARCHITECTURE.md §3), so a full pass means
  downloading a few gigabytes once.
- **Apple TV:** reads canonical state only. Foundation Models isn't available
  there anyway.
- **The queue:** SwiftData, beside the backup queue, using spec §32's states.
- **Offline:** observations wait in the queue while offline and upload once the
  NAS answers. Album edits stay online-only in v1, like every other edit in the
  app today. That's a documented limitation against spec §44.

### 6.5 Privacy rules (spec §34–40)

- **Pixels:** the phone's own Photos copy, or NAS thumbnails the person can
  already see. They're decoded in memory and never written out, and no
  originals are downloaded for analysis.
- **What leaves a device:** observations only, sent to the family's NAS over
  the existing TLS connection with the device token. Nothing goes to any third
  party, and there are no analytics SDKs in the app.
- **Not stored in v1:** OCR text, face data, embeddings, model-written
  descriptions, and location beyond what `assets` already holds.
- **Logging:** ids, versions, durations and counts. Never labels, titles, places
  or filenames. The in-app diagnostics log is exported as Markdown and shared,
  so anything written to it leaves the house.
- **Module boundary** (spec §38): the analyzer lives in its own target with no
  dependency on the networking client, and a separate uploader moves the
  observations. CI checks for networking imports in that target and for
  `PrivateCloudComputeLanguageModel` anywhere.
- **Delete** (spec §35): removes the person's observations, curated albums and
  edits to them. It never touches media or the person's own albums.
- **Disable** (spec §2): the server-side setting turns curation off on every
  device together.

### 6.6 Conflict policy (spec §45)

- **Observations:** the first one stored for (person, file, analysis version)
  wins. Duplicates from other devices are ignored, and a newer analysis version
  replaces an older one.
- **Edits:** last write wins per (person, album, photo), using the server's
  clock. That's the same policy albums and favorites follow today, and it's safe
  because edits are online-only, so the server orders them.
- **Precedence:** a person's edit always beats the resolver. Only "Reset AI
  curation" clears the edits.

---

## 7. Phases (spec §57, adapted)

Cross-device sync isn't a phase of its own here. It comes with the server-side
design.

| Phase | Deliverable | Done when |
|---|---|---|
| **0. Decide and measure** | Answers to §8. Vision timings, memory use and label quality on 512 px images, measured on your iPhone and Mac with a throwaway harness. | The numbers are recorded here, and the v1 category list and starting thresholds are set. |
| **1. Make the page skew-proof** | Apps skip unknown collection kinds instead of failing, and the AI settings plumbing exists (switched off). | It's on every family device *before* any server sends a new kind. |
| **2. Local analysis** | Analyzer target, queue, gating, backup-time analysis, observation upload, server table and endpoints, delete and disable. No albums yet. | The dev library has observations, analysis works with networking off, and nothing but observations leaves the device. |
| **3. Event detection** | Resolver candidates with confidence, behind a per-person flag. | Candidates reviewed against your library, with low-confidence ones absent. |
| **4. Canonical state** | Saved albums, edits, deletions, reset, and version mapping. | Spec §54 scenarios A–G pass. |
| **5. UI** | The Albums page section, album actions, and Settings. | The same page on iPhone, iPad, Mac and Apple TV (spec §55). |
| **6. Video** | 3–5 representative frames per video at backup time, and the poster frame for videos that live only on the NAS. | Videos join their events. |
| **7. Memories** | Year, season, holiday and "best of" views built from canonical state. | — |

**Tests.** The resolver is tested on the server with synthetic observations,
which are JSON, not photos. Determinism, edits winning, version mixing and
isolation can all be proven without a single image. The analyzer needs real
images, and those stay out of the repo and out of CI (spec §53, Q8).

---

## 8. Open questions (yours to answer)

**Answered 2026-10-05:**
- **Q1:** personal libraries only.
- **Q2:** one system.
- **Q3:** date plus visual evidence, with an off switch.
- **Q8:** you judge detection quality on your own photos on your phone; no
  simulator testing of the AI for now.

**Defaults taken until you say otherwise:**
- **Q4:** on by default per person, with a switch.
- **Q5:** iPhone and iPad analyze; a Mac backlog analyzer comes later.
- **Q6:** the minimum OS stays the same; analysis needs iOS 18.
- **Q9:** analysis runs on whatever is in the library, independent of the
  migration.
- **Q10:** no Foundation Models in v1.

1. **Scope of v1.** Personal libraries only (recommended), or shared libraries
   too?
2. **One system or two.** Should the resolver take over Trips and Holidays &
   Occasions and add the new kinds (recommended: one page, and every card can be
   edited and hidden)? Or should a separate "Curated Memories" section sit
   beside them?
3. **Holidays.** Keep today's date-only holiday cards, or require visual
   evidence? And should there be an off switch, and is it on or off by default?
4. **Default.** On for every family member, or opt-in per person?
5. **Who analyzes.** iPhones at backup time only, or a Mac for the backlog as
   well? Is there a Mac that's usually on?
6. **OS floor.** What do the family's devices run? Raise the targets to iOS 18,
   macOS 15 and tvOS 18, or keep them and skip analysis on older devices?
7. **Edits in shared libraries.** If one person removes a photo from a curated
   album in a shared library, does it disappear for everyone or only for them?
8. **Test photos.** Will you hand-pick a set of your own photos for manual
   tuning, kept out of the repo and CI, with openly licensed images used for
   anything automated?
9. **Migration order.** Before or after the roughly 67,000-file Synology
   migration?
10. **Foundation Models.** Agree to leave it out of v1?

---

## 9. Security checklist (spec §56), for this design

| # | Question | Answer for this design | How it gets verified |
|---|---|---|---|
| 1 | Can an original leave? | No. Analysis reads the phone's own Photos copy or NAS thumbnails, and sends only observations to the NAS, which already holds the original. | Network capture during analysis shows only NAS traffic. |
| 2 | A video frame? | No. Frames are sampled in memory. | Same capture, and a code review of the frame path. |
| 3 | OCR text? | None is produced in v1. | No text-recognition requests in the analyzer target. |
| 4 | Face information? | Counts only: no landmarks, embeddings or identity. | Schema review. |
| 5 | GPS? | Observations carry none. Titles use the coarse `place_name` that already exists. | Schema review. |
| 6 | Embeddings? | None are stored in v1. | Schema review. |
| 7 | AI descriptions? | None are generated. Labels come from a fixed vocabulary and go only to the NAS. | Schema review. |
| 8 | AI album metadata? | Stays on the NAS, readable only through the API by the person it belongs to. | Isolation tests, as for albums. |
| 9 | Third-party SDK gets media? | No third-party SDKs; Apple frameworks only. | A dependency audit in review. |
| 10 | Analytics? | None in the app. | Same audit. |
| 11 | Inference needs internet? | No. Vision runs on the device with models that ship in the OS. | Airplane-mode test. |
| 12 | Works offline? | Yes. Observations queue until the NAS answers. | Airplane-mode test, then reconnect. |
| 13 | Temporary files? | None in normal use. Any needed for video frames go in the app's temp directory and are deleted. | Code review. |
| 14 | Disable AI? | A server-side setting per person, followed by every device. | Settings test across two devices. |
| 15 | Delete AI data? | One action removes observations, curated albums and edits to them. Never media or the person's own albums. | Server test: counts before and after. |
| 16 | Edits preserved? | Stored as rows the resolver reads on every run. Only Reset clears them. | Spec scenarios C, D and F. |
| 17 | Logs privacy-safe? | Ids, versions, durations and counts only. | Read a diagnostics export in review. |
| 18 | Model downloads trusted? | The app downloads none. Vision's models are part of the OS. | — |
| 19 | One person's AI data reaching another? | Observations are per person. Albums are scoped to (person, library) and re-checked on read; non-members get 404. | Isolation tests. |
| 20 | Consistent state? | One writer (the resolver), deterministic keys, and every device reads the same response. | Spec scenarios A, B and E. |

---

## 10. Risks

- **NAS load.** The resolver runs on a J4125 against up to about 100k
  observations. Saved results should make the Albums page *cheaper* than it is
  today, since collections are rebuilt on every request now, but the worker
  itself needs measuring.
- **The label vocabulary.** It may not separate the spec's finer categories,
  such as a wedding from a party. Phase 0 decides which categories v1 offers.
- **Old app builds.** The closed `CollectionKind` must be handled by Phase 1
  before anything else ships.
- **Battery and heat.** A phone working through a large backlog could run warm
  or drain fast. Gate the work, and measure it on a real device.
- **`rebuild` loses edits,** the same way it loses albums. That's the documented
  boundary of the files-are-canonical decision.

---

## 11. First steps next week

1. Answer §8. Most answers are a word or two.
2. **Phase 0.** Run Vision over a few hundred hand-picked images on the iPhone
   and the Mac. Record the time per image, memory use and the labels that come
   back, and add the results to §4.
3. **Phase 1.** Ship lenient `CollectionKind` decoding on its own. It changes
   nothing anyone can see, and it has to reach every device first.
