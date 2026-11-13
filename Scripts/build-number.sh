#!/bin/bash
# The next TestFlight build number, worked out from everything this Mac can
# see, and reserved so no other session takes it.
#
#   Scripts/build-number.sh next     # print it and the evidence; changes nothing
#   Scripts/build-number.sh claim    # reserve it and write it to project.yml
#
# Why this exists: on 2026-11-13 two sessions shipped side by side. One used
# 34 and 35 while the other still thought 34 was next, and then App Store
# Connect refused an iPhone 36 it already had from an upload no commit
# recorded. A refused number costs an archive and an upload, and it is only
# reported after both.
#
# The number is one above the highest of:
#   - every CURRENT_PROJECT_VERSION ever committed, on any branch, including
#     origin's after a fetch;
#   - project.yml in every worktree, committed or not;
#   - every FrameStation archive on this Mac: its build number, and the number
#     each recorded upload went up as (Xcode can renumber on the way out);
#   - every number already claimed here (the ledger below).
#
# What it can't see: a build uploaded from another Mac, or archived somewhere
# else and deleted. Only App Store Connect knows those. If an upload is still
# refused as a "Redundant Binary Upload", claim again — the refused number is
# recorded, so the next claim is past it — and archive again. Never reuse a
# number, and never let Xcode renumber an upload.
#
# The ledger lives outside the repository so every worktree and session on
# this Mac shares it. FS_BUILD_LEDGER_DIR points it somewhere else, for
# testing.

set -euo pipefail

BUNDLE_ID="com.michaelromero.FrameStation"
LEDGER_DIR="${FS_BUILD_LEDGER_DIR:-$HOME/Library/Application Support/FrameStation-Shipping}"
LEDGER="$LEDGER_DIR/build-numbers.tsv"
LOCK="$LEDGER_DIR/lock"
ARCHIVES="$HOME/Library/Developer/Xcode/Archives"

REPO="$(git rev-parse --show-toplevel)"
PROJECT="$REPO/project.yml"

usage() {
    sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
}

# Prints "number<TAB>where it was seen" lines, one per source.
evidence() {
    # A missing field — an archive never uploaded, a worktree without the
    # line — is no number, not a failure. Runs in its own subshell (it is
    # always piped), so this doesn't loosen the rest of the script.
    set +e +o pipefail
    # Every value project.yml has ever had, on every ref.
    git -C "$REPO" fetch --quiet origin 2>/dev/null || echo "!	could not fetch origin; its newest commits are not counted" >&2
    local committed
    committed=$(git -C "$REPO" log --all -p -G 'CURRENT_PROJECT_VERSION:' -- project.yml 2>/dev/null \
        | sed -n 's/^[+-][[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*"\{0,1\}\([0-9][0-9]*\)"\{0,1\}.*/\1/p' \
        | sort -n | tail -1)
    if [ -n "$committed" ]; then printf '%s\tgit history (all branches)\n' "$committed"; fi

    # Every worktree's project.yml, as it is on disk now.
    git -C "$REPO" worktree list --porcelain | sed -n 's/^worktree //p' | while IFS= read -r tree; do
        local v
        v=$(sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*"\{0,1\}\([0-9][0-9]*\)"\{0,1\}.*/\1/p' "$tree/project.yml" 2>/dev/null | head -1)
        if [ -n "$v" ]; then printf '%s\tproject.yml in %s\n' "$v" "$tree"; fi
    done

    # Every archive of this app: what it was built as, and what it went up as.
    if [ -d "$ARCHIVES" ]; then
        find "$ARCHIVES" -maxdepth 3 -name '*.xcarchive' -type d 2>/dev/null | while IFS= read -r archive; do
            local plist="$archive/Info.plist" id built
            id=$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleIdentifier' "$plist" 2>/dev/null || true)
            [ "$id" = "$BUNDLE_ID" ] || continue
            built=$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleVersion' "$plist" 2>/dev/null || true)
            if [ -n "$built" ]; then printf '%s\tarchive %s\n' "${built%%.*}" "${archive#"$ARCHIVES"/}"; fi
            /usr/libexec/PlistBuddy -c 'Print :Distributions' "$plist" 2>/dev/null \
                | sed -n 's/^[[:space:]]*uploadedBuildNumber = \([0-9][0-9]*\).*/\1/p' \
                | while read -r up; do printf '%s\tupload recorded in %s\n' "$up" "${archive#"$ARCHIVES"/}"; done
        done
    fi

    # Numbers already claimed on this Mac.
    if [ -f "$LEDGER" ]; then
        local claimed
        claimed=$(cut -f1 "$LEDGER" | grep -E '^[0-9]+$' | sort -n | tail -1 || true)
        if [ -n "$claimed" ]; then printf '%s\tclaimed in %s\n' "$claimed" "$LEDGER"; fi
    fi
    return 0
}

highest() {
    evidence | cut -f1 | grep -E '^[0-9]+$' | sort -n | tail -1
}

show() {
    local top
    top=$(highest)
    top=${top:-0}
    echo "Highest build number seen: $top"
    evidence | sort -t$'\t' -k1,1nr | awk -F'\t' -v top="$top" '$1 == top { print "  " $1 "  " $2 }' | sort -u
    echo "Next: $((top + 1))"
    echo "(Not checked: App Store Connect itself. A build uploaded from another Mac is invisible here.)"
}

claim() {
    mkdir -p "$LEDGER_DIR"
    # One claim at a time across sessions: mkdir is atomic.
    local waited=0
    until mkdir "$LOCK" 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
        if [ "$waited" -ge 30 ]; then
            echo "Another claim has held $LOCK for 30 seconds. If no other session is shipping, remove it and try again." >&2
            exit 1
        fi
    done
    trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

    local top next
    top=$(highest)
    next=$(( ${top:-0} + 1 ))

    if ! grep -qE '^[[:space:]]*CURRENT_PROJECT_VERSION:' "$PROJECT"; then
        echo "No CURRENT_PROJECT_VERSION line in $PROJECT" >&2
        exit 1
    fi
    sed -i '' -E "s/^([[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*)\"?[0-9]+\"?/\\1\"$next\"/" "$PROJECT"

    [ -f "$LEDGER" ] || printf 'build\tclaimed\tcommit\tworktree\n' > "$LEDGER"
    printf '%s\t%s\t%s\t%s\n' "$next" "$(date '+%Y-%m-%d %H:%M:%S %Z')" \
        "$(git -C "$REPO" rev-parse --short HEAD)" "$REPO" >> "$LEDGER"

    echo "Claimed build $next (highest seen was ${top:-0}); project.yml now says $next."
    echo "Commit it as \"Build $next for TestFlight: …\" and archive from that commit."
}

case "${1:-}" in
    next) show ;;
    claim) claim ;;
    *) usage ;;
esac
