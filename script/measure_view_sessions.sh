#!/usr/bin/env bash
# Measures View Session latency and memory over the real Plugin helper (W13
# #60) and keeps every raw sample, as ADR 0007 requires. It builds the release
# configuration and passes its arguments on, so for the recorded run:
#
#   ./script/measure_view_sessions.sh --machine-idle yes
#
# on a quiet machine on AC power, with nothing else running. `--quick` is a
# short trial; `app-footprint` samples a running Spinnet app while you open
# the Typing Probe view by hand. `--help` lists the rest.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${SPINNET_MEASURE_CONFIGURATION:-release}"

cd "$ROOT_DIR"
swift build -c "$CONFIGURATION" --product SpinnetPluginHelper
swift build -c "$CONFIGURATION" --product SpinnetViewSessionMeasurement
BUILD_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

REVISION="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [[ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
    REVISION="$REVISION with uncommitted changes"
fi

exec "$BUILD_DIR/SpinnetViewSessionMeasurement" \
    --helper "$BUILD_DIR/SpinnetPluginHelper" \
    --fixture "$ROOT_DIR/Tests/Fixtures/TypingProbe.spinnetplugin" \
    --git-revision "$REVISION" \
    "$@"
