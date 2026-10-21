#!/bin/zsh
set -eu
cd "${0:A:h}/.."
APP="${PHOTOSIGNAL_BUILD_APP:-$PWD/build/PhotoSignal.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp scripts/catalog.py "$APP/Contents/Resources/catalog.py"
cp scripts/profile_catalog.py "$APP/Contents/Resources/profile_catalog.py"
cp web/profile.html "$APP/Contents/Resources/profile.html"
cp scripts/cloud_index.py "$APP/Contents/Resources/cloud_index.py"
cp scripts/build_october_viewer.py "$APP/Contents/Resources/build_october_viewer.py"
cp web/october.html "$APP/Contents/Resources/october.html"
cp scripts/curate_photos.py "$APP/Contents/Resources/curate_photos.py"
cp scripts/interpret_search.py "$APP/Contents/Resources/interpret_search.py"
cp contracts/* "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PhotoSignal</string>
<key>CFBundleIdentifier</key><string>local.photosignal.reader</string>
<key>CFBundleName</key><string>PhotoSignal</string>
<key>CFBundleVersion</key><string>1</string>
<key>NSPhotoLibraryUsageDescription</key><string>Index Photos metadata and previews on this Mac. The optional AI index sends rendered previews to Fireworks when you start it. Create Photos albums when requested.</string>
</dict></plist>
PLIST
PHOTOSIGNAL_STAGE=$(mktemp -d "${TMPDIR:-/tmp}/photosignal-build.XXXXXX")
trap 'rm -rf "$PHOTOSIGNAL_STAGE"' EXIT
cp Sources/*.swift "$PHOTOSIGNAL_STAGE/"
swiftc "$PHOTOSIGNAL_STAGE"/*.swift -o "$APP/Contents/MacOS/PhotoSignal" -framework Cocoa -framework Photos -framework Vision -framework WebKit
xattr -cr "$APP"
for attempt in 1 2 3; do
  xattr -cr "$APP"
  if codesign --force --sign - "$APP"; then break; fi
  if [[ "$attempt" == 3 ]]; then exit 1; fi
done
print "Built $APP"
