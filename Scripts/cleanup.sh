#!/bin/bash
#
# Finds this project's leftovers (build output, stale DerivedData, old archives,
# scratch databases, oversized logs, NAS deploy clutter) and, only with
# --apply, removes them. Written so nobody has to rediscover where the waste
# collects.
#
#   Scripts/cleanup.sh                 report what would go, with sizes; removes nothing
#   Scripts/cleanup.sh --apply         do it
#   Scripts/cleanup.sh --nas           also check the NAS (ssh -o BatchMode=yes nas; key auth, no sudo)
#   Scripts/cleanup.sh --nas --apply   and clean the NAS
#
# KEEP_ARCHIVES=6   how many FrameStation build numbers of Xcode archives to keep
#
# Conservative by design: it only touches things it can positively identify by
# name AND by content (a plist, a worktree's git state, a database prefix).
# Things that can't be rebuilt (old archives) go to ~/.Trash, not rm. Anything
# that merely looks suspicious (orphan processes, unknown simulator folders,
# unmerged worktrees and branches, NAS staging folders) is reported, never
# removed.
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLY=0
NAS=0
KEEP_ARCHIVES="${KEEP_ARCHIVES:-6}"
for arg in "$@"; do
    case "$arg" in
    --apply) APPLY=1 ;;
    --nas) NAS=1 ;;
    -h|--help) sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
    esac
done

TMP="${TMPDIR:-/tmp}"
TMP="${TMP%/}"
DERIVED="$HOME/Library/Developer/Xcode/DerivedData"
ARCHIVES="$HOME/Library/Developer/Xcode/Archives"
SIMDEVICES="$HOME/Library/Developer/CoreSimulator/Devices"
DEVLOG="$HOME/.framestation-dev/logs/server.log"
PSQL="/opt/homebrew/opt/postgresql@16/bin/psql"
PGPORT=55432

TOTAL_KB=0     # what was (or would be) reclaimed
REPORT_ONLY=0  # number of items flagged for a human

kb_of() { du -sk "$1" 2>/dev/null | awk '{print $1}' || echo 0; }
human() {  # kilobytes -> human
    awk -v k="$1" 'BEGIN{ if (k>=1048576) printf "%.1f GB", k/1048576; else if (k>=1024) printf "%.0f MB", k/1024; else printf "%d KB", k }'
}
say() { echo "$*"; }
section() { echo; echo "== $*"; }

# remove <path> <label>: rm (or report) one identified path.
remove() {
    local p="$1" kb
    [ -e "$p" ] || [ -L "$p" ] || return 0
    kb=$(kb_of "$p"); kb="${kb:-0}"
    TOTAL_KB=$((TOTAL_KB + kb))
    if [ "$APPLY" = 1 ]; then
        rm -rf -- "$p"
        say "  removed  $(human "$kb")  $p"
    else
        say "  would remove  $(human "$kb")  $p"
    fi
}

# trash <path>: same, but to ~/.Trash, for what can't be rebuilt.
trash() {
    local p="$1" kb dest
    [ -e "$p" ] || return 0
    kb=$(kb_of "$p"); kb="${kb:-0}"
    TOTAL_KB=$((TOTAL_KB + kb))
    if [ "$APPLY" = 1 ]; then
        mkdir -p "$HOME/.Trash"
        dest="$HOME/.Trash/$(basename "$p")-$(date +%Y%m%d%H%M%S)-$$"
        mv -- "$p" "$dest"
        say "  trashed  $(human "$kb")  $p"
    else
        say "  would move to Trash  $(human "$kb")  $p"
    fi
}

note() { REPORT_ONLY=$((REPORT_ONLY + 1)); say "  report only: $*"; }

[ "$APPLY" = 1 ] && say "cleanup --apply: removing what is listed." || say "cleanup (dry run): nothing is removed. Pass --apply to act."

# ---------------------------------------------------------------- Mac checks

section "repo build/ (xcodebuild output)"
if [ -d "$REPO/build" ]; then remove "$REPO/build"; else say "  none"; fi

section "stray dirs in FrameStation.xcodeproj whose names start with '-'"
found=0
if [ -d "$REPO/FrameStation.xcodeproj" ]; then
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        found=1; remove "$d"
    done < <(find "$REPO/FrameStation.xcodeproj" -maxdepth 1 -mindepth 1 -type d -name '-*' 2>/dev/null)
fi
[ "$found" = 1 ] || say "  none"

