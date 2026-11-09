#!/bin/sh
# Builds build/Merlin.app (release, ad-hoc signed). Needs only the Xcode
# Command Line Tools. Usage: ./build-app.sh [--install]  (--install copies it
# to /Applications)
set -e
cd "$(dirname "$0")"

swift build -c release --product Merlin
bin="$(swift build -c release --show-bin-path)/Merlin"

app=build/Merlin.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Merlin"
cp Resources/Info.plist "$app/Contents/Info.plist"

iconset=build/AppIcon.iconset
rm -rf "$iconset"
swift Resources/make-icon.swift "$iconset"
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
rm -rf "$iconset"

# Ad-hoc signature: enough for Location Services to remember the permission.
codesign --force --sign - --timestamp=none "$app"
echo "Built $(pwd)/$app"

if [ "$1" = "--install" ]; then
  rm -rf /Applications/Merlin.app
  cp -R "$app" /Applications/
  echo "Installed /Applications/Merlin.app"
fi
