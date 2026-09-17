#!/bin/bash
#
# The local test stack: Postgres and the server, kept alive by launchd.
#
# Why this exists. Both processes used to be foreground commands typed into a
# terminal, which meant the stack died with the window, died on reboot, and did
# not come back after a crash — so "why can't the simulator connect?" became a
# recurring question with a different answer every time. It is also how the port
# drifted: nothing wrote 8099 down, so the app ended up dialling 8098 and the
# grid blamed the NAS for it.
#
# The isolation guarantee. Both services bind loopback ONLY. Not a preference —
# it is the reason a test server can never be reached by the real iPhone, and
# therefore the reason testing here cannot disturb the family library on the
# NAS. Do not "temporarily" bind 0.0.0.0 to try something from a phone; install
# the dev build on the simulator instead, or point it at the NAS deliberately.
#
# Secrets live in ~/.framestation-dev/env (mode 600, outside the repo), not
# here and not in the generated launchd plists — the server agent sources that
# file at launch instead.
#
#   Scripts/devstack.sh install     generate + load both agents
#   Scripts/devstack.sh restart     restart the server (after a rebuild)
#   Scripts/devstack.sh status      what is running, and is it answering
#   Scripts/devstack.sh logs        tail both logs
#   Scripts/devstack.sh uninstall   unload + remove the agents
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA="$HOME/.framestation-dev"
PGDATA="$DATA/pgdata"
SOCK="$DATA/sock"
LOGS="$DATA/logs"
ENVFILE="$DATA/env"

PGPORT=55432
SRVPORT=8099
# Asked for rather than assumed.
#
# This was the literal path `.build/arm64-apple-macosx/debug/FrameStationServer`,
# which the toolchain stopped writing to: newer Swift builds land in
# `.build/out/Products/Debug`. Nothing failed. `swift build` said "Build
# complete", the agent kept launching the file that was still sitting at the old
# path, and the dev server went on serving a build from six days earlier — so a
# new endpoint answered 404 and a changed query returned the old answer, both
# silently, while every local check appeared to pass.
#
# `--show-bin-path` is the toolchain's own answer to "where did you put it", so
# this cannot drift again. The fallback keeps the script working if SwiftPM
# can't answer.
SRVBIN="$( (cd "$REPO/Server" && swift build --show-bin-path 2>/dev/null) )/FrameStationServer"
[ -x "$SRVBIN" ] || SRVBIN="$REPO/Server/.build/arm64-apple-macosx/debug/FrameStationServer"
# The version-stable symlink, not the Cellar path — a Homebrew upgrade must not
# silently leave launchd pointing at a directory that no longer exists.
PGBIN="/opt/homebrew/opt/postgresql@16/bin/postgres"

LABEL_DB="dev.framestation.postgres"
LABEL_SRV="dev.framestation.server"
AGENTS="$HOME/Library/LaunchAgents"
DOMAIN="gui/$(id -u)"

die() { echo "error: $*" >&2; exit 1; }

write_plists() {
    mkdir -p "$AGENTS" "$LOGS" "$SOCK"

    cat > "$AGENTS/$LABEL_DB.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL_DB</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PGBIN</string>
    <string>-D</string><string>$PGDATA</string>
    <string>-p</string><string>$PGPORT</string>
    <string>-k</string><string>$SOCK</string>
    <!-- Loopback only. See the note at the top of devstack.sh. -->
    <string>-c</string><string>listen_addresses=127.0.0.1</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <!-- Postgres refuses to start under a locale it cannot resolve, and
         launchd's environment is far barer than a login shell's. -->
    <key>LC_ALL</key><string>C</string>
    <key>LANG</key><string>C</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$LOGS/postgres.log</string>
  <key>StandardErrorPath</key><string>$LOGS/postgres.log</string>
</dict>
</plist>
PLIST

    # `sh -c` rather than exec'ing the binary directly, so the environment file
    # is read at launch. Keeping the values there rather than inlining them into
    # this plist means one private file to protect instead of two, and editing
    # the database URL doesn't mean regenerating launchd config.
    cat > "$AGENTS/$LABEL_SRV.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL_SRV</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>-c</string>
    <string>set -a; . "$ENVFILE"; set +a; exec "$SRVBIN" serve --hostname 127.0.0.1 --port $SRVPORT</string>
  </array>
  <key>WorkingDirectory</key><string>$REPO/Server</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <!-- Long enough that a server which cannot reach Postgres yet backs off
       instead of hot-looping while the database finishes starting. launchd has
       no ordering between agents, so retrying *is* the dependency mechanism. -->
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$LOGS/server.log</string>
  <key>StandardErrorPath</key><string>$LOGS/server.log</string>
</dict>
</plist>
PLIST
}

