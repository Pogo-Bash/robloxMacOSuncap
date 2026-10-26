#!/bin/bash
# Installs Uncapped.app from the latest GitHub release.
#   curl -fsSL https://raw.githubusercontent.com/Pogo-Bash/robloxMacOSuncap/main/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --uninstall
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail

REPO="${UNCAPPED_REPO:-Pogo-Bash/robloxMacOSuncap}" 
URL="https://github.com/$REPO/releases/latest/download/Uncapped.zip"

say()  { printf '\033[1;32m[uncapped]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[uncapped]\033[0m %s\n' "$*"; exit 1; }

[[ "$(uname)" == "Darwin" ]] || fail "Uncapped only runs on macOS."
major="$(sw_vers -productVersion | cut -d. -f1)"
(( major >= 14 )) || fail "macOS 14 or newer is required."

# /Applications if we can write to it, otherwise ~/Applications (no password needed).
if [[ -w /Applications ]]; then DEST=/Applications; else DEST="$HOME/Applications"; mkdir -p "$DEST"; fi
APP="$DEST/Uncapped.app"

if [[ "${1:-}" == "--uninstall" ]]; then
    [[ -x "$APP/Contents/Resources/uncapped.sh" ]] && "$APP/Contents/Resources/uncapped.sh" --restore || true
    rm -rf "$APP"
    say "Uninstalled. Roblox is back to normal."
    exit 0
fi

[[ -d /Applications/Roblox.app ]] || say "Note: Roblox isn't installed yet. Get it from roblox.com before launching Uncapped."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

say "Downloading the latest release"
curl -fsSL "$URL" -o "$tmp/Uncapped.zip" || fail "Download failed: $URL"
ditto -x -k "$tmp/Uncapped.zip" "$tmp"
[[ -d "$tmp/Uncapped.app" ]] || fail "The release archive didn't contain Uncapped.app."

rm -rf "$APP"
ditto "$tmp/Uncapped.app" "$APP"
xattr -cr "$APP" 2>/dev/null || true
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

say "Installed to $APP"
say "Open Uncapped from Launchpad or Spotlight whenever you want to play."
open "$APP"