section "SwiftPM .build/arm64-apple-macosx where .build/out exists"
found=0
for b in "$REPO/Server/.build" "$REPO"/Packages/*/.build; do
    if [ -d "$b/arm64-apple-macosx" ] && [ -d "$b/out" ]; then
        found=1; remove "$b/arm64-apple-macosx"
    fi
done
[ "$found" = 1 ] || say "  none"

section "DerivedData for FrameStation whose workspace no longer exists"
found=0
if [ -d "$DERIVED" ]; then
    for d in "$DERIVED"/FrameStation-*; do
        [ -d "$d" ] || continue
        ws=$(/usr/libexec/PlistBuddy -c 'Print :WorkspacePath' "$d/info.plist" 2>/dev/null || true)
        [ -n "$ws" ] || continue          # can't identify it: leave it
        if [ ! -e "$ws" ]; then
            found=1
            remove "$d"
            hash="${d##*/FrameStation-}"
            for lock in "$TMP"/_Users_*_DerivedData_FrameStation-"$hash"_SourcePackages_workspace-state.json.lock; do
                [ -e "$lock" ] && remove "$lock"
            done
        fi
    done
fi
[ "$found" = 1 ] || say "  none"

section "Xcode archives (FrameStation only; keep newest $KEEP_ARCHIVES build numbers)"
found=0
if [ -d "$ARCHIVES" ]; then
    list=""   # "<build>\t<path>"
    while IFS= read -r a; do
        [ -n "$a" ] || continue
        case "$(basename "$a")" in FrameStation*) ;; *) continue ;; esac
        v=$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleVersion' "$a/Info.plist" 2>/dev/null || true)
        case "$v" in ''|*[!0-9]*) note "can't read a build number, leaving it: $a"; continue ;; esac
        list="$list$v	$a"$'\n'
    done < <(find "$ARCHIVES" -maxdepth 2 -name '*.xcarchive' -type d 2>/dev/null)
    if [ -n "$list" ]; then
        keep=$(printf '%s' "$list" | cut -f1 | sort -un | tail -n "$KEEP_ARCHIVES")
        while IFS="	" read -r v a; do
            [ -n "$a" ] || continue
            if ! printf '%s\n' "$keep" | grep -qx "$v"; then found=1; trash "$a"; fi
        done <<<"$list"
    fi
fi
[ "$found" = 1 ] || say "  none"

section "leftovers in \$TMPDIR older than a day"
found=0
while IFS= read -r p; do
    [ -n "$p" ] || continue
    found=1; remove "$p"
done < <(find "$TMP" -maxdepth 1 \( -name 'framestation-ship-*' -o -name 'FrameStation-*.xcdistributionlogs' \) -mtime +1 2>/dev/null)
[ "$found" = 1 ] || say "  none"

# A branch (or worktree HEAD) counts as merged into main when it is an
# ancestor of main, or when every commit on it has a patch-equal twin in main
# (squash/rebase merges), which shows as no '+' lines in `git cherry`.
is_merged() {  # rev
    git -C "$REPO" merge-base --is-ancestor "$1" main 2>/dev/null && return 0
    # A cherry that fails says nothing, and nothing must not read as "merged".
    local cherry
    cherry=$(git -C "$REPO" cherry main "$1" 2>/dev/null) || return 1
    ! grep -q '^+' <<<"$cherry"
}

# Days since a worktree was last used: its newest checkout, commit or staging
# (the git dir's HEAD log and index). A session that has just made a worktree
# has nothing on it yet, which looks exactly like "merged and clean", so a
# worktree has to be idle for a week as well before it goes.
WORKTREE_IDLE_DAYS=7
idle_days() {  # worktree path
    local gd newest=0 m f
    gd=$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null) || { echo 0; return; }
    for f in "$gd/logs/HEAD" "$gd/index" "$gd/HEAD"; do
        [ -e "$f" ] || continue
        m=$(stat -f %m "$f" 2>/dev/null || echo 0)
        [ "$m" -gt "$newest" ] && newest=$m
    done
    [ "$newest" -gt 0 ] || { echo 0; return; }
    echo $(( ($(date +%s) - newest) / 86400 ))
}

