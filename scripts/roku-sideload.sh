#!/usr/bin/env bash
# Runs on: Mac (same LAN as the Roku). Packages and installs the dev channel.
# Usage: ROKU_IP=192.168.4.x scripts/roku-sideload.sh
# Prompts for the Developer Mode password (user is always "rokudev"), unless ROKU_PASS is set.
set -euo pipefail
: "${ROKU_IP:?set ROKU_IP}"
if [ -z "${ROKU_PASS:-}" ]; then
  read -rsp "Roku dev password: " ROKU_PASS
  echo
fi
[ -n "$ROKU_PASS" ] || { echo "Empty password." >&2; exit 1; }
cd "$(dirname "$0")/.."
zip=$(scripts/roku-package.sh)
curl -sS --fail --digest -u "rokudev:${ROKU_PASS}" \
  -F "mysubmit=Install" -F "archive=@${zip}" \
  "http://${ROKU_IP}/plugin_install" | grep -oE "Install Success|Identical to previous version|Install Failure[^<]*" || true
echo "Debug console: nc ${ROKU_IP} 8085"
