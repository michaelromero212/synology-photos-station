#!/bin/bash
# Archives and uploads the iPhone AND the Mac app to TestFlight, together,
# from the commit you are on, under the build number in its project.yml.
#
#   Scripts/build-number.sh claim        # 1. reserve the number
#   git commit -m "Build N for TestFlight: …" project.yml
#   Scripts/ship-testflight.sh           # 2. both apps, one number
#
# Both, always, from one commit: shipping one platform alone left them on
# different numbers with different code (Mac 36, iPhone 37 on 2026-11-13),
# and then nobody can say which build has which fix.
#
# Builds in a fresh worktree of HEAD, so nothing uncommitted — yours or
# another session's — ends up in a build, and copies in what a clean checkout
# lacks: Config/Local.xcconfig (gitignored; the background-upload host) and
# the hand-made archive schemes (xcodegen leaves none until Xcode opens the
# project). Uploads with Xcode's own Apple Account sign-in; "Failed to Use
# Accounts" means that sign-in has lapsed (Xcode > Settings > Accounts).
#
# Does nothing in App Store Connect beyond the upload: no tester groups, no
# What to Test, nothing expired. See SHIPPING.md for those.

set -euo pipefail

REPO="$(git rev-parse --show-toplevel)"
cd "$REPO"
BUNDLE_ID="com.michaelromero.FrameStation"
TEAM="47453G7Q89"
LEDGER="${FS_BUILD_LEDGER_DIR:-$HOME/Library/Application Support/FrameStation-Shipping}/build-numbers.tsv"

fail() { echo "✗ $*" >&2; exit 1; }

# --- What is being shipped -------------------------------------------------

