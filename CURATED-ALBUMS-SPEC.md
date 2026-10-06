# Local AI Curated Albums & Cross-Device Photo Intelligence

**Claude Code Implementation Specification**

> The product spec as provided in October 2026. The wording is verbatim; only
> the Markdown formatting is new (headings, and the rules, tiers and scenarios
> set out as lists). The investigation of the codebase against it, the
> recommended architecture and the plan are in
> [CURATED-ALBUMS.md](CURATED-ALBUMS.md).

## 1. Project Context

This is an existing Apple-platform photo application that connects to a user's NAS and provides a private photo/video library.

The application is intended to provide a secure, local-first alternative to traditional cloud photo organization.

The new feature described in this document will live primarily within the user's Albums experience.

The goal is to use on-device machine learning to understand photos and videos, identify meaningful events and memories throughout the year, and automatically create curated albums for the end user.

Examples:

* Beach Vacation
* Wedding
* Birthday Party
* Christmas 2026
* Thanksgiving
* New Year's Eve
* Soccer Tournament
* Graduation
* Camping Trip
* Family Gathering
* Concert
* Road Trip
* Weekend in New York
* Summer 2026
* Best of 2026
* Memories from July
* Holiday Season 2026

The feature should feel like an intelligent personal photo organizer, while maintaining a strict privacy-first architecture.

## 2. Primary Product Goal

The application should move beyond simply displaying folders from a NAS.

Instead, the Albums page should be able to contain:

1. User-created albums
2. NAS/folder-based albums where applicable
3. AI-curated albums
4. Automatically detected events
5. Seasonal or holiday collections
6. Yearly/monthly memory collections

The AI-curated albums should be treated as suggestions generated from the user's media, not as authoritative truth.

The user should always be able to:

* Open an AI-curated album
* Remove media
* Add media
* Rename an album
* Hide an album
* Delete an AI-generated album
* Disable AI curation
* Delete AI-generated metadata

## 3. CRITICAL PRIVACY PRINCIPLE

The application is a private photo library first and an AI application second.

User media is highly sensitive.

The AI system must be designed so that:

The user's photos and videos do not need to leave the user's trusted device environment in order to be analyzed.

Do not introduce cloud AI processing merely because it is easier or more accurate.

The initial implementation must NOT send user media or AI-derived personal information to:

* OpenAI
* Anthropic
* Google
* Microsoft
* third-party AI APIs
* remote inference services
* third-party vector databases
* developer-controlled servers
* analytics providers

unless a separate future feature explicitly introduces optional cloud processing with clear user consent.

## 4. ON-DEVICE AI

Investigate and use Apple's native on-device capabilities where appropriate.

Evaluate:

* Vision
* Core ML
* Create ML-compatible models
* Apple's on-device Foundation Models capabilities where appropriate and available
* CPU
* GPU
* Neural Engine

The system should operate without internet access once required local models/resources are available.

The AI subsystem should not require a network connection for inference.

If a desired capability cannot currently be implemented reliably on-device, document the limitation instead of silently introducing a cloud dependency.

## 5. PRODUCT EXPERIENCE

The primary user-facing destination is:

```text
Albums
```

Conceptually:

```text
Albums
────────────────────────────

Curated Memories

🏖 Beach Vacation
   July 2026
   243 photos · 18 videos

💍 Wedding
   April 2026
   293 photos · 27 videos

🎂 Birthday
   May 2026
   124 photos · 12 videos

⚽ Soccer Tournament
   June 2026
   76 photos · 8 videos

🎄 Christmas 2026
   December 2026
   184 photos · 21 videos

────────────────────────────

My Albums

Favorites
Family
Trips
Work
...
```

The exact UI should follow the existing application's design language.

Do not create a completely separate visual system unless necessary.

## 6. CURATED ALBUM TYPES

The architecture should support several classes of AI-generated collections.

### 6.1 Event Albums

Examples:

```text
Wedding
Birthday Party
Soccer Game
Concert
Graduation
Camping Trip
Beach Vacation
Road Trip
Family Gathering
```

### 6.2 Holiday Albums

The system may identify culturally/common calendar-based occasions where appropriate.

Examples:

```text
Christmas
Thanksgiving
Halloween
New Year's Eve
Easter
Fourth of July
Valentine's Day
```

Do not assume that every user celebrates every holiday.

Holiday detection should primarily be based on dates plus visual/contextual evidence and should avoid making sensitive assumptions about the user's religion, ethnicity, or identity.

Users should be able to disable holiday-based curation.

### 6.3 Seasonal Albums

Examples:

```text
Spring 2026
Summer 2026
Fall 2026
Winter 2026
```

