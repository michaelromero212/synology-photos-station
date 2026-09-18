# Shipping the app

Getting a build to TestFlight, and what has to be true before App Store Connect
will take it. The server has its own document — see DEPLOY.md.

## Every upload, in order

1. **Bump the build number.** `CURRENT_PROJECT_VERSION` in `project.yml`, not in
   Xcode's General tab — XcodeGen overwrites that on every generate. App Store
   Connect refuses a build number it has already seen against the same version,
   and it tells you *after* the upload rather than before it.
2. `xcodegen generate`
3. Xcode → **Product → Archive**, with the scheme set to `FrameStation-iOS` and
   the destination to **Any iOS Device**. A simulator destination grays Archive
   out, which is the usual reason it looks broken.
4. Organizer → **Distribute App → TestFlight & App Store**.
5. Answer the export-compliance question **No**. `ITSAppUsesNonExemptEncryption`
   is already `false` in the plist, so this should not be asked at all; if it
   is, the answer is still no. HTTPS and hashing are both exempt.

A version bump (`MARKETING_VERSION`) is only needed when the version people see
should change. The build number goes up every single time.

## What the project already satisfies

Each of these was missing or wrong once, and each would have cost an upload.
They are listed so a future change that breaks one is recognisable.

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
*your* NAS, which a reviewer cannot reach, so the review notes have to say so
plainly — that it is a client for a self-hosted server on the tester's own
network, and give them a test host and invite code if one can be exposed, or
explain that sign-in cannot be completed without one.

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
- **Hardened runtime** is on. It is what notarisation needs if this is ever
  distributed directly, and it costs nothing on the App Store path — where the
  sandbox is the requirement, and that was already set.
- Distribution needs a **Mac App Distribution** certificate and a provisioning
  profile carrying the sandbox entitlement. Same account, same first-time
  automatic creation as iOS.

TestFlight covers macOS, so family can test the Mac app the same way. tvOS has
no TestFlight of its own — testers install it from the App Store tab on the
Apple TV once they are in a TestFlight group for the app.
