#!/usr/bin/env bash
set -euo pipefail

usage() {
    printf 'usage: %s [--official] [--install-plugins DIR] [run|--debug|--logs|--telemetry|--verify|--lifecycle-check]\n' "$0"
    printf '       %s --package\n' "$0"
    printf '\n--install-plugins installs or updates every .spinnetplugin package in DIR,\n'
    printf 'or in DIR/Plugins for a SpinnetPlugins checkout, into your saved data through\n'
    printf 'the install-and-update path the Library uses, before the app opens.\n'
    printf '%s\n' '--verify reports the installed Plugin versions saved on disk once the app has stayed up.'
    printf '%s\n' '--official (or SPINNET_OFFICIAL_BUILD=1) builds an Official Build, with its Trial and Activation.'
    printf '%s\n' 'SPINNET_BUILD_CONFIGURATION=release builds the release configuration; SPINNET_DIST_DIR moves dist/.'
    printf '%s\n' 'Release DMGs are made by script/package_release.sh.'
}
reject_arguments() {
    usage >&2
    exit 2
}

# Validate before consulting signing identities, building or touching the
# running app. In particular, help and spelling errors must be inert.
# An Official Build has a Trial and takes an Activation Code; every other
# build is a source build and is never limited. It builds in its own scratch
# directory so switching does not rebuild the everyday one.
OFFICIAL_BUILD="${SPINNET_OFFICIAL_BUILD:-0}"
if [[ "${1-}" == --official ]]; then
    OFFICIAL_BUILD=1
    shift
fi
[[ "$OFFICIAL_BUILD" == 0 || "$OFFICIAL_BUILD" == 1 ]] || reject_arguments
SWIFT_BUILD_ARGUMENTS=()
if [[ "$OFFICIAL_BUILD" == 1 ]]; then
    SWIFT_BUILD_ARGUMENTS=(--scratch-path .build/official -Xswiftc -DSPINNET_OFFICIAL_BUILD)
fi
# Release packaging (script/package_release.sh) builds the release
# configuration, which leaves out DEBUG-only Developer tools.
BUILD_CONFIGURATION="${SPINNET_BUILD_CONFIGURATION:-debug}"
[[ "$BUILD_CONFIGURATION" == debug || "$BUILD_CONFIGURATION" == release ]] || reject_arguments
SWIFT_BUILD_ARGUMENTS+=(-c "$BUILD_CONFIGURATION")
INSTALL_PLUGINS_DIR=""
if [[ "${1-}" == --install-plugins ]]; then
    [[ $# -ge 2 && -n "$2" ]] || reject_arguments
    INSTALL_PLUGINS_DIR="$2"
    shift 2
    case "${1-run}" in
        run|--lifecycle-check|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify) ;;
        *) reject_arguments ;;
    esac
fi
MODE="${1-run}"
case "$MODE" in
    -h|--help)
        [[ $# -eq 1 ]] || reject_arguments
        usage
        exit 0
        ;;
    run|--package|--lifecycle-check|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify)
        [[ $# -le 1 ]] || reject_arguments
        ;;
    *) reject_arguments ;;
esac

APP_NAME="SpinnetHost"
BUNDLE_ID="com.vulpsecula.SpinnetHost.preview"
MIN_SYSTEM_VERSION="13.0"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -n "$INSTALL_PLUGINS_DIR" ]]; then
    if [[ ! -d "$INSTALL_PLUGINS_DIR" ]]; then
        echo "error: missing Plugin package directory: $INSTALL_PLUGINS_DIR" >&2
        exit 1
    fi
    INSTALL_PLUGINS_DIR="$(cd "$INSTALL_PLUGINS_DIR" && pwd)"