### 6.4 Time-Based Memory Albums

Examples:

```text
Best of January
Summer 2026
2026 Highlights
Weekend Memories
```

### 6.5 Location/Trip Albums

If appropriate local metadata exists:

```text
Maui Vacation
New York Trip
Washington DC Weekend
```

Do not expose or persist precise GPS information unnecessarily.

Prefer coarse location concepts when possible.

## 7. IMPORTANT: CURATION VS CLASSIFICATION

Do not build the system as a single fixed classifier.

Instead, use multiple layers:

```text
Media
  ↓
Media Metadata
  ↓
Local Visual Analysis
  ↓
Semantic Analysis
  ↓
Event Detection
  ↓
Event Clustering
  ↓
Curated Album Candidate
  ↓
Confidence / Quality Evaluation
  ↓
Albums Page
```

For example:

```text
Photo observations:

- 9 people
- cake
- candles
- balloons
- indoor
- celebration

Semantic interpretation:

Birthday Party

Related photos:

Same date
Same location
Similar visual content
Nearby videos

Result:

Birthday Party
124 photos
12 videos
```

## 8. ALBUM CONFIDENCE

AI-generated albums must have an internal confidence/quality score.

For example:

```json
{
  "albumType": "birthday",
  "confidence": 0.91
}
```

Do not necessarily expose numerical confidence to users.

Instead use internal thresholds such as:

```text
High confidence
→ Automatically surface

Medium confidence
→ Consider surfacing as a suggestion

Low confidence
→ Do not automatically create
```

The exact thresholds should be determined experimentally.

Avoid creating dozens of low-quality albums.

Album quality is more important than album quantity.

## 9. EVENT CLUSTERING

Individual image classification is not enough.

The system should group related media into events.

Potential signals:

* Timestamp
* Time proximity
* Location similarity
* Visual similarity
* Semantic tags
* Detected activities
* Detected objects
* Existing folder/album information
* User-created album information
* Video content
* Local OCR where useful

Example:

```text
IMG_1001
IMG_1002
IMG_1003
...
IMG_1240
```

may become:

```text
Maui Beach Vacation
July 18–24, 2026
243 photos
18 videos
```

The event clustering system must be modular.

Do not hard-code event rules into the image classifier.

## 10. MEDIA IDENTITY

Cross-device consistency requires a stable identity for each media item.

Do NOT use a device-local array index as a media identifier.

Do NOT assume:

```text
IMG_1234.JPG
```

is globally unique.

Design or inspect the existing NAS media identity system.

A media record should have a stable identifier that can survive:

* iPhone access
* iPad access
* Mac access
* Apple TV access
* NAS rescans
* file renaming where possible
* metadata refreshes

A potential conceptual model:

```swift
MediaID
```

could be based on a stable NAS/file identity or a deterministic content identity.

The exact implementation must account for performance and privacy.

Do not calculate expensive full-file hashes for an entire library without considering performance.

## 11. CROSS-DEVICE REQUIREMENT

The curated Albums page must remain consistent across the user's:

* iPhone
* iPad
* Mac
* Apple TV

The user should not experience:

```text
iPhone:
Beach Vacation
Wedding
Birthday

iPad:
Wedding
Birthday

Mac:
Beach Vacation
Different Birthday album
```

unless the devices genuinely have different access to the underlying media.

The product should strive for:

One logical photo library and one logical set of curated albums per user.

## 12. IMPORTANT ARCHITECTURAL QUESTION

Before implementation, investigate where the source of truth for AI-generated album state should live.

The application currently has a NAS as the media source.

Do NOT automatically assume the NAS should become the source of truth for all AI metadata.

Evaluate at least these architectures:

### Option A — NAS as canonical metadata store

```text
iPhone
   │
iPad ──────► NAS Metadata Store
   │
Mac
   │
Apple TV
```

Advantages:

* Centralized
* Consistent
* No dependence on Apple's cloud
* Works across Apple devices
* Fits the existing NAS architecture

Questions:

* Does the NAS support safe concurrent writes?
* How should multiple devices synchronize?
* How should authentication work?
* How should metadata conflicts be resolved?
* How should database migrations work?

### Option B — Device-local AI + shared synchronization layer

```text
iPhone ──┐
iPad ────┼──► Shared Album Metadata
Mac ─────┤
Apple TV ┘
```

The AI inference may happen on each device, while a shared metadata layer synchronizes the resulting album state.

### Option C — Apple ecosystem synchronization

Investigate whether appropriate Apple-native synchronization technologies can be used without transferring sensitive media to a third-party AI service.

Potential technologies to evaluate include:

* CloudKit
* iCloud-based application data
* NSPersistentCloudKitContainer
* other Apple-supported synchronization mechanisms

However:

Do not assume iCloud is automatically appropriate.

The privacy model must be explicitly evaluated.

The fact that data is synchronized through an Apple service does not mean the application should automatically synchronize all AI-derived information.

### Option D — Hybrid

Potential architecture:

```text
                 NAS
                  │
            Media Source
                  │
        ┌─────────┴─────────┐
        │                   │
      iPhone              Mac
        │                   │
    Local AI            Local AI
        │                   │
        └─────────┬─────────┘
                  │
           Shared Metadata
                  │
          ┌───────┼───────┐
          │       │       │
        iPad   Apple TV  Mac
```

Evaluate whether a hybrid architecture provides the best balance.

## 13. RECOMMENDED PRINCIPLE FOR CROSS-DEVICE CONSISTENCY

The system should distinguish between:

**Media**

The actual photo/video.

**Analysis**

What a particular device's local AI inferred.

**Canonical Album State**

The user's actual album organization.

These should NOT be treated as the same thing.

For example:

```text
Media
─────
IMG_1234

Local Analysis
──────────────
Beach
Ocean
People
Vacation
Confidence 0.91

Canonical Album
───────────────
Maui Beach Vacation

Membership
──────────
IMG_1234 ∈ Maui Beach Vacation
```

This distinction is critical.

A device can perform local inference without automatically changing the user's canonical album state.

## 14. ALBUM STATE MODEL

Design a canonical album model.

Conceptually:

```swift
CuratedAlbum {
    id
    ownerID
    title
    type
    createdAt
    updatedAt
    startDate
    endDate
    coverMediaID
    generationVersion
    state
}
```

Album membership:

```swift
AlbumMembership {
    albumID
    mediaID
    source
    confidence
    addedAt
    removedAt
}
```

Potential `source` values:

```text
ai
user
imported
system
```

This allows the application to distinguish:

AI suggested this photo

from:

User intentionally added this photo.

## 15. USER OVERRIDES MUST WIN

This is extremely important.

Suppose AI decides:

```text
IMG_1234 → Wedding
```

but the user removes it.

The next AI scan must NOT simply add it back.

Persist an explicit user override:

```text
mediaID
albumID
userOverride = removed
```

Likewise:

If the user manually adds a photo to an AI-curated album, the system should preserve that decision.

Conceptually:

```text
AI suggestion
      ↓
User decision
      ↓
Canonical album membership
```

The canonical state should take precedence over future AI inference unless the user explicitly resets AI curation.

## 16. CONFLICT RESOLUTION

Multiple devices may perform AI analysis simultaneously.

Example:

```text
iPhone:
Birthday Party confidence 0.87

Mac:
Birthday Party confidence 0.93
```

Do not allow this to create duplicate albums.

Instead, use a stable album identity and merge observations.

Possible rule:

```text
Same logical event
+
Same time window
+
Similar media
+
Similar semantic category
=
Same album candidate
```

The exact algorithm should be designed and tested.

## 17. AI ANALYSIS VS CANONICAL ALBUM GENERATION

A critical architecture decision:

Do not let every device independently create its own albums.

Bad:

```text
iPhone:
Create Birthday Album A

iPad:
Create Birthday Album B

Mac:
Create Birthday Album C
```

Instead:

```text
Local AI Analysis
       ↓
Analysis Observation
       ↓
Shared / Canonical Event Resolver
       ↓
Canonical Album
```

If analysis occurs on multiple devices, the results should feed a common deterministic resolution process.

## 18. DETERMINISTIC ALBUM GENERATION

Whenever possible, album generation should be deterministic.

Given the same:

* media set
* timestamps
* metadata
* AI observations
* model versions
* user overrides

the application should produce the same logical album.

This reduces cross-device inconsistency.

Avoid algorithms that depend on random model output unless randomness is controlled.

## 19. MODEL VERSIONING ACROSS DEVICES

Different Apple devices may have different hardware and potentially different available ML capabilities.

For example:

```text
iPhone:
Model v2

iPad:
Model v2

Mac:
Model v2

Older device:
Model v1
```

Do not let different model versions create contradictory album identities.

Persist:

```text
modelVersion
analysisVersion
albumGenerationVersion
```

The canonical album resolver should be capable of handling observations from different model versions.

## 20. LOCAL AI RESULTS ARE OBSERVATIONS

Treat AI output as an observation rather than absolute truth.

Conceptual model:

```swift
AnalysisObservation {
    mediaID
    deviceID
    modelVersion
    observedAt
    categories
    objects
    activities
    confidence
}
```

Then:

