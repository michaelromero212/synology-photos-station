#!/bin/bash
# Checks that the App Review server reaches nothing but its own database: not
# DSM, not the family's server, not the LAN, not the internet. It tries each
# from inside the running server, so it tests the real thing. See APP-REVIEW.md.
#
# Run as root from the demo's own folder, once the demo is up:
#
#   cd /volume1/docker/framestation-demo && sudo bash demo-isolation-check.sh
#
# Exits non-zero if anything was reachable, or if the demo itself wasn't.
set -uo pipefail
# DSM's sudo leaves /usr/local/bin off the PATH, and that's where docker is.
export PATH="/usr/local/bin:$PATH"
cd "$(dirname "$0")"

[ "$(id -u)" = 0 ] || { echo "Run with sudo: Docker on DSM needs root." >&2; exit 2; }

compose(){ docker compose --project-directory "$(pwd)" "$@"; }
# The HTTP status the server got from a URL, or 000 if it couldn't connect.
from_server(){ compose exec -T server curl -sk -m 5 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || true; }

# The NAS as the containers see it: Docker's default bridge, and its LAN
# address. Either one would lead to DSM, SSH, file sharing and the family's
# server behind DSM's reverse proxy.
BRIDGE=$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null)
LAN=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')

failed=0
echo "From inside the demo server:"

code=$(from_server http://127.0.0.1:8080/health)
if [ "$code" = 200 ]; then
  echo "  answers on its own port"
else
  echo "  ✗ the server didn't answer on its own port ($code); is the demo up?"
  failed=1
fi

check(){
  code=$(from_server "$2")
  if [ "${code:-000}" = 000 ]; then
    echo "  blocked: $1"
  else
    echo "  ✗ REACHABLE ($code): $1"
    failed=1
  fi
}
check "DSM, through Docker's bridge" "http://${BRIDGE:-172.17.0.1}:5000/"
[ -n "$LAN" ] && check "DSM, at the NAS's LAN address" "http://$LAN:5000/"
[ -n "$LAN" ] && check "DSM's reverse proxy and the family's server behind it" "https://$LAN:8443/"
check "the internet" "https://www.apple.com/"

echo "From the NAS, the way DSM's reverse proxy reaches it:"
if curl -sf -m 5 -o /dev/null http://127.0.0.1:8081/health; then
  echo "  answers on 127.0.0.1:8081"
else
  echo "  ✗ nothing answered on 127.0.0.1:8081"
  failed=1
fi

if [ "$failed" = 0 ]; then
  echo "Isolated: the demo server can reach its own database and nothing else."
else
  echo "Not isolated, or not up. See the ✗ lines above." >&2
fi
exit "$failed"
