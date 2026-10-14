# App Store listing

What to enter in App Store Connect for **FrameStation Photos**. SHIPPING.md covers
getting a build uploaded; this covers everything around it.

## App Information

- **Name:** FrameStation Photos
- **Subtitle:** Your photos, on your own NAS
- **Primary category:** Photo & Video. **Secondary:** Utilities.
- **Content Rights:** "No, it does not contain, show, or access third-party
  content." Everything it shows is the user's own media on their own server.
- **Age Rating:** None or No to every question except user-generated content,
  and let App Store Connect work out the rating from those.
  - Unrestricted web access: No. The app talks only to the user's server.
  - Messaging or chat: No. There is none.
  - User-generated content: Yes. People share photos with each other in shared
    libraries. They're private and invite-only, on the user's own server, and
    nothing is public, but App Review counts sharing between people as
    user-generated content, and it's what reporting, blocking and the Terms of
    Use are for. See APP-REVIEW.md.

## Pricing

Free, in all regions.

## App Privacy

- **Privacy Policy URL:** https://michaelromero212.github.io/synology-photos-station/privacy.html
- **Apple TV Privacy Policy:** the same URL.
- **Data collection:** "No, we do not collect data from this app." This matches
  `PrivacyInfo.xcprivacy`: no analytics, no crash reporter, no tracking. Media
  goes only to the user's own server, and Apple doesn't count that as
  collection.

## Version page (English U.S.)

- **Support URL:** https://michaelromero212.github.io/synology-photos-station/
- **Keywords** (96 of 100 characters; leave "Synology" out, since trademarks
  in keywords get rejected):

  ```
  nas,photo backup,self-hosted,family photos,dsm,home server,private,albums,video,memories,library
  ```

- **Promotional Text:**

  ```
  Back up every photo and video to the NAS you already own. No subscription, no cloud storage limits, no one else holding your memories.
  ```

- **Description:**

  ```
  FrameStation Photos keeps your family's photos and videos on your own Synology NAS, not someone else's cloud.

  BACK UP AUTOMATICALLY
  Your iPhone and iPad back up new photos and videos to your NAS. Choose Wi-Fi only, back up only while charging, or skip videos. Edited photos are saved as you see them.

  ONE LIBRARY, EVERY DEVICE
  Browse your whole library in a fast, familiar timeline on iPhone, iPad, Mac, and Apple TV. Videos play smoothly and keep going into the next clip.

  SHARE WITH YOUR FAMILY
  Create a shared library for the whole family, and everyone's photos land in one place with who added them. Invite family members with a code. They don't need a NAS account.

  ALBUMS AND MEMORIES
  Make your own albums, personal or shared. FrameStation also gathers trips and moments into albums for you, using analysis that runs on your device.

  FIND BY PLACE
  Search your library by where photos were taken, and see them on a map.

  NOTHING LEAVES YOUR HOME
  No account with us, no analytics, no ads, no tracking. Your photos travel only between your devices and your NAS.

  Deleted something by mistake? Recently Deleted keeps it for 29 days.

  REQUIREMENTS
  FrameStation Photos connects to the free FrameStation server, which runs on a Synology NAS in Container Manager. Setup instructions are on the support page.
  ```

## App Review Information

- **Sign-in and notes:** APP-REVIEW.md. App Review can't reach a server on a
  home network, so they get a demo server of their own and an invite code for
  it; that document sets it up and has the notes to paste.
- **Contact Information:** your name, phone, and email. Apple uses these only to
  reach you; they aren't shown on the store.

## Build

Upload one following SHIPPING.md, wait for processing (about 15–30 minutes),
then pick it under **Build** on the version page.
