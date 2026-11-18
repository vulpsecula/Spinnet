#!/usr/bin/env bash
# Packages a release: an Official Build in the release configuration, signed
# with the Vulpsecula Software certificate, as Spinnet.app inside a DMG.
#
#   ./script/package_release.sh 1.0.0-beta.1
#
# The label is the Host version from HostCompatibility.swift, optionally
# followed by a pre-release suffix such as -beta.1; the tag is v<label>.
# It builds from a clean checkout of HEAD and never touches the running Host.
set -euo pipefail

usage() {
    printf 'usage: %s VERSION[-PRERELEASE]\n' "$0"
}
[[ $# -eq 1 ]] || { usage >&2; exit 2; }
case "$1" in -h|--help) usage; exit 0 ;; esac
LABEL="$1"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_SOURCE="$ROOT_DIR/Sources/SpinnetCore/Plugins/HostCompatibility.swift"
APP_VERSION="$(sed -nE 's/^[[:space:]]*public static let currentString = "([0-9]+\.[0-9]+\.[0-9]+)"[[:space:]]*$/\1/p' "$VERSION_SOURCE")"
if [[ ! "$LABEL" =~ ^${APP_VERSION//./\\.}(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?$ ]]; then
    echo "error: release label $LABEL must be the Host version $APP_VERSION, optionally with a suffix such as -beta.1" >&2
    exit 2
fi

# A release is reproducible from its tag: nothing uncommitted may go in.
if ! git -C "$ROOT_DIR" diff --quiet HEAD --; then
    echo "error: commit or stash tracked changes first; a release builds exactly HEAD" >&2
    exit 1
fi

# Every release is signed with the same certificate, or macOS treats the
# update as a new app and drops its Accessibility consent.
RELEASE_SIGNING_NAME="Vulpsecula Software"
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null |
    awk -v name="\"$RELEASE_SIGNING_NAME\"" 'index($0, name) { print $2; exit }')"
if [[ -z "$IDENTITY" ]]; then
    echo "error: the $RELEASE_SIGNING_NAME code-signing certificate is not in the Keychain" >&2
    exit 1
fi

OUTPUT_DIR="$ROOT_DIR/dist/release"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/spinnet-release.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
DMG="$OUTPUT_DIR/Spinnet-$LABEL.dmg"

SPINNET_OFFICIAL_BUILD=1 SPINNET_BUILD_CONFIGURATION=release SPINNET_DIST_DIR="$WORK_DIR/build" \
    SPINNET_CODESIGN_IDENTITY="$IDENTITY" SPINNET_ALLOW_ADHOC_SIGNING=0 \
    "$ROOT_DIR/script/build_and_run.sh" --package

# The bundle is named for the product; renaming it keeps its signature.
STAGE="$WORK_DIR/stage"
mkdir -p "$STAGE"
ditto "$WORK_DIR/build/SpinnetHost.app" "$STAGE/Spinnet.app"
ln -s /Applications "$STAGE/Applications"
codesign --verify --deep --strict "$STAGE/Spinnet.app"

mkdir -p "$OUTPUT_DIR"
rm -f "$DMG" "$DMG.sha256"
hdiutil create -quiet -volname "Spinnet $LABEL" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
codesign --force --sign "$IDENTITY" "$DMG"
codesign --verify "$DMG"
(cd "$OUTPUT_DIR" && shasum -a 256 "$(basename "$DMG")" >"$(basename "$DMG").sha256")

echo "Packaged $DMG"
cat "$DMG.sha256"