```text
Multiple observations
        ↓
Canonical resolver
        ↓
Album decision
```

This architecture makes the system much easier to evolve.

## 21. APPLE TV

Apple TV is primarily a consumption/display device.

Do not assume Apple TV should perform the same AI workload as an iPhone or Mac.

Prefer:

```text
Apple TV
   ↓
Read canonical album state
   ↓
Display curated albums
```

rather than:

```text
Apple TV
   ↓
Download hundreds of photos
   ↓
Run ML
   ↓
Create albums
```

unless future testing demonstrates a strong reason to do so.

The Apple TV should ideally consume the canonical album metadata and media references.

## 22. MAC

The Mac can potentially act as a high-capability local analysis device.

Because Macs may have:

* More RAM
* More storage
* More sustained compute
* Apple Silicon Neural Engine/GPU
* Better background-processing opportunities

the Mac could optionally process larger portions of the library.

However:

Do not make the Mac mandatory.

The application should remain functional when the user only has an iPhone/iPad.

## 23. IPHONE / IPAD

iPhone and iPad should be capable of:

* On-demand analysis
* Foreground analysis
* Queued analysis
* Opportunistic background analysis where platform rules allow
* Local semantic understanding

Prioritize media currently being viewed.

Then process remaining media opportunistically.

Consider:

* battery level
* Low Power Mode
* thermal state
* charging
* Wi-Fi
* foreground/background state

## 24. DEVICE IDENTITY

If the synchronization architecture needs device identity, do not use personally identifying device information unnecessarily.

Use an application-generated local device identifier.

Do not expose device identifiers to users.

Do not use serial numbers or other hardware identifiers as application identity.

## 25. USER IDENTITY

The canonical album state must be associated with the correct end user.

Investigate the existing application's authentication model.

Determine:

* How users authenticate to the NAS
* Whether multiple users can use the same NAS
* Whether each user has a separate library
* Whether family/shared libraries exist
* How permissions are enforced

Never allow AI-generated album metadata from one user to leak into another user's Albums page.

Example:

```text
User A
  ↓
Library A
  ↓
AI metadata A
  ↓
Albums A

User B
  ↓
Library B
  ↓
AI metadata B
  ↓
Albums B
```

## 26. MULTI-USER / SHARED NAS CONSIDERATIONS

If multiple users can access the same NAS:

Do not assume:

```text
NAS = one user
```

The architecture must account for separate ownership.

Every canonical album should have an ownership scope.

Conceptually:

```text
ownerID
libraryID
albumID
```

The exact identifiers should follow the existing application's authentication/data model.

## 27. MEDIA SYNCHRONIZATION

Do not assume all devices have the same local media cache.

For example:

```text
iPhone:
Original available on NAS

iPad:
Thumbnail only

Apple TV:
Streaming access

Mac:
Original locally cached
```

The canonical album should reference the media by stable identity, not by a device-local file path.

Bad:

```text
/Users/Michael/Pictures/IMG_1234.JPG
```

Good:

```text
mediaID = stable-library-identifier
```

Each device resolves that identity through the application's media provider.

## 28. ALBUM COVER SELECTION

Album covers should also be deterministic.

Potential criteria:

* Representative image
* High image quality
* Strong semantic relevance
* Face composition where appropriate
* Avoid blurry frames
* Avoid duplicate images
* User-selected cover should override AI selection

Persist the selected cover by stable `mediaID`.

## 29. ALBUM TITLES

AI may generate titles, but titles should be normalized.

For example:

Bad:

```text
A Wonderful Day at the Beach With Friends and Family
```

Better:

```text
Beach Vacation
```

Potential title sources:

1. User-defined title
2. Existing folder/album title
3. Strong event category
4. Location + event
5. Date/season
6. Generic fallback

The user should always be able to rename the album.

## 30. HOLIDAY DETECTION

Holiday albums should not rely only on visual recognition.

Use a combination of:

```text
Date
+
Calendar context
+
Visual evidence
+
Existing album/folder context
```

For example:

```text
December 25
+
Christmas decorations
+
Christmas tree
+
gift opening
=
Christmas album candidate
```

But:

```text
December 25
```

alone should not necessarily cause an album to be created.

Do not infer sensitive personal attributes from holiday participation.

## 31. YEARLY MEMORY EXPERIENCE

The system should eventually support an annual memory view.

Example:

```text
2026 Memories

January
────────
Winter Weekend

March
─────
Camping Trip

April
─────
Wedding

May
───
Birthday

June
────
Soccer Tournament

July
────
Maui Vacation

December
────────
Christmas
```

This should be generated from canonical event/album state.

It should not independently re-run completely different logic on every device.

