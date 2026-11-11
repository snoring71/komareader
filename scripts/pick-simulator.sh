#!/bin/bash
# Prints the UDID of an available iPad simulator on the newest iOS runtime (prefers iPad Pro 13-inch).
set -euo pipefail
xcrun simctl list devices available --json | python3 -c '
import json, sys, re
data = json.load(sys.stdin)["devices"]
def ver(rt):
    m = re.search(r"iOS-(\d+)-(\d+)", rt)
    return (int(m.group(1)), int(m.group(2))) if m else (0, 0)
runtimes = sorted((rt for rt in data if "iOS" in rt and ver(rt)[0] >= 26), key=ver, reverse=True)
for rt in runtimes:
    ipads = [d for d in data[rt] if d["name"].startswith("iPad")]
    if ipads:
        pro13 = [d for d in ipads if "Pro" in d["name"] and "13" in d["name"]]
        print((pro13 or ipads)[0]["udid"]); sys.exit(0)
sys.exit("No iPad simulator with iOS 26 or later")
'
