#!/bin/bash
# Picks the newest Xcode 26 on a GitHub macOS runner.
set -euo pipefail
XCODE=$(ls -d /Applications/Xcode_26*.app 2>/dev/null | sort -V | tail -1 || true)
if [ -z "$XCODE" ]; then XCODE=$(ls -d /Applications/Xcode*.app | sort -V | tail -1); fi
echo "Using $XCODE"
sudo xcode-select -s "$XCODE/Contents/Developer"
xcodebuild -version
