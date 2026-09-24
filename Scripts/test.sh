#!/bin/bash
# Runs the test suite. The build folder is kept outside iCloud Drive (~/Documents), because
# Finder metadata added there makes codesign reject the test bundle.
set -euo pipefail
cd "$(dirname "$0")/.."
exec swift test --scratch-path "${TMPDIR:-/tmp}/VideoCleaner-build" "$@"
