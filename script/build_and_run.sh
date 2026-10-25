#!/usr/bin/env bash
set -euo pipefail

usage() {
    printf 'usage: %s [run|--package|--debug|--logs|--telemetry|--verify|--lifecycle-check|--background-lifecycle-check [--prepare|--run|--status|--clean [--unregister]]]\n' "$0"
}
reject_arguments() {
    usage >&2
    exit 2
}

# Validate before consulting signing identities, resolving Plugins or touching
# the running app. In particular, help and spelling errors must be inert.
MODE="${1-run}"
case "$MODE" in
    -h|--help)
        [[ $# -eq 1 ]] || reject_arguments
        usage
        exit 0
        ;;
    --background-lifecycle-check)
        BACKGROUND_MODE="${2---prepare}"
        case "$BACKGROUND_MODE" in
            --prepare|--run|--status|-h|--help) [[ $# -le 2 ]] || reject_arguments ;;
            --clean)
                [[ $# -le 3 ]] || reject_arguments
                [[ $# -lt 3 || "$3" == --unregister ]] || reject_arguments
                ;;
            *) reject_arguments ;;
        esac
        ;;
    run|--package|--lifecycle-check|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify)
        [[ $# -le 1 ]] || reject_arguments
        ;;
    *) reject_arguments ;;
esac

APP_NAME="SpinnetHost"
BUNDLE_ID="com.vulpsecula.SpinnetHost.preview"
MIN_SYSTEM_VERSION="13.0"
# The Host version Plugins read as spinnet.environment.hostVersion.
APP_VERSION="0.1.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$MODE" == --background-lifecycle-check ]]; then
    if [[ $# -eq 3 ]]; then
        exec bash "$ROOT_DIR/script/check_background_lifecycle.sh" "$BACKGROUND_MODE" "$3"
    fi
    exec bash "$ROOT_DIR/script/check_background_lifecycle.sh" "$BACKGROUND_MODE"
fi
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_PLUGINS="$APP_RESOURCES/Plugins"
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

SIGNING_IDENTITY="${SPINNET_CODESIGN_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development:/{print $2; exit}')"
fi

if [[ "$SIGNING_IDENTITY" == "-" && "$ALLOW_ADHOC_SIGNING" != "1" ]]; then
    echo "error: ad-hoc signing is disabled because it invalidates Accessibility consent." >&2
    echo "       Use an Apple Development identity, or set SPINNET_ALLOW_ADHOC_SIGNING=1 for a deliberate permission-free run." >&2
    exit 1
fi

if [[ -z "$SIGNING_IDENTITY" && "$ALLOW_ADHOC_SIGNING" != "1" ]]; then
    echo "error: no stable code-signing identity found; refusing ad-hoc signing because it invalidates Accessibility consent." >&2
    echo "       Install/select an Apple Development identity, or set SPINNET_ALLOW_ADHOC_SIGNING=1 for a deliberate permission-free run." >&2
    exit 1
fi

BUNDLED_PLUGINS_DIR="$("$ROOT_DIR/script/resolve_bundled_plugins.sh")"

# The commit a DEBUG Host reports in Developer > Copy Diagnostics.
SOURCE_REVISION="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [[ "$SOURCE_REVISION" != unknown ]] && ! git -C "$ROOT_DIR" diff --quiet HEAD -- 2>/dev/null; then
    SOURCE_REVISION="$SOURCE_REVISION-dirty"
fi

if [[ "$MODE" != "--package" ]]; then
    pkill -f "$APP_BINARY" >/dev/null 2>&1 || true
fi

cd "$ROOT_DIR"
swift build --product "$APP_NAME"
for specification in "${HELPER_SPECS[@]}"; do
    swift build --product "${specification%%|*}"
done
BUILD_DIR="$(swift build --show-bin-path)"
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
# SwiftPM native resource bundles contain only sealed Host-owned Ruby adapters.
for bundle in "$BUILD_DIR"/Spinnet_SpinnetCore.bundle; do
    [[ -d "$bundle" ]] || continue
    ditto "$bundle" "$APP_RESOURCES/$(basename "$bundle")"
done

# Bundled Plugins ship as Plugin packages so the Host reads them the same way
# it reads an installed Plugin. They live under Resources rather than PlugIns
# because they carry no loadable code; codesign seals them as resources.
mkdir -p "$APP_PLUGINS"
bundled_count=0
for package in "$BUNDLED_PLUGINS_DIR"/*.spinnetplugin; do
    [[ -d "$package" ]] || continue
    ditto "$package" "$APP_PLUGINS/$(basename "$package")"
    bundled_count=$((bundled_count + 1))
done
if [[ "$bundled_count" -eq 0 ]]; then
    echo "error: no Plugin packages found in $BUNDLED_PLUGINS_DIR" >&2
    exit 1
fi
echo "Bundled $bundled_count Plugin package(s)"

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
if [[ -n "$SIGNING_IDENTITY" && "$SIGNING_IDENTITY" != "-" ]]; then
    "$APP_BINARY" --verify-homebrew-transport
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
        ;;
    *)
        reject_arguments
        ;;
esac