## 32. AI PROCESSING QUEUE

Implement a local analysis queue.

Potential states:

```text
notAnalyzed
queued
processing
completed
failed
skipped
```

Support:

* Pause
* Resume
* Retry
* Cancel
* Priority
* Progress

Prioritize media the user is actively viewing.

## 33. VIDEO ANALYSIS

Do not analyze every frame.

Use representative sampling.

Conceptually:

```text
Video
  ↓
Duration analysis
  ↓
Representative frame selection
  ↓
Local vision analysis
  ↓
Observation aggregation
  ↓
Semantic classification
```

Consider:

* Scene changes
* Frame similarity
* Video duration
* Resolution
* Device performance
* Battery
* Thermal state

## 34. STORAGE

Avoid permanently duplicating NAS media on the device solely for AI processing.

Preferred pipeline:

```text
NAS media
   ↓
Temporary local processing
   ↓
AI analysis
   ↓
Derived metadata
   ↓
Temporary media released
```

Persist only what is needed.

AI metadata itself should be stored securely.

## 35. DELETE AI DATA

Provide a user-accessible way to delete generated AI metadata.

This should remove:

* AI tags
* AI descriptions
* AI classifications
* AI observations
* AI embeddings
* AI-generated album candidates
* AI-generated albums, if the user chooses

It must NOT delete original NAS media.

If canonical albums contain user-added content, do not silently delete user-created organization.

Clearly distinguish:

```text
AI-generated organization
```

from:

```text
User-created organization
```

## 36. FACE ANALYSIS

Do not implement identity recognition in the first version.

Basic people detection may be used when useful for semantic understanding.

Do not attempt to identify:

```text
"This is Michael."
```

or:

```text
"This is Sarah."
```

without a separate explicit product/security design.

Face embeddings must be treated as highly sensitive data.

## 37. OCR

OCR can provide useful contextual information.

Example:

```text
"Maui 2026"
```

could help identify a trip.

However, OCR can reveal:

* names
* addresses
* phone numbers
* emails
* financial information
* private messages
* documents

Therefore:

* Keep OCR local
* Do not transmit OCR results
* Avoid persisting raw OCR unnecessarily
* Do not log OCR text
* Consider filtering sensitive OCR categories

## 38. NETWORK SECURITY

Do not weaken the existing NAS security architecture.

Maintain:

* TLS where applicable
* certificate validation
* authentication
* Keychain credential storage
* secure session handling
* appropriate access control

The local AI pipeline should not have arbitrary networking access.

Conceptually:

```text
NAS Network Layer
        ↓
Media Provider
        ↓
Local AI Pipeline
        ↓
Local Metadata
```

AI inference should not call the network layer.

## 39. LOGGING

Never log:

* photo contents
* video contents
* OCR text
* GPS coordinates
* face information
* AI descriptions
* personal names
* private filenames
* sensitive album titles

Prefer:

```text
Media analysis completed
mediaID: internal identifier
modelVersion: 1.0
duration: 183ms
```

Use privacy-preserving logging.

## 40. SECURITY TESTING

Test the AI subsystem with networking disabled.

Verify:

* Photo analysis works
* Video analysis works
* No external AI endpoint is contacted
* No media is uploaded
* No derived data is uploaded
* No unexpected analytics data is generated

Inspect all new dependencies and SDKs.

Do not add a dependency without understanding its network behavior.

## 41. DATA MODEL

Create a clean separation between:

Media

```swift
MediaItem
```

Local AI Observation

```swift
AnalysisObservation
```

Canonical Album

```swift
CuratedAlbum
```

Album Membership

```swift
AlbumMembership
```

User Override

```swift
AlbumMembershipOverride
```

Processing State

```swift
AnalysisTask
```

Adapt names to the existing application architecture.

## 42. POSSIBLE DATA MODEL

Conceptually:

```swift
struct AnalysisObservation {
    let mediaID: MediaID
    let deviceID: DeviceID
    let modelVersion: String
    let analysisVersion: String
    let observedAt: Date

    let categories: [SemanticCategory]
    let objects: [DetectedObject]
    let activities: [DetectedActivity]

    let confidence: Double
}
```

```swift
struct CuratedAlbum {
    let id: AlbumID
    let ownerID: OwnerID
    let libraryID: LibraryID

    let title: String
    let type: AlbumType

    let createdAt: Date
    let updatedAt: Date

    let startDate: Date?
    let endDate: Date?

    let coverMediaID: MediaID?

    let generationVersion: String
}
```

```swift
struct AlbumMembership {
    let albumID: AlbumID
    let mediaID: MediaID

    let source: MembershipSource
    let confidence: Double?

    let createdAt: Date
}
```

