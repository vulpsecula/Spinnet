#!/usr/bin/env bash
# Runs the #69 AX insertion matrix unattended, through the Host A2 insertion
# code itself.
#
#   ./script/ax_insertion_matrix.sh                 build, check the grant, run every target
#   ./script/ax_insertion_matrix.sh --only chrome,vscode
#   ./script/ax_insertion_matrix.sh --skip obsidian
#   ./script/ax_insertion_matrix.sh --dry-run       drive only the probe's own fixture App
#   ./script/ax_insertion_matrix.sh --build-only    build, sign and self-check
#   ./script/ax_insertion_matrix.sh --output DIR    where results go
#                                                   (default tmp/ax-insertion-matrix/<time>)
#
# The probe is dist/AXInsertionProbe.app, a developer-only App in no product.
# It compiles Host A2's own PluginHostServices.swift (and the SpinnetCore it
# needs) from commit af1a450, byte for byte, and calls
# AppKitPluginHostServiceProvider.insertText(_:intoApplication:) exactly as
# the Host does for a Plugin View's standard insert action.
#
# One-time step: grant Accessibility to "AX Insertion Probe" in System
# Settings > Privacy & Security > Accessibility. The grant follows the signing
# identity and bundle ID, so rebuilding keeps it.
#
# What a run opens, each in something new it closes afterwards: its own
# fixture App, a new TextEdit document of its own, a new Terminal window, its
# own pages in Safari, and separate instances of Chrome, Visual Studio Code,
# Cursor and Obsidian on throwaway profiles. The pages are served by the probe
# on 127.0.0.1 and report their fields' values back to it, and the editors'
# files are read from disk, so every web and Electron row is also checked
# without Accessibility. Results: results.json and results.md in the output
# directory.
set -euo pipefail

HOST_A2="af1a45095dbac15eddeb44063809927a373705b1"
BUNDLE_ID="com.vulpsecula.Spinnet.AXInsertionProbe"
FIXTURE_BUNDLE_ID="com.vulpsecula.Spinnet.AXInsertionProbe.Fixture"
HOST_FILES=(PluginHostServices.swift FocusedWindowScreen.swift StageManagerStrip.swift)
# The Host A2 error texts the probe maps to steps; they must be in the
# pinned insertion code.
HOST_MESSAGES=("No focused text field" "The focused App does not accept inserted text" "The focused App did not accept the text")

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="$ROOT_DIR/.build/ax-insertion-probe"
PACKAGE_DIR="$BUILD_ROOT/package"
SCRATCH_DIR="$BUILD_ROOT/scratch"
APP_BUNDLE="$ROOT_DIR/dist/AXInsertionProbe.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/AXInsertionProbe"
FIXTURE_BUNDLE="$APP_BUNDLE/Contents/Resources/AXProbeFixture.app"

MODE="run"
OUTPUT_DIR=""
PROBE_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-only) MODE="build" ;;
        --dry-run) MODE="dry-run" ;;
        --output) OUTPUT_DIR="$2"; shift ;;
        --only|--skip) PROBE_ARGS+=("$1" "$2"); shift ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
    esac
    shift
done
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/tmp/ax-insertion-matrix/$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

SIGNING_IDENTITY="${SPINNET_CODESIGN_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development:/{print $2; exit}')"
fi
if [[ -z "$SIGNING_IDENTITY" || "$SIGNING_IDENTITY" == "-" ]]; then
    echo "error: no Apple Development signing identity; an ad-hoc signature would lose the Accessibility grant on every build" >&2
    exit 1
fi

git_root() { git -C "$ROOT_DIR" "$@"; }

assemble_package() {
    echo "Assembling the probe package from Tools/AXInsertionProbe and Host A2 ($HOST_A2)"
    git_root cat-file -e "$HOST_A2^{commit}"
    mkdir -p "$PACKAGE_DIR"
    rsync -a --delete --exclude .build --exclude Sources/SpinnetCore --exclude Sources/AXInsertionProbe/HostA2 \
        "$ROOT_DIR/Tools/AXInsertionProbe/" "$PACKAGE_DIR/"
    rm -rf "$PACKAGE_DIR/Sources/SpinnetCore" "$PACKAGE_DIR/Sources/AXInsertionProbe/HostA2"
    git_root archive "$HOST_A2" Sources/SpinnetCore | tar -x -C "$PACKAGE_DIR"
    mkdir -p "$PACKAGE_DIR/Sources/AXInsertionProbe/HostA2"

    # Every pinned file must be Host A2's blob, byte for byte.
    local mismatches=0 path blob actual
    while read -r _ _ blob path; do
        actual="$(git_root hash-object "$PACKAGE_DIR/$path")"
        if [[ "$actual" != "$blob" ]]; then echo "error: $path is not Host A2's blob $blob" >&2; mismatches=1; fi
    done < <(git_root ls-tree -r "$HOST_A2" Sources/SpinnetCore)
    local files_swift=""
    for name in "${HOST_FILES[@]}"; do
        path="Sources/SpinnetHost/$name"
        blob="$(git_root rev-parse "$HOST_A2:$path")"
        git_root show "$HOST_A2:$path" > "$PACKAGE_DIR/Sources/AXInsertionProbe/HostA2/$name"
        actual="$(git_root hash-object "$PACKAGE_DIR/Sources/AXInsertionProbe/HostA2/$name")"
        if [[ "$actual" != "$blob" ]]; then echo "error: $path is not Host A2's blob $blob" >&2; mismatches=1; fi
        files_swift+="        \"$path\": \"$blob\","$'\n'
    done
    [[ "$mismatches" -eq 0 ]] || exit 1
    for message in "${HOST_MESSAGES[@]}"; do
        if ! grep -qF "\"$message\"" "$PACKAGE_DIR/Sources/AXInsertionProbe/HostA2/PluginHostServices.swift"; then
            echo "error: Host A2's insertion code no longer says \"$message\"; the probe's step mapping is stale" >&2
            exit 1
        fi
    done
    local core_tree head_identical="true"
    core_tree="$(git_root rev-parse "$HOST_A2:Sources/SpinnetCore")"
    if ! git_root diff --quiet "$HOST_A2" HEAD -- Sources/SpinnetCore \
        "${HOST_FILES[@]/#/Sources/SpinnetHost/}"; then
        head_identical="false"
    fi
    cat >"$PACKAGE_DIR/Sources/AXInsertionProbe/HostA2/HostA2Provenance.swift" <<SWIFT
// Generated by script/ax_insertion_matrix.sh. Do not edit.
enum HostA2Provenance {
    static let commit = "$HOST_A2"
    static let spinnetCoreTree = "$core_tree"
    static let files: [String: String] = [
$files_swift    ]
    /// Whether HEAD's copies of these files equal Host A2's when the probe
    /// was built. The probe runs Host A2's either way.
    static let headIdentical = $head_identical
}
SWIFT
    echo "Pinned: SpinnetCore tree $core_tree and ${#HOST_FILES[@]} Host files checked against $HOST_A2"
}

