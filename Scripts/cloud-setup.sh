#!/bin/bash
# Setup script for the Claude Code cloud environment this repository is worked
# on in. It lives here so it is versioned and reviewed; the copy that actually
# runs is the one pasted into the environment's settings (claude.ai/code →
# environment menu → settings → Setup script). Paste it again after changing it.
#
# Installs Swift the way swift.org documents for Linux: swiftly, Swift's own
# toolchain manager, which checks each toolchain's signature against swift.org's
# keys. swiftly itself is checked against the same keys before it runs.
#
# SWIFT_VERSION must match .swift-version. Inside the repository swiftly obeys
# that file, so a version bump the environment hasn't caught up with stops with
# a clear "run swiftly install" rather than building with the wrong compiler.
#
# A setup script that fails stops sessions from starting, so this one always
# exits 0 and says in its output why Swift is missing if it didn't install.
SWIFT_VERSION=6.4.0

# The steps run in a `bash -e` of their own. Written inline and followed by
# `|| echo …`, a failed step would not stop them: bash ignores `set -e` inside
# any command whose exit status is being tested.
read -r -d '' INSTALL_SWIFT <<'STEPS'
work="$(mktemp -d)"
arch="$(uname -m)"
cd "$work"

export GNUPGHOME="$work/gnupg"
mkdir -m 700 "$GNUPGHOME"
curl -fsSL https://www.swift.org/keys/all-keys.asc | gpg --batch --quiet --import
curl -fsSLO "https://download.swift.org/swiftly/linux/swiftly-$arch.tar.gz"
curl -fsSLO "https://download.swift.org/swiftly/linux/swiftly-$arch.tar.gz.sig"
gpg --batch --verify "swiftly-$arch.tar.gz.sig" "swiftly-$arch.tar.gz"
tar zxf "swiftly-$arch.tar.gz"

# Named rather than left to swiftly, which takes its home from the passwd entry
# while the shell takes it from $HOME; the two needn't agree.
export SWIFTLY_HOME_DIR="$HOME/.local/share/swiftly"
export SWIFTLY_BIN_DIR="$SWIFTLY_HOME_DIR/bin"
./swiftly init --assume-yes --quiet-shell-followup --skip-install
. "$SWIFTLY_HOME_DIR/env.sh"

# swiftly lists the system packages a toolchain needs in a script rather than
# installing them itself, and exits non-zero when it wrote one.
swiftly install "$SWIFT_VERSION" --assume-yes --use --post-install-file "$work/post-install.sh" \
  || [ -s "$work/post-install.sh" ]
if [ -s "$work/post-install.sh" ]; then
  apt-get update -qq
  bash "$work/post-install.sh"
fi
swift --version
STEPS

if ! SWIFT_VERSION="$SWIFT_VERSION" bash -euo pipefail -c "$INSTALL_SWIFT"; then
  echo "Swift $SWIFT_VERSION was not installed; the output above says why."
fi
exit 0
