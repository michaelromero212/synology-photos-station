# App Review

What App Review asked for in October 2026, with the answer to each. APP-STORE.md
covers the listing and SHIPPING.md the build.

This repository is public, so the demo server's real address and code never go
in it. They live in APP-REVIEW.local.md, which is gitignored. Below they're
`<nas-host>` (the NAS's hostname, as in DEPLOY.md) and `<review-code>`.

## The demo server

App Review can't reach a NAS on a home network, so they get one of their own: a
second FrameStation on the same NAS, with sample photos only, its own address,
its own database and its own folder. It runs as an unprivileged user with only
its own folders mounted, has no DSM sign-in and no File Station tree, and can't
reach the family's library. `Demo/docker-compose.yml` says what it is and isn't
given, and why.

Reviewers sign in with an invite code that joins them to a shared library,
**Demo Family**, whose photos were added by **Sam (Demo)**. That's what lets them
try reporting and blocking: both need photos someone else added.

### Setting it up, once

1. **Pick the sample photos.** Twenty to forty photos and a short video or two
   that you're happy for Apple to see: places, food, pets. No people, nothing
   private. Put them in a folder on the Mac, here `~/Desktop/Demo Photos`. The
   setup strips their locations before importing them, so nobody can read where
   they were taken from the server's copies.

2. **Copy the files to the NAS**, from the repository on the Mac:

   ```bash
   ssh nas 'mkdir -p /volume1/docker/framestation-demo/seed'
   ```

   ```bash
   scp Demo/docker-compose.yml Scripts/demo-setup.sh nas:/volume1/docker/framestation-demo/
   ```

   ```bash
   scp ~/Desktop/Demo\ Photos/* nas:/volume1/docker/framestation-demo/seed/
   ```

3. **Give it its own database password**, never the family server's:

   ```bash
   ssh nas 'cd /volume1/docker/framestation-demo && umask 077 && echo "POSTGRES_PASSWORD=$(openssl rand -hex 24)" > .env'
   ```

4. **Run the setup.** It pulls the image, starts the server, makes Sam and Demo
   Family, imports the photos, and ends by printing the reviewer code. That code
   goes in APP-REVIEW.local.md and in App Store Connect.

   ```bash
   ssh -t nas 'cd /volume1/docker/framestation-demo && sudo bash demo-setup.sh'
   ```

5. **Give it an address.** In DSM: Control Panel → Login Portal → Advanced →
   Reverse Proxy → Create:

   | | Protocol | Hostname | Port |
   |---|---|---|---|
   | Source | HTTPS | `demo.<nas-host>` | 8443 |
   | Destination | HTTP | `localhost` | 8081 |

   Name it FrameStation Demo. That's all it needs. The NAS's certificate already
   covers `*.<nas-host>`, the name already resolves, and 8443 is already
   forwarded, so the router and the certificate stay as they are.

6. **Check it from outside the house**, with the Mac on a phone's hotspot or the
   check run from a phone on cellular:

   ```bash
   curl -s https://demo.<nas-host>:8443/health
   ```

   The answer should list `account-deletion` and `report-and-block`.

7. **Sign in to it once** in the simulator, the way the notes below tell a
   reviewer to, so the first person to follow them isn't Apple. Each sign-in
   uses one of the code's twenty uses.

### Keeping it

- **Update it with the family server**, so a reviewer sees the build that
  ships:

  ```bash
  ssh -t nas 'cd /volume1/docker/framestation-demo && sudo /usr/local/bin/docker compose pull && sudo /usr/local/bin/docker compose up -d'
  ```

- **A fresh code**: run the setup again. It keeps Sam, Demo Family and the
  photos, and prints a new code. Codes last ninety days.
- **Between reviews** it can stay up or come down. This stops it, and the
  setup brings it back:

  ```bash
  ssh -t nas 'cd /volume1/docker/framestation-demo && sudo /usr/local/bin/docker compose down'
  ```

## App Review Information

In App Store Connect, on the version page under App Review Information.

- **Sign-in required:** on.
- **User name:** `demo.<nas-host>` (the server address; there is no username).
- **Password:** `<review-code>`.
- **Notes:** paste this, with the two placeholders filled in.

```
FrameStation Photos is the app for FrameStation, a free, open-source photo library server that anyone can run on their own Synology NAS (github.com/michaelromero212/synology-photos-station). The app backs up an iPhone's photos and videos to that server and browses them. The developer runs no service and never sees anyone's photos: each family's server is their own. For review, we run a demo server with sample photos.

SIGNING IN
1. On the sign-in screen, tap the gear at the bottom left.
2. Under "Sign in with", choose Invite Code, then tap Done.
3. Hostname or IP: demo.<nas-host>
4. Your name: any name.
5. Invite code: <review-code>
6. Leave HTTPS on and tap Connect.
The invite code creates your account. It works 20 times, so it can be used on more than one device and again after deleting the account.

WHAT TO TRY
- Photos tab: your own library. It's empty until you add photos with the + button or turn on Photo Backup.
- Albums tab, then Demo Family under Shared Albums: a shared library you joined with the code. Its photos were added by "Sam (Demo)".
- Report a photo: open one of Sam's photos, tap the ••• button at the top, then Report Photo, and choose a reason. It's hidden from you at once, and the library's owner is asked to review it in the library's Edit screen.
- Block someone: open one of Sam's photos, tap •••, then Block Sam (Demo). Everything Sam added is hidden from you. Unblock in More > Blocked People.
- Delete the account: More > Delete Account. It explains what's deleted, asks you to confirm, deletes the account and signs you out.

SHARING AND SAFETY
Photos are shared only inside shared libraries, which are private and invite-only. There's no public feed, profile, discovery, comments or messaging. Each library's owner chooses its members and can remove any photo or member. Members can report a photo (hidden from them right away, and the owner reviews it) and block a member. Signing in means agreeing to the Terms of Use, linked on the sign-in screen, which have no tolerance for objectionable content: https://michaelromero212.github.io/synology-photos-station/terms.html
```

## Answers to Apple's questions

**Screen recording.** On a physical iPhone, with Screen Recording from Control
Center, against the demo server. One take, in this order:

1. Force-quit the app, then launch it from the Home Screen.
2. Sign in with the invite code, following the notes above. This is
   registration: the code creates the account.
3. Browse: scroll the Photos tab, open Albums → Demo Family, open a photo, swipe
   to the next, play a video.
4. Add a photo to Demo Family with + to show something being shared.
5. Report one of Sam's photos: ••• → Report Photo → a reason. The toast says
   it's reported, and the photo is gone from the grid.
6. Block Sam: ••• on another of Sam's photos → Block Sam (Demo) → Block. Sam's
   photos are gone. Then More → Blocked People → Unblock, and they're back.
7. Sign out from More, and sign in again with the same code (login).
8. More → Delete Account → Delete Account → Delete Account. The app returns to
   the sign-in screen and says the account was deleted.

**Purpose and audience.** A private, self-hosted alternative to cloud photo
storage: back up an iPhone or iPad's photos and videos to your own Synology
NAS, browse them on iPhone, iPad, Mac and Apple TV, and share libraries with
family. For anyone who owns a Synology NAS. The FrameStation server is free and
open source, and installs in Synology's Container Manager.

**Setup and credentials.** The demo server and invite code above. The app has
no username and password of its own: an invite code from a server's owner
creates an account on that server, and a DSM account on that NAS also works.

**External services.** The app connects only to the FrameStation server the
person enters, which is their own NAS. Apple services: Apple Push Notification
service (when the server's owner has set it up), MapKit for maps, and Vision on
the device for curated albums. A DSM sign-in is checked by the person's own
server against their own NAS. No analytics, advertising, crash reporting or
third-party SDKs.

**Regional differences.** None. The app works the same everywhere, with no
region-specific content or features.

**Regulated industries.** Not applicable. The app offers nothing in a
regulated field: no financial, medical, gambling or legal services.

**2.1, app completeness.** Tested on iPhone and iPad against the demo server
before submitting, including the whole recording above.

**2.1, demo account.** The demo server and code. It's up for as long as the
review takes, and the code works twenty times.

**2.3.3, screenshots.** Taken from the app in use on each device type, not the
sign-in screen. iPad screenshots from an iPad, not a stretched iPhone. Use the
demo server or a library with nothing private in it.

**3.1.1, in-app purchase.** There is none. The app and the server are free, and
nothing is sold or unlocked. An invite code is not a purchase: it lets someone
into a server its owner runs.

**3.2, business model.** Free, no ads, no subscription, no accounts with the
developer. Open to the general public: anyone with a Synology NAS can install
the free server and use the app. It isn't limited to one family or
organization.
