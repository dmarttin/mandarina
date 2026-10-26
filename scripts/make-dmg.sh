#!/bin/bash
# Packages build/Mandarina.app into dist/Mandarina-<version>.dmg.
# Run ./build.sh first, or let this script do it.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
version=$(tr -d ' \n' < "$here/VERSION")
app="$here/build/Mandarina.app"
dist="$here/dist"

[ -d "$app" ] || "$here/build.sh"

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Mandarina.app"
ln -s /Applications "$stage/Applications"

mkdir -p "$dist"
dmg="$dist/Mandarina-$version.dmg"
rm -f "$dmg"

# diskutil replaced hdiutil in macOS 26; keep the old call for older runners.
if diskutil image create from 2>&1 | grep -q "USAGE"; then
  diskutil image create from --format UDZO --volumeName Mandarina "$stage" "$dmg" >/dev/null
else
  hdiutil create -volname "Mandarina" -srcfolder "$stage" \
    -fs HFS+ -format UDZO -ov "$dmg" >/dev/null
fi

(cd "$dist" && shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg").sha256")
echo "packaged $dmg ($(du -h "$dmg" | cut -f1))"