Do not blindly implement these structures. Adapt them to the application's current persistence and synchronization architecture.

## 43. SYNCHRONIZATION RULES

The following principles should guide synchronization:

* **Rule 1** — Media identity must be stable.
* **Rule 2** — Album identity must be stable.
* **Rule 3** — User edits must override AI suggestions.
* **Rule 4** — AI observations may be device-specific.
* **Rule 5** — Canonical album membership should be shared.
* **Rule 6** — Different model versions must not create duplicate logical albums.
* **Rule 7** — Apple TV should primarily consume canonical album state.
* **Rule 8** — Devices should not independently create conflicting album records.
* **Rule 9** — Sync must be resilient to offline operation.
* **Rule 10** — Conflict resolution must be deterministic.

## 44. OFFLINE-FIRST BEHAVIOR

The user may be offline.

The application should continue to work with whatever local state is available.

Example:

```text
iPhone offline
    ↓
Local AI analysis
    ↓
Local album changes
    ↓
Pending synchronization
    ↓
Network restored
    ↓
Synchronize canonical state
```

Do not discard local work simply because the NAS or synchronization service is temporarily unavailable.

Use a pending-operation model if necessary.

## 45. SYNCHRONIZATION CONFLICT EXAMPLE

Suppose:

```text
iPhone:
Adds IMG_1234 to Beach Vacation

Mac:
Removes IMG_1234 from Beach Vacation
```

The system must have an explicit conflict policy.

Possible approaches:

* Last-write-wins with timestamps
* Versioned changes
* User override priority
* Operation log
* CRDT-like approach

Investigate which approach best fits the existing architecture.

Do not silently choose a simplistic conflict strategy without documenting it.

## 46. USER OVERRIDE CONFLICT RULE

User actions should carry stronger authority than AI observations.

Example:

```text
AI:
IMG_1234 belongs in Wedding

User:
Remove IMG_1234
```

Result:

```text
Canonical membership:
REMOVED
```

Later:

```text
AI:
IMG_1234 belongs in Wedding
```

The system must recognize the existing user override.

## 47. ALBUM DELETION

If a user deletes an AI-curated album:

Do not immediately recreate it on the next scan.

Persist a user-level suppression/override.

Example:

```text
albumCandidateID
suppressedByUser = true
```

Allow the user to reset AI curation if desired.

## 48. DEVICE CAPABILITY DIFFERENCES

Different devices may have different capabilities.

The architecture must not assume:

```text
Every Apple device = same ML capabilities
```

Create a capability abstraction where appropriate.

For example:

```swift
DeviceMLCapabilities {
    supportsVision
    supportsFoundationModel
    supportsRequiredCoreMLModel
    availableMemory
    hardwareGeneration
}
```

Do not expose unnecessary hardware details to the user.

## 49. PERFORMANCE

AI processing should not destroy the normal photo browsing experience.

Consider:

* memory pressure
* CPU/GPU usage
* Neural Engine availability
* battery
* thermal state
* network
* NAS bandwidth
* disk space

Never download the entire NAS library simply because AI analysis was enabled.

Process incrementally.

## 50. PRIORITIZATION

A good priority model might be:

```text
1. Currently viewed media
2. Newly imported media
3. Media in recently viewed albums
4. Media likely to belong to active event
5. Remaining library
```

Background analysis should be opportunistic.

## 51. MODEL STRATEGY

Do not immediately introduce a large third-party model.

First evaluate:

* **Tier 1** — Vision framework.
* **Tier 2** — Core ML.
* **Tier 3** — Apple on-device Foundation Models capabilities.
* **Tier 4** — Custom packaged local model.

Only move to a more complex approach when there is a demonstrated capability gap.

Document:

* model size
* RAM requirements
* supported devices
* inference time
* battery impact
* thermal impact
* model version
* accuracy limitations

## 52. DO NOT MAKE CLOUD AI A FALLBACK

This is important.

Do not implement:

```text
Local AI failed
     ↓
Send photo to cloud AI
```

without an explicit future user opt-in feature.

Instead:

```text
Local AI failed
     ↓
Retry / skip / mark uncertain
```

The default product must remain privacy-preserving.

## 53. TEST DATA

Create a representative test dataset containing examples of:

* beach vacations
* weddings
* birthdays
* sports
* concerts
* graduations
* camping
* family gatherings
* holidays
* food
* pets
* ordinary daily life
* ambiguous images
* screenshots
* documents
* memes
* low-light photos
* blurry photos
* videos

Do not use real user media in automated tests unless the user has explicitly provided it for testing.

Prefer synthetic or properly controlled test assets.