fi
# Package the same release version that unbundled Host and helper code use.
VERSION_SOURCE="$ROOT_DIR/Sources/SpinnetCore/Plugins/HostCompatibility.swift"
APP_VERSION="$(sed -nE 's/^[[:space:]]*public static let currentString = "([0-9]+\.[0-9]+\.[0-9]+)"[[:space:]]*$/\1/p' "$VERSION_SOURCE")"
if [[ ! "$APP_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "error: cannot read the Host release version from $VERSION_SOURCE" >&2
    exit 1
fi
DIST_DIR="${SPINNET_DIST_DIR:-$ROOT_DIR/dist}"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
HOST_ENTITLEMENTS="$ROOT_DIR/Resources/SpinnetHost.entitlements"
ALLOW_ADHOC_SIGNING="${SPINNET_ALLOW_ADHOC_SIGNING:-0}"

# Product and optional signing identifier for each shipped helper. Build,
# packaging and both signing modes use this same inventory.
HELPER_SPECS=(
    'SpinnetPluginHelper|'
    'SpinnetToolTaskRunner|com.vulpsecula.SpinnetHost.task-runner'
    'SpinnetHomebrewAskpass|com.vulpsecula.SpinnetHost.homebrew-askpass'
    'SpinnetToolAuthorizationClient|com.vulpsecula.SpinnetHost.authorization-client'
    'SpinnetPrivilegedToolHelper|com.vulpsecula.SpinnetHost.privileged-tools'
    'SpinnetReceiptInventory|com.vulpsecula.SpinnetHost.receipt-inventory'
    'SpinnetArchiveBootstrap|com.vulpsecula.SpinnetHost.archive-bootstrap'
    'SpinnetArchiveDecoder|com.vulpsecula.SpinnetHost.archive-decoder'
    'SpinnetPathInventory|com.vulpsecula.SpinnetHost.path-inventory'
    'SpinnetVendorOrigin|com.vulpsecula.SpinnetHost.vendor-origin'
    'SpinnetPathRemoval|com.vulpsecula.SpinnetHost.path-removal'
    'SpinnetLaunchServiceInventory|com.vulpsecula.SpinnetHost.launch-service-inventory'
)

# Official Builds ship signed with Spinnet's own self-signed certificate, so
# Accessibility consent survives updates; it is preferred whenever present.
# Without it, an Apple Development identity serves local development.
RELEASE_SIGNING_NAME="Vulpsecula Software"
SIGNING_IDENTITY="${SPINNET_CODESIGN_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -v name="\"$RELEASE_SIGNING_NAME\"" '
        index($0, name) && !release { release = $2 }
        /Apple Development:/ && !development { development = $2 }
        END { print (release ? release : development) }')"
fi

if [[ "$SIGNING_IDENTITY" == "-" && "$ALLOW_ADHOC_SIGNING" != "1" ]]; then
    echo "error: ad-hoc signing is disabled because it invalidates Accessibility consent." >&2
    echo "       Use the Vulpsecula Software or an Apple Development identity, or set SPINNET_ALLOW_ADHOC_SIGNING=1 for a deliberate permission-free run." >&2
    exit 1
fi

if [[ -z "$SIGNING_IDENTITY" && "$ALLOW_ADHOC_SIGNING" != "1" ]]; then
    echo "error: no stable code-signing identity found; refusing ad-hoc signing because it invalidates Accessibility consent." >&2
    echo "       Install/select the Vulpsecula Software or an Apple Development identity, or set SPINNET_ALLOW_ADHOC_SIGNING=1 for a deliberate permission-free run." >&2
    exit 1
fi

# The commit a DEBUG Host reports in Developer > Copy Diagnostics.
SOURCE_REVISION="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [[ "$SOURCE_REVISION" != unknown ]] && ! git -C "$ROOT_DIR" diff --quiet HEAD -- 2>/dev/null; then
    SOURCE_REVISION="$SOURCE_REVISION-dirty"
fi

if [[ "$MODE" != "--package" ]]; then
    pkill -f "$APP_BINARY" >/dev/null 2>&1 || true
fi

cd "$ROOT_DIR"
swift build ${SWIFT_BUILD_ARGUMENTS[@]+"${SWIFT_BUILD_ARGUMENTS[@]}"} --product "$APP_NAME"
for specification in "${HELPER_SPECS[@]}"; do
    swift build ${SWIFT_BUILD_ARGUMENTS[@]+"${SWIFT_BUILD_ARGUMENTS[@]}"} --product "${specification%%|*}"
done
BUILD_DIR="$(swift build ${SWIFT_BUILD_ARGUMENTS[@]+"${SWIFT_BUILD_ARGUMENTS[@]}"} --show-bin-path)"
BUILD_BINARY="$BUILD_DIR/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
mkdir -p "$APP_CONTENTS/Helpers"
for specification in "${HELPER_SPECS[@]}"; do
    tool="${specification%%|*}"
    cp "$BUILD_DIR/$tool" "$APP_CONTENTS/Helpers/$tool"
    chmod +x "$APP_CONTENTS/Helpers/$tool"
done
mkdir -p "$APP_CONTENTS/Library/LaunchDaemons"
cp "$ROOT_DIR/Resources/LaunchDaemons/com.vulpsecula.SpinnetHost.privileged-tools.plist" "$APP_CONTENTS/Library/LaunchDaemons/"
# Core no longer has runtime resources. Do not package its obsolete SwiftPM
# bundle if an incremental build left the retired Ruby adapters behind.

# The Host's compiled String Catalog goes into the app's own resources, so
# the Host and AppKit both run in the interface language General chooses.
HOST_RESOURCES="$BUILD_DIR/Spinnet_SpinnetHost.bundle/Contents/Resources"
if [[ ! -f "$HOST_RESOURCES/zh-Hans.lproj/Localizable.strings" ]]; then
    echo "error: missing the Host's compiled String Catalog in $HOST_RESOURCES" >&2
    exit 1
fi
cp -R "$HOST_RESOURCES/"*.lproj "$APP_RESOURCES/"
mkdir -p "$APP_RESOURCES/en.lproj"
cp "$HOST_RESOURCES/StatusItemTemplate.pdf" "$APP_RESOURCES/StatusItemTemplate.pdf"
# Compile the editable Icon Composer document for current macOS appearances
# and the minimum supported macOS. actool emits Assets.car and AppIcon.icns.
xcrun actool "$ROOT_DIR/Resources/AppIcon.icon" \
    --compile "$APP_RESOURCES" \
    --output-partial-info-plist "$DIST_DIR/AppIcon-info.plist" \
    --app-icon AppIcon --platform macosx \
    --minimum-deployment-target "$MIN_SYSTEM_VERSION" \
    --output-format human-readable-text

# The app contains no Plugins: every Plugin, official or not, is installed
# into the user's saved data the way the Library installs one.

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>Spinnet</string>
  <key>CFBundleDisplayName</key>
  <string>Spinnet</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>en</string>
    <string>zh-Hans</string>
  </array>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>SpinnetSourceRevision</key>
  <string>$SOURCE_REVISION</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Spinnet sends an app only the requests it has reviewed for that app, when you choose a Command of a Plugin you allowed to control it.</string>
</dict>
</plist>
PLIST

if [[ "$ALLOW_ADHOC_SIGNING" == "1" && ( -z "$SIGNING_IDENTITY" || "$SIGNING_IDENTITY" == "-" ) ]]; then
    SIGNING_ARGUMENTS=(--force --sign -)
else
    SIGNING_ARGUMENTS=(--force --options runtime --sign "$SIGNING_IDENTITY")
fi
for specification in "${HELPER_SPECS[@]}"; do
    tool="${specification%%|*}"
    identifier="${specification#*|}"
    arguments=("${SIGNING_ARGUMENTS[@]}")
    if [[ -n "$identifier" ]]; then arguments+=(--identifier "$identifier"); fi
    codesign "${arguments[@]}" "$APP_CONTENTS/Helpers/$tool"
done
codesign "${SIGNING_ARGUMENTS[@]}" --entitlements "$HOST_ENTITLEMENTS" "$APP_BUNDLE"
if [[ "$ALLOW_ADHOC_SIGNING" == "1" && ( -z "$SIGNING_IDENTITY" || "$SIGNING_IDENTITY" == "-" ) ]]; then
    echo "warning: ad-hoc signed app; Accessibility consent will not persist across code changes" >&2
else
    echo "Signed with code-signing identity $SIGNING_IDENTITY"
fi
codesign --verify --deep --strict "$APP_BUNDLE"
"$APP_CONTENTS/Helpers/SpinnetToolTaskRunner" --verify-resources
"$APP_CONTENTS/Helpers/SpinnetHomebrewAskpass" --verify
"$APP_BINARY" --verify-localizations
if [[ -n "$SIGNING_IDENTITY" && "$SIGNING_IDENTITY" != "-" ]]; then
    if ! "$APP_BINARY" --verify-homebrew-transport; then
        echo "error: the signed Task runner refused this Host's signature; Homebrew Tasks would fail with runner_refused" >&2
        exit 1
    fi
    bash "$ROOT_DIR/script/check_background_helper.sh" "$APP_CONTENTS/Helpers/SpinnetPrivilegedToolHelper"
fi
if [[ "$MODE" != "--package" ]]; then
    if ! "$APP_BINARY" --refresh-existing-background-operations; then
        if [[ "$MODE" == --verify ]]; then
            echo "error: the enabled background component failed its signed connection/update check" >&2
            exit 1
        fi
        echo "warning: background component update is pending; open Spinnet Privacy & Permissions for its status" >&2
    fi
fi

if [[ -n "$INSTALL_PLUGINS_DIR" ]]; then
    # No Host is running: the launcher quit it before building.
    echo "Installing Plugin packages from $INSTALL_PLUGINS_DIR"
    "$APP_BINARY" --install-plugins "$INSTALL_PLUGINS_DIR"
fi

open_app() {
    /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
    --package)
        # Validate a clean-checkout bundle without replacing the running Host.
        ;;
    run)
        open_app
        ;;
    --lifecycle-check)
        /usr/bin/open -n "$APP_BUNDLE" --args --lifecycle-check
        ;;
    --debug|debug)
        lldb -- "$APP_BINARY"
        ;;
    --logs|logs)
        open_app
        /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
        ;;
    --telemetry|telemetry)
        open_app
        # Every Host and Core Logger uses this subsystem (HostLog).
        /usr/bin/log stream --info --style compact --predicate "subsystem == \"com.vulpsecula.Spinnet\""
        ;;
    --verify|verify)
        open_app
        for second in 1 2 3 4 5; do
            sleep 1
            if ! pgrep -f "$APP_BINARY" >/dev/null; then
                echo "$APP_NAME exited after ${second}s" >&2
                exit 1
            fi
        done
        echo "Running $APP_BUNDLE"
        echo "Installed Plugins, as saved on disk:"
        if ! "$APP_BINARY" --report-installed-plugins; then
            echo "warning: the running Host refuses an installed Plugin; see Settings → Menu" >&2
        fi
        ;;
    *)
        reject_arguments
        ;;
esac
