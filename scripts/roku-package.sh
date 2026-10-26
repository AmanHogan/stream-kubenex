#!/usr/bin/env bash
# Runs on: Mac. Zips the Roku channel into build/stream-kubenex-roku.zip.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
rm -f build/stream-kubenex-roku.zip
(cd roku && zip -qr ../build/stream-kubenex-roku.zip manifest source components images)
echo "build/stream-kubenex-roku.zip"
