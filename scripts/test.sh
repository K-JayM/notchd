#!/bin/sh
# Runs the unit tests. Command Line Tools ship the Swift Testing macro plugin in a subfolder
# the compiler doesn't search by default, so point it there.
cd "$(dirname "$0")/.."
PLUGINS="$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins/testing"
exec swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
