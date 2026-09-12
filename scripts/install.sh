#!/usr/bin/env bash
# Build ps2mc in release mode and install it to a stable path.
#
# The install path matters more than usual here: macOS pins Input Monitoring and
# Accessibility grants to a specific binary path, so a driver that lives in .build/debug
# loses its permissions on every rebuild. Installing once to /usr/local/bin means the
# grants stick.
set -euo pipefail

PREFIX="${PREFIX:-/usr/local}"
BIN_DIR="$PREFIX/bin"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$REPO_ROOT"

echo "==> Building (release)"
swift build -c release

BUILT="$(swift build -c release --show-bin-path)/ps2mc"
[ -x "$BUILT" ] || { echo "build did not produce $BUILT" >&2; exit 1; }

echo "==> Verifying the build"
"$BUILT" selftest

echo "==> Installing to $BIN_DIR/ps2mc"
# Try unprivileged first. Testing -w on $BIN_DIR alone is not enough: when the directory
# does not exist yet the test fails and we would escalate to sudo needlessly.
if mkdir -p "$BIN_DIR" 2>/dev/null && [ -w "$BIN_DIR" ]; then
  install -m 0755 "$BUILT" "$BIN_DIR/ps2mc"
else
  echo "    (needs sudo to write $BIN_DIR)"
  sudo install -d "$BIN_DIR"
  sudo install -m 0755 "$BUILT" "$BIN_DIR/ps2mc"
fi

cat <<EOF

Installed: $BIN_DIR/ps2mc

Next:
  ps2mc permissions    grant Input Monitoring and Accessibility
  ps2mc calibrate      teach it your pad's button order
  ps2mc monitor        confirm sticks and buttons read correctly
  ps2mc run            play

If $BIN_DIR is not on your PATH, add it:
  echo 'export PATH="$BIN_DIR:\$PATH"' >> ~/.zshrc
EOF
