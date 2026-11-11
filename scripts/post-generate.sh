#!/bin/bash
# Runs after every `xcodegen generate` (see options.postGenCommand in project.yml).
#
# FREE_ACCOUNT=1 xcodegen generate
#   Builds without iCloud so the app can be signed with a free Apple ID (Personal Team), which
#   cannot sign the iCloud capability. The app then keeps its data (covers, reading progress,
#   settings) on the device instead of in iCloud Drive/Comic Reader; picking a comics folder in
#   iCloud Drive with the folder picker still works. Run plain `xcodegen generate` to turn iCloud
#   back on.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "${FREE_ACCOUNT:-0}" != "1" ]; then
  exit 0
fi

cat > App/ComicReader.entitlements <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
PLIST

plutil -remove NSUbiquitousContainers App/Info.plist 2>/dev/null || true

echo "FREE_ACCOUNT=1: generated without iCloud (data stays on the device)."
