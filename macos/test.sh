#!/bin/sh
# Runs the core tests. With only the Command Line Tools installed, SwiftPM
# doesn't find the swift-testing macro plugin by itself: point it there.
set -e
cd "$(dirname "$0")"
plugins="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
if [ -d "$plugins" ]; then
  exec swift test -Xswiftc -plugin-path -Xswiftc "$plugins" "$@"
fi
exec swift test "$@"
