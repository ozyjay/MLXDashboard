#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="MLXDashboard.app"
PACKAGED_APP="$ROOT/dist/$APP_NAME"
INSTALL_DIR="$HOME/Applications"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME"

"$ROOT/scripts/package-app.sh" >/dev/null

if [[ ! -d "$PACKAGED_APP" ]]; then
  echo "Packaged app not found: $PACKAGED_APP" >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALLED_APP"
cp -R "$PACKAGED_APP" "$INSTALLED_APP"

echo "$INSTALLED_APP"
