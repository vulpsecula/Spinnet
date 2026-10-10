#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="SpinnetHost"
BUNDLE_ID="com.vulpsecula.SpinnetHost.preview"
MIN_SYSTEM_VERSION="13.0"
# The Host version Plugins read as spinnet.environment.hostVersion.
APP_VERSION="0.1.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

pkill -f "$APP_BINARY" >/dev/null 2>&1 || true

cd "$ROOT_DIR"
swift build --product "$APP_NAME"
swift build --product SpinnetPluginHelper
swift build --product SpinnetToolTaskRunner
swift build --product SpinnetToolAuthorizationClient
swift build --product SpinnetPrivilegedToolHelper
BUILD_DIR="$(swift build --show-bin-path)"
BUILD_BINARY="$BUILD_DIR/$APP_NAME"
BUILD_HELPER="$BUILD_DIR/SpinnetPluginHelper"
BUILD_TASK_RUNNER="$BUILD_DIR/SpinnetToolTaskRunner"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
mkdir -p "$APP_CONTENTS/Helpers"
cp "$BUILD_HELPER" "$APP_CONTENTS/Helpers/SpinnetPluginHelper"
chmod +x "$APP_CONTENTS/Helpers/SpinnetPluginHelper"
cp "$BUILD_TASK_RUNNER" "$APP_CONTENTS/Helpers/SpinnetToolTaskRunner"
chmod +x "$APP_CONTENTS/Helpers/SpinnetToolTaskRunner"
cp "$BUILD_DIR/SpinnetToolAuthorizationClient" "$APP_CONTENTS/Helpers/SpinnetToolAuthorizationClient"
cp "$BUILD_DIR/SpinnetPrivilegedToolHelper" "$APP_CONTENTS/Helpers/SpinnetPrivilegedToolHelper"
chmod +x "$APP_CONTENTS/Helpers/SpinnetToolAuthorizationClient" "$APP_CONTENTS/Helpers/SpinnetPrivilegedToolHelper"
mkdir -p "$APP_CONTENTS/Library/LaunchDaemons"
cp "$ROOT_DIR/Resources/LaunchDaemons/com.vulpsecula.SpinnetHost.privileged-tools.plist" "$APP_CONTENTS/Library/LaunchDaemons/"
# SwiftPM native resource bundles contain only sealed Host-owned Ruby adapters.
for bundle in "$BUILD_DIR"/Spinnet_SpinnetToolTaskRunner.bundle "$BUILD_DIR"/Spinnet_SpinnetCore.bundle; do
    [[ -d "$bundle" ]] || continue
    ditto "$bundle" "$APP_RESOURCES/$(basename "$bundle")"
done

# Bundled Plugins ship as Plugin packages so the Host reads them the same way
# it reads an installed Plugin. They live under Resources rather than PlugIns
# because they carry no loadable code; codesign seals them as resources.
mkdir -p "$APP_PLUGINS"
bundled_count=0
for package in "$ROOT_DIR"/Plugins/*.spinnetplugin; do
    [[ -d "$package" ]] || continue
    ditto "$package" "$APP_PLUGINS/$(basename "$package")"
    bundled_count=$((bundled_count + 1))
done
if [[ "$bundled_count" -eq 0 ]]; then
    echo "error: no Plugin packages found in $ROOT_DIR/Plugins" >&2
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
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
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
    codesign --force --sign - "$APP_CONTENTS/Helpers/SpinnetPluginHelper"
    codesign --force --identifier com.vulpsecula.SpinnetHost.task-runner --sign - "$APP_CONTENTS/Helpers/SpinnetToolTaskRunner"
    codesign --force --identifier com.vulpsecula.SpinnetHost.authorization-client --sign - "$APP_CONTENTS/Helpers/SpinnetToolAuthorizationClient"
    codesign --force --identifier com.vulpsecula.SpinnetHost.privileged-tools --sign - "$APP_CONTENTS/Helpers/SpinnetPrivilegedToolHelper"
    codesign --force --entitlements "$HOST_ENTITLEMENTS" --sign - "$APP_BUNDLE"
    echo "warning: ad-hoc signed app; Accessibility consent will not persist across code changes" >&2
else
    codesign --force --options runtime --sign "$SIGNING_IDENTITY" "$APP_CONTENTS/Helpers/SpinnetPluginHelper"
    codesign --force --identifier com.vulpsecula.SpinnetHost.task-runner --options runtime --sign "$SIGNING_IDENTITY" "$APP_CONTENTS/Helpers/SpinnetToolTaskRunner"
    codesign --force --identifier com.vulpsecula.SpinnetHost.authorization-client --options runtime --sign "$SIGNING_IDENTITY" "$APP_CONTENTS/Helpers/SpinnetToolAuthorizationClient"
    codesign --force --identifier com.vulpsecula.SpinnetHost.privileged-tools --options runtime --sign "$SIGNING_IDENTITY" "$APP_CONTENTS/Helpers/SpinnetPrivilegedToolHelper"
    codesign --force --options runtime --entitlements "$HOST_ENTITLEMENTS" --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
    echo "Signed with code-signing identity $SIGNING_IDENTITY"
fi
codesign --verify --deep --strict "$APP_BUNDLE"
"$APP_CONTENTS/Helpers/SpinnetToolTaskRunner" --verify-resources

open_app() {
    /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
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
        /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
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
        echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--lifecycle-check]" >&2
        exit 2
        ;;
esac