section "git worktrees under .claude/worktrees"
found=0
if git -C "$REPO" rev-parse --verify -q main >/dev/null; then
    wt=""; head=""
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
        "worktree "*) wt="${line#worktree }"; head="" ;;
        "HEAD "*) head="${line#HEAD }" ;;
        "")
            if [ -n "$wt" ] && [ -n "$head" ]; then
                case "$wt" in
                */.claude/worktrees/*)
                    found=1
                    dirty=$(git -C "$wt" status --porcelain 2>/dev/null | head -1 || true)
                    idle=$(idle_days "$wt")
                    if [ -n "$dirty" ]; then
                        note "worktree has uncommitted changes, keeping: $wt"
                    elif [ "$idle" -lt "$WORKTREE_IDLE_DAYS" ]; then
                        note "worktree used $idle day(s) ago, keeping (a session may still be on it): $wt"
                    elif is_merged "$head"; then
                        kb=$(kb_of "$wt"); TOTAL_KB=$((TOTAL_KB + kb))
                        if [ "$APPLY" = 1 ]; then
                            git -C "$REPO" worktree remove "$wt" && say "  removed worktree  $(human "$kb")  $wt"
                        else
                            say "  would remove worktree  $(human "$kb")  $wt  (merged, clean)"
                        fi
                    else
                        note "worktree not merged into main, keeping: $wt"
                    fi
                    ;;
                esac
            fi
            wt=""; head=""
            ;;
        esac
    done < <(git -C "$REPO" worktree list --porcelain; echo)
fi
[ "$found" = 1 ] || say "  none"

section "local branches already in main"
found=0
if git -C "$REPO" rev-parse --verify -q main >/dev/null; then
    checked_out=$(git -C "$REPO" worktree list --porcelain | sed -n 's|^branch refs/heads/||p')
    cur=$(git -C "$REPO" symbolic-ref -q --short HEAD || true)
    while IFS= read -r br; do
        [ -n "$br" ] && [ "$br" != "main" ] || continue
        found=1
        if [ "$br" = "$cur" ] || printf '%s\n' "$checked_out" | grep -qx -- "$br"; then
            note "branch is checked out somewhere, keeping: $br"
        elif is_merged "refs/heads/$br"; then
            if [ "$APPLY" = 1 ]; then git -C "$REPO" branch -D "$br" >/dev/null && say "  deleted branch  $br"
            else say "  would delete branch  $br  (nothing missing from main)"; fi
        else
            note "branch has commits not in main, keeping: $br"
        fi
    done < <(git -C "$REPO" for-each-ref --format='%(refname:short)' refs/heads)
fi
[ "$found" = 1 ] || say "  none"

section "scratch databases framestation_* in the dev Postgres"
if [ -x "$PSQL" ] && nc -z 127.0.0.1 "$PGPORT" 2>/dev/null; then
    dbs=$(PGCONNECT_TIMEOUT=3 "$PSQL" -h 127.0.0.1 -p "$PGPORT" -U framestation -d framestation -w -tAc \
        "select datname from pg_database where datname like 'framestation\_%' order by 1" 2>/dev/null || true)
    if [ -n "$dbs" ]; then
        while IFS= read -r db; do
            case "$db" in framestation_?*) ;; *) continue ;; esac
            [ "$db" != "framestation" ] || continue
            size=$(PGCONNECT_TIMEOUT=3 "$PSQL" -h 127.0.0.1 -p "$PGPORT" -U framestation -d framestation -w -tAc \
                "select pg_size_pretty(pg_database_size('$db'))" 2>/dev/null || echo "?")
            if [ "$APPLY" = 1 ]; then
                PGCONNECT_TIMEOUT=3 "$PSQL" -h 127.0.0.1 -p "$PGPORT" -U framestation -d framestation -w -qc "DROP DATABASE \"$db\"" \
                    && say "  dropped database  $size  $db"
            else
                say "  would drop database  $size  $db"
            fi
        done <<<"$dbs"
    else
        say "  none (or not reachable without a password)"
    fi
else
    say "  dev Postgres isn't running; skipped"
fi

section "dev server log"
if [ -f "$DEVLOG" ]; then
    size=$(stat -f %z "$DEVLOG" 2>/dev/null || echo 0)
    if [ "$size" -gt $((50 * 1024 * 1024)) ]; then
        kb=$((size / 1024)); TOTAL_KB=$((TOTAL_KB + kb))
        if [ "$APPLY" = 1 ]; then
            tail -n 20000 "$DEVLOG" > "$DEVLOG.1"; : > "$DEVLOG"
            say "  trimmed  $(human "$kb")  $DEVLOG  (last 20,000 lines kept in server.log.1)"
        else
            say "  would trim  $(human "$kb")  $DEVLOG  (keep last 20,000 lines in server.log.1)"
        fi
    else
        say "  server.log is $(human $((size / 1024))); under 50 MB"
    fi
else
    say "  none"
fi

section "orphan exiftool -stay_open processes (report only)"
found=0
while IFS= read -r l; do
    [ -n "$l" ] || continue
    ppid=$(awk '{print $1}' <<<"$l"); pid=$(awk '{print $2}' <<<"$l")
    if [ "$ppid" = 1 ]; then found=1; note "pid $pid has ppid 1: $(cut -c1-120 <<<"$l")"; fi
done < <(ps -axo ppid=,pid=,command= | grep 'exiftool' | grep -e '-stay_open' | grep -v grep || true)
[ "$found" = 1 ] || say "  none"

section "simulator folders not in device_set.plist (report only)"
found=0
if [ -d "$SIMDEVICES" ] && [ -f "$SIMDEVICES/device_set.plist" ]; then
    known=$(plutil -p "$SIMDEVICES/device_set.plist" 2>/dev/null | grep -Eo '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' | sort -u || true)
    for d in "$SIMDEVICES"/*/; do
        d="${d%/}"; id="$(basename "$d")"
        case "$id" in [0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F]-*) ;; *) continue ;; esac
        if ! printf '%s\n' "$known" | grep -qx "$id"; then
            found=1; note "$(human "$(kb_of "$d")")  $d"
        fi
    done