write_plist() {
    local path="$1" executable="$2" identifier="$3" name="$4" ui_element="$5"
    cat >"$path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$executable</string>
  <key>CFBundleIdentifier</key>
  <string>$identifier</string>
  <key>CFBundleName</key>
  <string>$name</string>
  <key>CFBundleDisplayName</key>
  <string>$name</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <$ui_element/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST
}

build_app() {
    assemble_package
    echo "Building (release)"
    swift build -c release --package-path "$PACKAGE_DIR" --scratch-path "$SCRATCH_DIR"
    local bin_dir
    bin_dir="$(swift build -c release --package-path "$PACKAGE_DIR" --scratch-path "$SCRATCH_DIR" --show-bin-path)"

    rm -rf "$APP_BUNDLE"
    mkdir -p "$APP_BUNDLE/Contents/MacOS" "$FIXTURE_BUNDLE/Contents/MacOS"
    cp "$bin_dir/AXInsertionProbe" "$APP_BINARY"
    cp "$bin_dir/AXProbeFixture" "$FIXTURE_BUNDLE/Contents/MacOS/AXProbeFixture"
    write_plist "$APP_BUNDLE/Contents/Info.plist" AXInsertionProbe "$BUNDLE_ID" "AX Insertion Probe" true
    write_plist "$FIXTURE_BUNDLE/Contents/Info.plist" AXProbeFixture "$FIXTURE_BUNDLE_ID" "AX Probe Fixture" false

    codesign --force --options runtime --sign "$SIGNING_IDENTITY" "$FIXTURE_BUNDLE"
    codesign --force --options runtime --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
    codesign --verify --deep --strict "$APP_BUNDLE"
    echo "Signed $APP_BUNDLE with $SIGNING_IDENTITY ($BUNDLE_ID)"

    "$APP_BINARY" selftest --out "$OUTPUT_DIR/selftest-sample"
}

# Through LaunchServices, so macOS checks the probe's own Accessibility grant
# rather than the terminal's.
run_probe() {
    local log="$1"
    shift
    mkdir -p "$(dirname "$log")"
    : >"$log"
    trap 'pkill -TERM -f "$APP_BINARY" || true' INT TERM
    local status=0
    # `open --stdout` makes LaunchServices refuse a long-running probe
    # (-10810 on macOS 27), so the probe's progress is not streamed; its
    # results are printed when it finishes.
    /usr/bin/open -W -n "$APP_BUNDLE" --args "$@" >>"$log" 2>&1 || status=$?
    trap - INT TERM
    return "$status"
}

build_app
[[ "$MODE" == "build" ]] && exit 0

if [[ "$MODE" == "dry-run" ]]; then
    run_probe "$OUTPUT_DIR/probe.log" run --dry-run --out "$OUTPUT_DIR" "${PROBE_ARGS[@]+"${PROBE_ARGS[@]}"}"
    echo "Dry run results: $OUTPUT_DIR/results.md"
    exit 0
fi

/usr/bin/open -W -n "$APP_BUNDLE" --args check-trust --prompt --out "$OUTPUT_DIR/trust.txt" || true
if [[ "$(cat "$OUTPUT_DIR/trust.txt" 2>/dev/null)" != "trusted" ]]; then
    # Without the grant, record what the Host does with Accessibility off,
    # into the probe's own fixture only.
    run_probe "$OUTPUT_DIR/accessibility-off/probe.log" run --dry-run --only fixture \
        --out "$OUTPUT_DIR/accessibility-off" >/dev/null 2>&1 || true
    echo
    echo "Accessibility is not granted to the probe. Turn on \"AX Insertion Probe\" in System Settings > Privacy & Security > Accessibility ($APP_BUNDLE), then run this script again."
    echo "(Recorded the Accessibility-off case into the probe's own fixture: $OUTPUT_DIR/accessibility-off/results.md)"
    exit 3
fi

echo "Running the AX insertion matrix unattended. It takes about 8 minutes and moves windows to the front;"
echo "do not type or click until it finishes. Ctrl-C stops it and ends the probe's own instances."
run_probe "$OUTPUT_DIR/probe.log" run --out "$OUTPUT_DIR" "${PROBE_ARGS[@]+"${PROBE_ARGS[@]}"}"
echo
cat "$OUTPUT_DIR/results.md"
echo
echo "Results: $OUTPUT_DIR/results.json and $OUTPUT_DIR/results.md"