## 54. TESTING CROSS-DEVICE CONSISTENCY

Create scenarios such as:

* **Scenario A** — iPhone analyzes a photo. Mac opens Albums. Expected: same canonical album appears.
* **Scenario B** — Mac analyzes an entire event. iPhone opens Albums. Expected: same event appears once.
* **Scenario C** — iPhone removes a photo from an AI album. Mac opens the album. Expected: photo remains removed.
* **Scenario D** — Mac adds a photo manually. iPhone opens the album. Expected: photo remains present.
* **Scenario E** — Two devices analyze the same event. Expected: one logical album, not two.
* **Scenario F** — User deletes an AI-generated album. Another device performs a scan. Expected: deleted album does not immediately reappear.
* **Scenario G** — One device is offline. Expected: local changes remain pending and synchronize when connectivity returns.

## 55. APPLE TV TESTING

Verify that Apple TV:

* displays canonical albums
* uses stable album IDs
* resolves media through stable media IDs
* does not create duplicate albums
* does not need to perform AI inference
* respects user deletions
* respects album membership changes
* handles albums created by iPhone/iPad/Mac

## 56. SECURITY REVIEW CHECKLIST

Before declaring this feature complete, answer:

1. Can an original photo leave the trusted local environment?
2. Can a video frame leave?
3. Can OCR text leave?
4. Can face information leave?
5. Can GPS information leave?
6. Can embeddings leave?
7. Can AI descriptions leave?
8. Can AI album metadata leave?
9. Does any third-party SDK receive media?
10. Does any analytics framework receive sensitive AI metadata?
11. Does AI inference require internet access?
12. Can analysis operate with networking disabled?
13. Are temporary files handled safely?
14. Can users disable AI?
15. Can users delete AI-generated data?
16. Are user overrides preserved?
17. Are logs privacy-safe?
18. Are model downloads trusted and integrity-checked?
19. Can one user's AI metadata leak to another user?
20. Can devices reach a consistent canonical album state?

Document the answers.

## 57. IMPLEMENTATION PHASES

Do not attempt to build the entire system at once.

### Phase 1 — Architecture

Inspect the existing application.

Determine:

* current architecture
* media identity
* NAS architecture
* persistence
* authentication
* sync capabilities
* iOS/macOS/tvOS targets
* current Albums implementation

Then propose the architecture.

### Phase 2 — Local Photo Analysis

Implement:

* local Vision analysis
* semantic observations
* local persistence
* privacy-safe logging
* analysis queue
* user enable/disable

No automatic album creation yet.

### Phase 3 — Event Detection

Implement:

* event clustering
* semantic event categories
* confidence scoring
* candidate albums

### Phase 4 — Canonical Album State

Implement:

* stable album IDs
* stable media IDs
* membership records
* user overrides
* album suppression
* deterministic album generation

### Phase 5 — Cross-Device Synchronization

Implement the chosen synchronization architecture.

Ensure:

* iPhone
* iPad
* Mac
* Apple TV

can resolve the same canonical album state.

### Phase 6 — Curated Albums UI

Add AI-generated albums to the existing Albums experience.

Clearly distinguish AI-curated albums from user-created albums where appropriate.

### Phase 7 — Video Understanding

Add representative-frame video analysis.

### Phase 8 — Memory Experience

Add:

* yearly memories
* seasonal memories
* holiday collections
* trip/event collections
* highlights

## 58. DO NOT OVERENGINEER THE FIRST VERSION

The first usable version should be relatively small.

A good MVP is:

```text
NAS media
   ↓
Local Vision analysis
   ↓
Semantic observations
   ↓
Event clustering
   ↓
Curated album candidate
   ↓
Canonical album
   ↓
Albums page
```

with:

* no cloud AI
* no face recognition
* no complex personalization
* no massive model
* no unnecessary media duplication
* no device-specific album creation

## 59. ARCHITECTURAL SEPARATION

Keep these responsibilities separate:

```text
MediaProvider
     ↓
MediaPreprocessor
     ↓
VisionAnalyzer
     ↓
SemanticAnalyzer
     ↓
EventClusterer
     ↓
AlbumCandidateGenerator
     ↓
CanonicalAlbumResolver
     ↓
AlbumRepository
     ↓
Albums UI
```

Synchronization should be a separate concern:

```text
CanonicalAlbumResolver
        ↓
SyncEngine
        ↓
Shared Metadata Store
```

The exact implementation should follow the existing project's architecture.

## 60. PROPOSED PROTOCOLS

These are conceptual examples only.

```swift
protocol MediaAnalyzer {
    func analyzePhoto(_ media: MediaItem) async throws -> MediaAnalysis
    func analyzeVideo(_ media: MediaItem) async throws -> MediaAnalysis
}
```