fi
[ "$found" = 1 ] || say "  none"

# ---------------------------------------------------------------- NAS checks

if [ "$NAS" = 1 ]; then
    section "NAS (ssh nas, read-only unless --apply)"
    # One remote script, run by sh. Prints "CAND<TAB>kb<TAB>path" for each
    # thing it would remove (removing it too when asked) and "NOTE<TAB>..." for
    # report-only items. No sudo anywhere.
    REMOTE=$(cat <<'REMOTE_SH'
APPLY="$1"
F=/volume1/docker/framestation
cand() {  # path
    [ -e "$1" ] || return 0
    kb=$(du -sk "$1" 2>/dev/null | cut -f1)
    printf 'CAND\t%s\t%s\n' "${kb:-0}" "$1"
    [ "$APPLY" = 1 ] && rm -rf -- "$1"
    return 0
}
D="$HOME/framestation-deploy"
if [ -d "$D" ]; then
    keep=$(ls -t "$D"/redeploy-*.sh 2>/dev/null | head -1)
    for f in "$D"/* "$D"/.[!.]*; do
        [ -e "$f" ] || continue
        [ "$f" = "$keep" ] && continue
        cand "$f"
    done
    [ -n "$keep" ] && printf 'KEEP\t%s\n' "$keep"
fi
if [ -d "$F" ]; then
    find "$F" -maxdepth 1 \( -name 'docker-compose.yml.before-*' -o -name 'pgdump-before-*.sql.gz' \) -mtime +7 2>/dev/null |
    while IFS= read -r f; do cand "$f"; done
fi
if [ -d "$F/derivatives" ]; then
    find "$F/derivatives" -name playback-1080.mp4 2>/dev/null |
    while IFS= read -r f; do
        d=$(dirname "$f")
        if [ -f "$d/stream-v1/master.m3u8" ] || [ -f "$d/stream-v2/master.m3u8" ]; then cand "$f"; fi
    done
fi
if [ -d "$F/incoming" ]; then
    find "$F/incoming" -mindepth 1 -maxdepth 1 -mtime +14 2>/dev/null |
    while IFS= read -r f; do
        kb=$(du -sk "$f" 2>/dev/null | cut -f1)
        printf 'NOTE\t%s\t%s\n' "${kb:-0}" "$f"
    done
fi
REMOTE_SH
)
    # ssh's own chatter (closed-connection and post-quantum warnings) is
    # dropped, and so is anything that could name the host.
    if out=$(ssh -o BatchMode=yes -o ConnectTimeout=10 nas "sh -s -- $APPLY" <<<"$REMOTE" 2>&1 | \
            grep -viE 'Connection to .* closed|post-quantum|not using a post|store now|upgraded|vulnerable|^\*\*|^$' ); then
        found=0
        while IFS="	" read -r kind a b; do
            case "$kind" in
            CAND) found=1; TOTAL_KB=$((TOTAL_KB + ${a:-0}))
                  [ "$APPLY" = 1 ] && say "  removed  $(human "${a:-0}")  $b" || say "  would remove  $(human "${a:-0}")  $b" ;;
            KEEP) say "  keeping newest redeploy script: $a" ;;
            NOTE) note "staging folder older than 14 days  $(human "${a:-0}")  $b" ;;
            "") ;;
            *) say "  nas: $kind${a:+ $a}${b:+ $b}" ;;
            esac
        done <<<"$out"
        [ "$found" = 1 ] || say "  nothing to remove on the NAS"
    else
        say "  couldn't run checks over ssh (key auth failed or NAS unreachable); skipped"
    fi
    echo
    say "  Sudo-only parts, for you to run yourself:"
    say "    ssh -t nas 'sudo ls -la /volume1/docker/framestation/backups && sudo /usr/local/bin/docker image prune -f'"
    say "  backups/ should keep only the newest pgdump-before-*.sql.gz (remove older ones with sudo rm)."
    say "  'docker image prune' is safe: GHCR keeps every image's sha tag for rollback."
fi

# ------------------------------------------------------------------- summary

echo
echo "== Summary"
if [ "$APPLY" = 1 ]; then say "  reclaimed about $(human "$TOTAL_KB")"
else say "  would reclaim about $(human "$TOTAL_KB")  (re-run with --apply)"; fi
[ "$REPORT_ONLY" -eq 0 ] || say "  $REPORT_ONLY item(s) reported for you to look at; none were touched"