# The server refuses to boot without its blob root and exits, which under
# `KeepAlive` becomes a crash loop rather than a visible failure — the stack
# looks "loaded" while nothing answers.
#
# This bit us for real: the blob root lived in /tmp, macOS clears /tmp on
# reboot, and the launchd agents dutifully came back to storage that no longer
# existed. Recreating it here means a reboot can cost you the cached blobs but
# never the stack itself. Keep the blob root somewhere durable and it costs you
# neither.
check_paths() {
    local blobs geonames
    blobs=$(sed -n 's/^FRAMESTATION_BLOB_ROOT=//p' "$ENVFILE" | tr -d '"')
    geonames=$(sed -n 's/^FRAMESTATION_GEONAMES_DIR=//p' "$ENVFILE" | tr -d '"')

    case "$blobs" in
        /tmp/*|/private/tmp/*)
            echo "  warning: blob root is under /tmp, which macOS clears on reboot" >&2
            echo "           uploaded media will not survive a restart: $blobs" >&2
            ;;
    esac
    [ -n "$blobs" ] && mkdir -p "$blobs" && echo "  blob root ok: $blobs"
    if [ -n "$geonames" ] && [ ! -d "$geonames" ]; then
        # Not fatal — place names simply stay empty without it.
        echo "  warning: geonames dir missing, reverse geocoding will be inert: $geonames" >&2
    fi
}

stop_strays() {
    # Anything started by hand before this script existed. Left running it would
    # hold the port and launchd's copy would crash-loop against it.
    pkill -f "FrameStationServer serve" 2>/dev/null && echo "  stopped a hand-started server" || true
    if [ -d "$PGDATA" ] && "$(dirname "$PGBIN")/pg_ctl" -D "$PGDATA" status >/dev/null 2>&1; then
        LC_ALL=C "$(dirname "$PGBIN")/pg_ctl" -D "$PGDATA" stop -m fast >/dev/null 2>&1 \
            && echo "  stopped a hand-started postgres" || true
    fi
    sleep 1
}

case "${1:-}" in
install)
    [ -x "$PGBIN" ] || die "postgres not found at $PGBIN"
    [ -x "$SRVBIN" ] || die "server not built — run: (cd Server && swift build)"
    [ -f "$ENVFILE" ] || die "missing $ENVFILE (FRAMESTATION_* vars, one per line)"
    [ -d "$PGDATA" ] || die "no database at $PGDATA"
    check_paths

    echo "stopping anything already running…"
    stop_strays
    write_plists
    for label in "$LABEL_DB" "$LABEL_SRV"; do
        launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
        launchctl bootstrap "$DOMAIN" "$AGENTS/$label.plist"
        echo "  loaded $label"
    done
    echo "waiting for health…"
    # Generous: the server loads ~170k geonames places before it listens,
    # and a short wait reported a false failure on a server that was fine.
    for _ in $(seq 1 60); do
        sleep 1
        if curl -fsS -m 2 "http://127.0.0.1:$SRVPORT/health" >/dev/null 2>&1; then
            echo "stack is up on http://127.0.0.1:$SRVPORT"; exit 0
        fi
    done
    die "came up but /health never answered — check $LOGS/server.log"
    ;;

restart)
    # After `swift build`: a running process keeps executing the image it
    # started with, so a rebuilt binary does nothing until the process is
    # replaced. This is that step.
    launchctl kickstart -k "$DOMAIN/$LABEL_SRV"
    # Generous: the server loads ~170k geonames places before it listens,
    # and a short wait reported a false failure on a server that was fine.
    for _ in $(seq 1 60); do
        sleep 1
        curl -fsS -m 2 "http://127.0.0.1:$SRVPORT/health" >/dev/null 2>&1 && {
            echo "server restarted on :$SRVPORT"; exit 0; }
    done
    die "did not come back — check $LOGS/server.log"
    ;;

status)
    for label in "$LABEL_DB" "$LABEL_SRV"; do
        if launchctl print "$DOMAIN/$label" >/dev/null 2>&1; then
            pid=$(launchctl print "$DOMAIN/$label" | awk '/^\tpid = /{print $3}')
            echo "$label: loaded${pid:+, pid $pid}"
        else
            echo "$label: NOT loaded"
        fi
    done
    nc -z 127.0.0.1 $PGPORT 2>/dev/null && echo "postgres :$PGPORT listening" || echo "postgres :$PGPORT DOWN"
    code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" "http://127.0.0.1:$SRVPORT/health" || true)
    [ "$code" = "200" ] && echo "server :$SRVPORT healthy" || echo "server :$SRVPORT unhealthy (HTTP ${code:-none})"
    echo
    echo "simulator app connects with:"
    echo "  -FSServerURL http://127.0.0.1:$SRVPORT"
    ;;

logs)
    tail -n 40 -f "$LOGS/server.log" "$LOGS/postgres.log"
    ;;

uninstall)
    for label in "$LABEL_SRV" "$LABEL_DB"; do
        launchctl bootout "$DOMAIN/$label" 2>/dev/null && echo "  unloaded $label" || true
        rm -f "$AGENTS/$label.plist"
    done
    echo "agents removed. Data left alone at $DATA"
    ;;

*)
    sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
