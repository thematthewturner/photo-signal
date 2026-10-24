#!/bin/zsh
# Two apps, one shared local catalog; no runtime data enters the bundles.
set -eu
cd "${0:A:h}/.."
OUT="${PHOTOSIGNAL_PRODUCTS_DIR:-$PWD/build/products}"
mkdir -p "$OUT"
PHOTOSIGNAL_BUILD_APP="$OUT/Photo Signal.app" zsh scripts/build.sh
ICON_STAGE=$(mktemp -d "${TMPDIR:-/tmp}/photosignal-icons.XXXXXX")
swift tools/AppIcon.swift "$ICON_STAGE/viewer.iconset"
iconutil -c icns "$ICON_STAGE/viewer.iconset" -o "$OUT/Photo Signal.app/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon' "$OUT/Photo Signal.app/Contents/Info.plist"
xattr -cr "$OUT/Photo Signal.app"
codesign --force --sign - "$OUT/Photo Signal.app"
AGENT="$OUT/Photo Signal Indexer.app"
mkdir -p "$AGENT/Contents/MacOS" "$AGENT/Contents/Resources"
cp "$OUT/Photo Signal.app/Contents/Resources/"* "$AGENT/Contents/Resources/"
cp "$OUT/Photo Signal.app/Contents/Info.plist" "$AGENT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.photosignal.indexer' "$AGENT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Photo Signal Indexer' "$AGENT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' "$AGENT/Contents/Info.plist"
swift tools/AppIcon.swift "$ICON_STAGE/indexer.iconset" --indexer
iconutil -c icns "$ICON_STAGE/indexer.iconset" -o "$AGENT/Contents/Resources/AppIcon.icns"
rm -rf "$ICON_STAGE"
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/photosignal-agent.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
for source in Sources/*.swift; do
  if [[ "$source" != Sources/main.swift ]]; then cp "$source" "$STAGE/"; fi
done
cp Agent/main.swift "$STAGE/main.swift"
swiftc "$STAGE"/*.swift -o "$AGENT/Contents/MacOS/PhotoSignal" -framework Cocoa -framework Photos -framework Vision -framework WebKit -framework CryptoKit
xattr -cr "$AGENT"
for attempt in 1 2 3; do
  xattr -cr "$AGENT"
  if codesign --force --sign - "$AGENT"; then break; fi
  if [[ "$attempt" == 3 ]]; then exit 1; fi
done
print "Built both apps in $OUT"
