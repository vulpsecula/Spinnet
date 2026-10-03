#!/usr/bin/env bash
# Runs the Host A2 checks from the Emoji probe's PROOF.md (#69) that need no
# person and no permission, unattended:
#
#   1. authority: install review and disclosure, update 1.0.0 -> 1.1.0 with no
#      access prompt, Insert denied, Accessibility off, and a revocation with
#      the view open ending the View Session and its helper at once;
#   2. for each round, View Session latency and memory with the Emoji package,
#      including idle retirement with the view open (--idle-retirements 2)
#      and long typing (--memory-queries 40: more than 30 pauses within 30 s);
#   3. the Emoji repository's own tests through the pinned test kit, with its
#      120-event helper soak (EMOJI_SOAK=1).
#
#   ./script/emoji_e1_host_checks.sh [--quick] [--machine-idle yes|no] [--output DIR] [--skip-kit-tests]
#
# The Host code is Host A2 (af1a450) byte for byte: the script builds from a
# `git archive` of that commit, replacing only Sources/SpinnetViewSessionMeasurement
# (a developer tool in no product) with this checkout's. Results go to
# tmp/emoji-e1-host-checks/<time> unless --output says otherwise.
set -euo pipefail

HOST_A2="af1a45095dbac15eddeb44063809927a373705b1"
ROUND1="003eafce0f319327ca92ee7abf37e63f083cbd7b"
ROUND2="7d553616bbcf329392b44175f2294bcce7cab567"
QUERIES="smile|cat|red heart|party|thumbs up|flag japan|rocket|pizza"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EMOJI_REPO="${SPINNET_EMOJI_PROBE:-$(cd "$ROOT_DIR/.." && pwd)/SpinnetProbes/emoji}"
BUILD_ROOT="$ROOT_DIR/.build/emoji-e1-host-a2"
SOURCE_DIR="$BUILD_ROOT/source"
SCRATCH_DIR="$BUILD_ROOT/scratch"

QUICK=()
MACHINE_IDLE="unknown"
OUTPUT_DIR=""
KIT_TESTS=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --quick) QUICK=(--quick) ;;
        --machine-idle) MACHINE_IDLE="$2"; shift ;;
        --output) OUTPUT_DIR="$2"; shift ;;
        --skip-kit-tests) KIT_TESTS=0 ;;
        -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
    esac
    shift
done
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/tmp/emoji-e1-host-checks/$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

[[ -d "$EMOJI_REPO/.git" ]] || { echo "error: the Emoji probe is not at $EMOJI_REPO (set SPINNET_EMOJI_PROBE)" >&2; exit 1; }

echo "Assembling Host A2 ($HOST_A2) with this checkout's measurement tool"
git -C "$ROOT_DIR" cat-file -e "$HOST_A2^{commit}"
rm -rf "$SOURCE_DIR"
mkdir -p "$SOURCE_DIR"
git -C "$ROOT_DIR" archive "$HOST_A2" | tar -x -C "$SOURCE_DIR"
rm -rf "$SOURCE_DIR/Sources/SpinnetViewSessionMeasurement"
cp -R "$ROOT_DIR/Sources/SpinnetViewSessionMeasurement" "$SOURCE_DIR/Sources/SpinnetViewSessionMeasurement"
TOOL_REVISION="$(git -C "$ROOT_DIR" rev-parse --short HEAD)"
if [[ -n "$(git -C "$ROOT_DIR" status --porcelain -- Sources/SpinnetViewSessionMeasurement)" ]]; then
    TOOL_REVISION="$TOOL_REVISION with uncommitted changes"
fi
REVISION="Host A2 ${HOST_A2:0:7}; measurement tool from $TOOL_REVISION"

echo "Building release"
swift build -c release --package-path "$SOURCE_DIR" --scratch-path "$SCRATCH_DIR" --product SpinnetPluginHelper
swift build -c release --package-path "$SOURCE_DIR" --scratch-path "$SCRATCH_DIR" --product SpinnetViewSessionMeasurement
BIN_DIR="$(swift build -c release --package-path "$SOURCE_DIR" --scratch-path "$SCRATCH_DIR" --show-bin-path)"
HELPER="$BIN_DIR/SpinnetPluginHelper"
TOOL="$BIN_DIR/SpinnetViewSessionMeasurement"

for round in 1 2; do
    commit_var="ROUND$round"
    mkdir -p "$OUTPUT_DIR/packages/round$round"
    git -C "$EMOJI_REPO" archive "${!commit_var}" Emoji.spinnetplugin | tar -x -C "$OUTPUT_DIR/packages/round$round"
done
ROUND1_PACKAGE="$OUTPUT_DIR/packages/round1/Emoji.spinnetplugin"
ROUND2_PACKAGE="$OUTPUT_DIR/packages/round2/Emoji.spinnetplugin"

FAILED=()
step() {
    local name="$1"
    shift
    echo
    echo "== $name"
    if ! "$@"; then FAILED+=("$name"); fi
}

step "authority" "$TOOL" authority --helper "$HELPER" --fixture "$ROUND1_PACKAGE" --update-to "$ROUND2_PACKAGE" \
    --output "$OUTPUT_DIR/authority" --git-revision "$REVISION"

for round in 1 2; do
    package_var="ROUND${round}_PACKAGE"
    step "round $round sessions" "$TOOL" --helper "$HELPER" --fixture "${!package_var}" \
        --queries "$QUERIES" --event-query heart --memory-queries 40 --idle-retirements 2 \
        --machine-idle "$MACHINE_IDLE" --git-revision "$REVISION" \
        --note "Emoji round $round on Host A2; each memory cycle types 40 queries (long typing)" \
        --output "$OUTPUT_DIR/round$round-sessions" "${QUICK[@]+"${QUICK[@]}"}"
done

if [[ "$KIT_TESTS" -eq 1 ]]; then
    kit_tests() {
        (cd "$EMOJI_REPO" && EMOJI_SOAK=1 swift test 2>&1) | tee "$OUTPUT_DIR/kit-tests.log"
        return "${PIPESTATUS[0]}"
    }
    step "Emoji kit tests with the helper soak" kit_tests
fi

echo
echo "Results: $OUTPUT_DIR"
if [[ ${#FAILED[@]} -gt 0 ]]; then
    printf 'Did not pass: %s\n' "${FAILED[@]}"
    exit 1
fi
echo "Every step passed."
