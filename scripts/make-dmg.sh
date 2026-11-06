#!/bin/zsh
# Builds "ARM Sim.app" and packs it into build/ARM-Sim-<version>-macOS.dmg
# (drag-to-Applications layout). Usage: scripts/make-dmg.sh <version>, e.g. v0.1.1
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${1:?usage: make-dmg.sh <version>}

./scripts/make-app.sh

STAGE=build/dmg
DMG="build/ARM-Sim-$VERSION-macOS.dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "build/ARM Sim.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "ARM Sim $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Created $DMG"
