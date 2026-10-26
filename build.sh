#!/bin/bash
# Builds build/Mandarina.app from Sources/.
#
#   ./build.sh                 ad-hoc signature, what a release uses
#   MANDARINA_SIGN_IDENTITY="Developer ID Application: …" ./build.sh
#
# Signing with your own identity keeps the Automation permission across
# rebuilds while you develop; a release stays ad-hoc unless you pass an
# identity, because a shared repo cannot carry anyone's certificate.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
version=$(tr -d ' \n' < "$here/VERSION")
build=${MANDARINA_BUILD:-$(date +%s)}
app="$here/build/Mandarina.app"
identity=${MANDARINA_SIGN_IDENTITY:--}

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

swiftc -O -swift-version 5 \
  -target arm64-apple-macos13.0 \
  -framework AppKit -framework ApplicationServices \
  "$here"/Sources/*.swift \
  -o "$app/Contents/MacOS/Mandarina"

sed -e "s/@VERSION@/$version/g" -e "s/@BUILD@/$build/g" \
  "$here/Resources/Info.plist" > "$app/Contents/Info.plist"

if [ -f "$here/Resources/AppIcon.icns" ]; then
  cp "$here/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
fi
printf 'APPL????' > "$app/Contents/PkgInfo"

codesign --force --sign "$identity" --timestamp=none \
  --identifier app.mandarina.desktop "$app" >/dev/null
codesign --verify --strict "$app"
echo "built $app $version with identity: $identity"
