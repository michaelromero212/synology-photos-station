# Shipping the app

Getting a build to TestFlight, and what has to be true before App Store Connect
will take it. The server has its own document — see DEPLOY.md.

## Every upload, in order

1. **Claim the build number: `Scripts/build-number.sh claim`.** Never pick it
   by hand or from memory. It takes one above the highest number anywhere on
   this Mac — every `CURRENT_PROJECT_VERSION` ever committed on any branch
   (origin's too), `project.yml` in every worktree, every archive and the
   number each of its uploads went up as, and every earlier claim — then
   writes it to `project.yml` and records it, under a lock, so two sessions
   shipping at once can't take the same number. Commit it on its own as
   "Build N for TestFlight: …" and archive from that commit.
   `Scripts/build-number.sh next` shows the number and where the current
   highest was seen, without changing anything.

   Why: App Store Connect refuses a build number it has already seen against
   the same version, and says so only *after* the archive and the upload. On
   November 13 two sessions shipped side by side: one used 34 and 35 while the
   other still had 34 as next, and then the iPhone's 36 was refused because
   App Store Connect already had a 36 that nothing here recorded. The script
   can't see App Store Connect itself. If an upload is still refused as a
   "Redundant Binary Upload", claim again — the refused number is past — and
   archive again. Never reuse a number, and never let Xcode renumber.

   The number lives in `project.yml`, not Xcode's General tab, which XcodeGen
   overwrites on every generate.

   **Every upload is both apps, iPhone and Mac, from the same commit under the
   same number** — even when only one of them changed. Shipping one alone left
   them on different numbers with different code (on November 13 the Mac was
   on 36 and the iPhone on 37), and then nobody can say which build has which
   fix. If one platform's upload fails, fix it and upload that platform under
   the same number; if its number is refused, claim a new number and send both
   again.
2. **Ship both apps: `Scripts/ship-testflight.sh`.** From a clean, committed
   tree, it archives the iPhone and the Mac app from HEAD in a fresh worktree
   (so nothing uncommitted — yours or another session's — gets in), checks
   both archives carry the claimed number and the iPhone its upload
   extension, and uploads both. It refuses a number nobody claimed, or one
   already uploaded from this Mac, and says plainly if either upload failed.

   By hand, only if the script can't be used: `xcodegen generate`, then in
   Xcode **Product → Archive** for `FrameStation-iOS` on **Any iOS Device** and
   again for `FrameStation-macOS`, then Organizer → **Distribute App →
   TestFlight & App Store** for each. If Xcode offers to manage the version and
   build number, turn it off: it renumbers the upload when the number is taken
   and `project.yml` falls behind without a word — an archive of build 2 went
   up as build 3 that way on October 23.
3. If asked about export compliance, the answer is **No**.
   `ITSAppUsesNonExemptEncryption` is already `false` in the plist, so it
   should not be asked at all. HTTPS and hashing are both exempt.

A version bump (`MARKETING_VERSION`) is only needed when the version people see
should change. The build number goes up every single time.

**Once it has processed, every time:**

4. Add it to the **Family Testing** group, iOS and Mac — the same number on
   both. Who is in the group doesn't change here.
5. Fill in **What to Test**: a few plain lines for family on what changed and
   what to try.
6. **Expire the builds before it**, on both, so no one stays on an old one.

## What the project already satisfies

Each of these was missing or wrong once, and each would have cost an upload.
They are listed so a future change that breaks one is recognizable.

- **`PrivacyInfo.xcprivacy`** — required of every app since May 2024, refused
  without it when the binary reaches a "required reason" API. This one reaches
  two: `UserDefaults` (CA92.1) and file timestamps on its own cache (C617.1).
  Nothing is collected and nothing is tracked, which is why those arrays are
  empty. One copy per platform, because each target excludes the other
  platforms' `Resources` directory; they are identical and change together.
- **`CFBundleIconName` at the top level of the plist.** `actool` wrote it only
  *nested* inside `CFBundleIcons`, which is ITMS-90713. It is declared
  explicitly in `project.yml` now, with the same value the catalog produces.
- **The version keys point at the build settings.** They used to be XcodeGen's
  literals — `1.0` and `1` — so `MARKETING_VERSION` said `0.1`, every build came
  out `1.0`, and nothing anywhere reported the disagreement.
- **The 1024pt icon has no alpha channel.** A transparent app icon is rejected.
- **Usage strings for everything the binary touches**: photo library (read and
  add) and local network. No camera, microphone or location code, so no strings
  for those — adding one for an API the app doesn't use is its own rejection.
- **iPad declares all four orientations**, which `UIRequiresFullScreen: false`
  requires. Claiming multitasking and three orientations is a contradiction
  Xcode flags.
- **Release archive builds arm64-only, with dSYMs**, so TestFlight crash reports
  symbolicate.
- **Debugging tools stay in development builds.** Export Playback Logs (More →
  Diagnostics) is compiled only into builds run from Xcode, under
  `#if DEBUG`; a Release archive — what TestFlight and the App Store get —
  doesn't contain it. Anything added for chasing a bug goes behind the same
  check, or testers see it.

## What needs your Apple account

None of this can be done from the repo.

- **An Apple Distribution certificate.** Only a Development one exists on this
  Mac. Xcode creates the distribution certificate and the App Store provisioning
  profile on the first *Distribute App*, with Automatically Manage Signing on —
  it needs the Apple Developer Program membership to be current.
- **The App ID's capabilities must match the entitlements**: Push Notifications,
  and Background Modes. If the profile is missing Push, the upload is accepted
  and the silent push simply never arrives, which is a much harder failure to
  read than a refusal.
- **An App Store Connect record** for `com.michaelromero.FrameStation`.
- `aps-environment` stays `development` in the entitlements file. Xcode swaps it
  to `production` when exporting for distribution, and `PushRegistrar.environment`
  already mirrors that with `#if DEBUG` — so a TestFlight build talks to the
  production APNs host and registers a production token.

## Getting it to the family

The distinction that matters, because it decides whether anyone waits on Apple:

- **Internal testers** — up to 100, each needs a role on your App Store Connect
  team. No review, available within minutes of processing.
- **External testers** — up to 10,000, invited by email or a public link, and
  the *first* build to a given group needs Beta App Review. That is usually a
  day or less, and later builds of the same version go straight through.

For a handful of family members, external testing with an invite link is the
kinder route: it needs no App Store Connect accounts for them, at the cost of
one review on the first build.

Beta App Review will want to reach the app's backend. FrameStation talks to
*your* NAS, which a reviewer cannot reach, so they get the demo server and
invite code in APP-REVIEW.md, with the same notes the App Store review gets.

## The other two platforms

Both archive clean in Release, with dSYMs and the privacy manifest in the
bundle. Each is its own app record in App Store Connect and its own upload;
they share a bundle identifier, which is allowed and is what makes them one
product to a buyer.

### tvOS

An Apple TV app is refused without an **App Icon & Top Shelf Image** brand
assets collection, and for a long time there wasn't one — `Scripts/GenerateIcon.swift`
drew the layers into `Design/Icon` and stopped, with no catalog for them to go
into. The catalog exists now and the generator fills it, so the artwork cannot
drift from what ships:

- **App Icon**, 400×240 and 800×480, as a two-layer stack — gradient behind,
  frames in front. The stack is not decoration: it is what lets the focus
  engine part the layers as the remote moves across the row.
- **App Icon – App Store**, a single 1280×768, same two layers.
- **Top Shelf Image** at 1920×720, **Top Shelf Image Wide** at 2320×720, each
  with a @2x. These are flat rather than layered, and the mark is kept to about
  half the height — a top shelf is a backdrop, not a poster.

Re-run `swift Scripts/GenerateIcon.swift` after any change to the mark; it
writes every platform's catalog in one pass, which is the point of it.

### macOS

- **`LSApplicationCategoryType`** is required of every Mac App Store submission
  and the rejection for omitting it arrives after the upload. Set to
  photography.
- **Hardened runtime** is on. It is what notarization needs if this is ever
  distributed directly, and it costs nothing on the App Store path — where the
  sandbox is the requirement, and that was already set.
- Distribution needs a **Mac App Distribution** certificate and a provisioning
  profile carrying the sandbox entitlement. Same account, same first-time
  automatic creation as iOS.

TestFlight covers macOS, so family can test the Mac app the same way. tvOS has
no TestFlight of its own — testers install it from the App Store tab on the
Apple TV once they are in a TestFlight group for the app.
