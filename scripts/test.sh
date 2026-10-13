#!/bin/sh
# Runs the unit tests. Command Line Tools ship the Swift Testing macro plugin in a subfolder
# the compiler doesn't search by default, so point it there (Xcode finds it on its own).
cd "$(dirname "$0")/.."
PLUGINS="$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins/testing"
if [ -d "$PLUGINS" ]; then exec swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"; fi
exec swift test "$@"