```swift
protocol SemanticAnalyzer {
    func classify(
        observations: [VisionObservation]
    ) async throws -> SemanticClassification
}
```

```swift
protocol EventClusterer {
    func cluster(
        analyses: [MediaAnalysis]
    ) async throws -> [MediaEvent]
}
```

```swift
protocol AlbumResolver {
    func resolve(
        events: [MediaEvent],
        existingAlbums: [CuratedAlbum],
        userOverrides: [AlbumMembershipOverride]
    ) async throws -> [CuratedAlbumChange]
}
```

```swift
protocol AlbumSyncEngine {
    func pushPendingChanges() async throws
    func pullRemoteChanges() async throws
    func resolveConflicts() async throws
}
```

Adapt these to the real codebase.

## 61. FIRST TASK FOR CLAUDE CODE

Before modifying the project, inspect the repository and answer:

### Existing Architecture

* What is the current app architecture?
* What platforms are currently supported?
* What are the deployment targets?
* How is NAS access implemented?
* How are media IDs represented?
* How are albums represented?
* How is data persisted?
* Is there already synchronization?
* Is there authentication?
* Is the app multi-user?

### AI Feasibility

* Which Vision APIs are available?
* Which Core ML capabilities are appropriate?
* Is Apple's on-device Foundation Models framework available for the deployment targets?
* What capabilities can be achieved without custom model training?
* What capabilities require a custom model?

### Cross-Device Architecture

Compare:

1. NAS canonical metadata
2. Apple/iCloud synchronization
3. Hybrid synchronization
4. Device-local analysis with shared canonical metadata

Then recommend an architecture based on the actual project.

Do not start implementation until this investigation is complete.

## 62. FINAL DELIVERABLE

After implementation, provide:

### Architecture Summary

Explain the complete data flow.

### Privacy Summary

Explicitly state:

* what remains local
* what is synchronized
* whether any media leaves the device
* whether any AI-derived information leaves the device
* what third-party services are involved

### Cross-Device Behavior

Explain how the same user sees consistent Albums on:

* iPhone
* iPad
* Mac
* Apple TV

### AI Pipeline

Explain:

```text
Media
→ Vision
→ Semantic Analysis
→ Event Detection
→ Album Resolution
```

### Synchronization

Explain:

* canonical state
* local observations
* conflict resolution
* user overrides
* offline behavior

### Files Changed

List important files.

### Testing

List privacy, AI, synchronization, and cross-device tests.

### Limitations

Be honest about current limitations.

### Future Improvements

Potential future capabilities:

* better semantic models
* personalized categories
* improved event clustering
* video understanding
* local natural-language search
* yearly memory generation
* user corrections
* smarter album covers
* richer local semantic indexing

## 63. NON-NEGOTIABLE PRODUCT PRINCIPLES

1. Privacy comes before AI capability.
2. Original media must not be sent to cloud AI by default.
3. AI inference should happen locally.
4. AI observations are not authoritative truth.
5. User decisions override AI decisions.
6. Canonical album state must be separate from local AI observations.
7. Every media item needs a stable identity.
8. Every curated album needs a stable identity.
9. Devices must not independently create duplicate logical albums.
10. Offline operation should be supported wherever practical.
11. Apple TV should primarily consume canonical state rather than perform heavy AI processing.
12. The Mac may perform heavier local processing but must not become mandatory.
13. AI-generated data must be deletable.
14. AI curation must be disableable.
15. Different model versions must not break album consistency.
16. One user's album metadata must never leak into another user's library.
17. Do not introduce cloud AI as a silent fallback.
18. Do not trade user privacy for slightly better classification accuracy.

## The desired end state

```text
                 USER'S MEDIA
                      │
                      ▼
             ┌─────────────────┐
             │       NAS       │
             │ Source of Truth │
             │    for Media    │
             └────────┬────────┘
                      │
          ┌───────────┼────────────┐
          │           │            │
       iPhone       iPad          Mac
          │           │            │
          ▼           ▼            ▼
       Local AI    Local AI     Local AI
          │           │            │
          └───────────┼────────────┘
                      │
                      ▼
             AI Observations
                      │
                      ▼
            Canonical Resolver
                      │
                      ▼
             Curated Albums
                      │
          ┌───────────┼────────────┐
          │           │            │
       iPhone       iPad        Apple TV
          │           │            │
          └───────────┼────────────┘
                      │
                      ▼
              CONSISTENT ALBUMS
```

The user's original photos and videos remain private, while every Apple device can present a consistent, intelligent view of the user's memories.
