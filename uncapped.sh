#!/bin/bash
# uncapped — launch Roblox on macOS without the 120 Hz / 240 fps caps.
# SPDX-License-Identifier: GPL-3.0-only
#
#   ./uncapped.sh            set things up and launch
#   ./uncapped.sh --restore  put the frame cap back to 240 and delete the staged copy
#
# Environment: UNCAPPED_FPS (default 1000), UNCAPPED_OVERLAY=0, ROBLOX_APP.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DYLIB="${UNCAPPED_DYLIB:-$HERE/build/uncapped.dylib}"
SRC_APP="${ROBLOX_APP:-/Applications/Roblox.app}"
STAGE_DIR="$HOME/Library/Application Support/uncapped"
STAGED_APP="$STAGE_DIR/Roblox.app"
STAMP="$STAGE_DIR/.staged-version"
SETTINGS="$HOME/Library/Roblox/GlobalBasicSettings_13.xml"
LOG="$HOME/Library/Logs/uncapped.log"
FPS="${UNCAPPED_FPS:-1000}"

say()  { printf '\033[1;32m[uncapped]\033[0m %s\n' "$*"; }
# Started from the app (no terminal): show errors as a dialog instead.
fail() {
    printf '\033[1;31m[uncapped]\033[0m %s\n' "$*"
    if [[ ! -t 1 ]]; then
        /usr/bin/osascript -e "display dialog \"$*\" with title \"Uncapped\" buttons {\"OK\"} default button 1 with icon caution" >/dev/null 2>&1 || true
    fi
    exit 1
}

set_cap() {   # $1 = value
    [[ -f "$SETTINGS" ]] || { say "No Roblox settings file yet (launch Roblox normally once). Skipping cap edit."; return; }
    [[ -f "$SETTINGS.uncapped-backup" ]] || cp "$SETTINGS" "$SETTINGS.uncapped-backup"
    sed -i '' "s#<int name=\"FramerateCap\">[0-9-]*</int>#<int name=\"FramerateCap\">$1</int>#" "$SETTINGS"
    say "Roblox frame cap set to $1"
}

quit_roblox() {
    if pgrep -x RobloxPlayer >/dev/null; then
        say "Closing running Roblox"
        pkill -x RobloxPlayer || true
        sleep 2
    fi
}

if [[ "${1:-}" == "--restore" ]]; then
    quit_roblox
    set_cap 240
    rm -rf "$STAGE_DIR"
    say "Restored. Your normal Roblox app was never modified."
    exit 0
fi

[[ "$(uname)" == "Darwin" ]] || fail "This only runs on macOS."
[[ -d "$SRC_APP" ]] || fail "Roblox not found at $SRC_APP. Install it from roblox.com first."

# 1. Get the dylib: prebuilt from a release, or build it.
if [[ ! -f "$DYLIB" ]]; then
    if xcrun --find clang >/dev/null 2>&1; then
        say "Building (first run only)"
        make -C "$HERE" >/dev/null
    else
        say "Apple's command line tools are needed to build. Starting the installer..."
        xcode-select --install 2>/dev/null || true
        fail "Run this again once the install finishes. (Or download a release, which includes a prebuilt build.)"
    fi
fi
xattr -c "$DYLIB" 2>/dev/null || true

quit_roblox

# 2. Lift Roblox's own frame cap.
set_cap "$FPS"

# 3. Stage an ad-hoc signed copy (only when Roblox updates).
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SRC_APP/Contents/Info.plist")"
if [[ ! -d "$STAGED_APP" || "$(cat "$STAMP" 2>/dev/null)" != "$version" ]]; then
    say "Preparing Roblox $version (takes a moment after each Roblox update)"
    [[ -t 1 ]] || /usr/bin/osascript -e 'display notification "Preparing Roblox, this takes a moment after each update." with title "Uncapped"' >/dev/null 2>&1 || true
    mkdir -p "$STAGE_DIR"
    rm -rf "$STAGED_APP"
    ditto "$SRC_APP" "$STAGED_APP"
    xattr -cr "$STAGED_APP"
    codesign --force --deep --sign - "$STAGED_APP" 2>/dev/null
    echo "$version" > "$STAMP"
fi

# 4. Launch, detached so this window can be closed.
say "Launching Roblox (target $FPS fps). Log: $LOG"
DYLD_INSERT_LIBRARIES="$DYLIB" UNCAPPED_FPS="$FPS" \
    nohup "$STAGED_APP/Contents/MacOS/RobloxPlayer" "$@" >"$LOG" 2>&1 &
disown
say "Done. You can close this window."