git diff --quiet HEAD -- . ':!Design' || fail "Uncommitted changes. Commit what should ship (the build is made from HEAD alone)."
COMMIT=$(git rev-parse --short HEAD)
BUILD=$(git show HEAD:project.yml | sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*"\{0,1\}\([0-9][0-9]*\)"\{0,1\}.*/\1/p' | head -1)
[ -n "$BUILD" ] || fail "No CURRENT_PROJECT_VERSION in HEAD's project.yml."

grep -qE "^$BUILD	" "$LEDGER" 2>/dev/null \
    || fail "Build $BUILD was never claimed. Run Scripts/build-number.sh claim and commit project.yml first."

# Already uploaded from this Mac? Then this number is spent.
ARCHIVES="$HOME/Library/Developer/Xcode/Archives"
while IFS= read -r plist; do
    [ "$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleIdentifier' "$plist" 2>/dev/null)" = "$BUNDLE_ID" ] || continue
    # "Uploaded to Apple" is the upload event's title only when it went
    # through; a refused upload records the number too, and "Upload failed".
    dist=$(/usr/libexec/PlistBuddy -c 'Print :Distributions' "$plist" 2>/dev/null || true)
    if grep -q "uploadedBuildNumber = $BUILD$" <<<"$dist" && grep -q "title = Uploaded to Apple" <<<"$dist"; then
        fail "Build $BUILD has already been uploaded from this Mac (${plist%/Info.plist}). Claim a new number."
    fi
done < <(find "$ARCHIVES" -maxdepth 3 -name Info.plist -path '*.xcarchive/Info.plist' 2>/dev/null)

echo "Shipping build $BUILD from $COMMIT — iPhone and Mac."

# --- A clean copy of HEAD --------------------------------------------------

WORK=$(mktemp -d "${TMPDIR:-/tmp}/framestation-ship-$BUILD.XXXXXX")
TREE="$WORK/tree"
cleanup() { git -C "$REPO" worktree remove --force "$TREE" >/dev/null 2>&1 || true; git -C "$REPO" worktree prune; }
trap cleanup EXIT

git worktree add --detach --quiet "$TREE" HEAD
[ -f "$REPO/Config/Local.xcconfig" ] || fail "Config/Local.xcconfig is missing; without it background uploads have no host."
cp "$REPO/Config/Local.xcconfig" "$TREE/Config/Local.xcconfig"
(cd "$TREE" && xcodegen generate --quiet)
SCHEMES=$(ls -d "$REPO"/FrameStation.xcodeproj/xcuserdata/*.xcuserdatad 2>/dev/null | head -1)
[ -n "$SCHEMES" ] && [ -d "$SCHEMES/xcschemes" ] || fail "No archive schemes in FrameStation.xcodeproj/xcuserdata (see SHIPPING notes)."
mkdir -p "$TREE/FrameStation.xcodeproj/xcuserdata/$(basename "$SCHEMES")"
cp -R "$SCHEMES/xcschemes" "$TREE/FrameStation.xcodeproj/xcuserdata/$(basename "$SCHEMES")/"

cat > "$WORK/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>uploadSymbols</key><true/>
</dict></plist>
PLIST

# --- Archive both, check both, then upload both ----------------------------

DAY=$(date +%Y-%m-%d)
archive() {  # platform scheme destination
    local name="FrameStation-$1-$BUILD" path="$ARCHIVES/$DAY/FrameStation-$1-$BUILD.xcarchive"
    echo "→ Archiving $1…"
    (cd "$TREE" && xcodebuild archive -project FrameStation.xcodeproj -scheme "$2" \
        -configuration Release -destination "$3" -archivePath "$path" \
        -allowProvisioningUpdates > "$WORK/archive-$1.log" 2>&1) \
        || { grep -m 15 "error:" "$WORK/archive-$1.log" >&2; fail "$1 archive failed (log: $WORK/archive-$1.log)."; }
    echo "$path"
}

IOS=$(archive iOS FrameStation-iOS 'generic/platform=iOS' | tail -1)
MAC=$(archive macOS FrameStation-macOS 'generic/platform=macOS' | tail -1)

check() {  # label info.plist
    local v id
    v=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$2")
    id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$2")
    [ "$v" = "$BUILD" ] || fail "$1 archive says build $v, not $BUILD."
    [ "$id" = "$BUNDLE_ID" ] || fail "$1 archive is $id, not $BUNDLE_ID."
}
check iPhone "$IOS/Products/Applications/FrameStation-iOS.app/Info.plist"
check Mac "$MAC/Products/Applications/FrameStation-macOS.app/Contents/Info.plist"
ls "$IOS/Products/Applications/FrameStation-iOS.app/Extensions/"*.appex >/dev/null 2>&1 \
    || fail "The background upload extension isn't in the iPhone app's Extensions/."
echo "✓ Both archives are build $BUILD of $BUNDLE_ID; the iPhone carries its upload extension."

upload() {  # platform archive
    echo "→ Uploading $1…"
    if xcodebuild -exportArchive -archivePath "$2" -exportOptionsPlist "$WORK/ExportOptions.plist" \
        -exportPath "$WORK/export-$1" -allowProvisioningUpdates > "$WORK/export-$1.log" 2>&1 \
        && grep -q "Upload succeeded" "$WORK/export-$1.log"; then
        echo "✓ $1 build $BUILD uploaded."
        return 0
    fi
    grep -hE "error:|Redundant Binary|Failed to Use Accounts" "$WORK/export-$1.log" | head -5 >&2
    if grep -q "Redundant Binary" "$WORK/export-$1.log"; then
        echo "  App Store Connect already has build $BUILD. Claim a new number and ship BOTH again." >&2
    fi
    return 1
}

ok=0
upload iPhone "$IOS" || ok=1
upload Mac "$MAC" || ok=1

if [ $ok -ne 0 ]; then
    trap - EXIT; cleanup
    fail "Build $BUILD is NOT on TestFlight for both apps. Logs: $WORK"
fi
echo "✓ Build $BUILD ($COMMIT) is uploaded for the iPhone and the Mac. Apple processes it next."
