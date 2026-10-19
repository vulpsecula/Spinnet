#!/usr/bin/env bash
set -euo pipefail

# Explicit system integration test. Never uses the daily Host's identifiers,
# service registration, saved configuration or Task journals. A first macOS
# approval remains a human action; exit 77 means pending, never success.
MODE="${1:---prepare}"
[[ "$MODE" == --prepare || "$MODE" == --run ]] || { echo 'usage: check_background_lifecycle.sh [--prepare|--run]' >&2; exit 64; }
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT_DIR/dist/background-lifecycle"
APP="$WORK/SpinnetLifecycle.app"
LABEL=com.vulpsecula.SpinnetHost.lifecycle-fixture.privileged-tools
HOST_ID=com.vulpsecula.SpinnetHost.lifecycle-fixture.preview
SERVICE=com.vulpsecula.SpinnetHost.lifecycle-fixture.reviewed-tools
IDENTITY="${SPINNET_CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development:/{print $2; exit}')"
fi
[[ -n "$IDENTITY" && "$IDENTITY" != - ]] || { echo 'A stable SPINNET_CODESIGN_IDENTITY is required' >&2; exit 64; }
mkdir -p "$WORK"
mkdir "$WORK/lock" 2>/dev/null || { echo "Lifecycle test is busy: $WORK/lock" >&2; exit 1; }
trap 'rmdir "$WORK/lock"' EXIT
RESULTS="$(mktemp -d /tmp/spinnet-background-lifecycle.XXXXXX)"
echo "Lifecycle results: $RESULTS"
json_field() {
    uv --cache-dir /tmp/spinnet-uv-cache run --no-project python - "$1" "$2" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))[sys.argv[2]])
PY
}
build_variant() {
    local variant="$1" destination="$WORK/$1.app" bin_path
    local flags=(-Xswiftc -DSPINNET_BACKGROUND_LIFECYCLE_FIXTURE)
    if [[ "$variant" == next ]]; then flags+=(-Xswiftc -DSPINNET_BACKGROUND_LIFECYCLE_NEXT); fi
    swift build --package-path "$ROOT_DIR" --scratch-path "$ROOT_DIR/.build/background-lifecycle" --product SpinnetBackgroundLifecycleProbe "${flags[@]}" > "$RESULTS/build-$variant.log" 2>&1
    swift build --package-path "$ROOT_DIR" --scratch-path "$ROOT_DIR/.build/background-lifecycle" --product SpinnetPrivilegedToolHelper "${flags[@]}" >> "$RESULTS/build-$variant.log" 2>&1
    bin_path="$(swift build --package-path "$ROOT_DIR" --scratch-path "$ROOT_DIR/.build/background-lifecycle" --show-bin-path "${flags[@]}")"
    rm -rf "$destination"
    mkdir -p "$destination/Contents/MacOS" "$destination/Contents/Helpers" "$destination/Contents/Library/LaunchDaemons"
    cp "$bin_path/SpinnetBackgroundLifecycleProbe" "$destination/Contents/MacOS/SpinnetBackgroundLifecycleProbe"
    cp "$bin_path/SpinnetPrivilegedToolHelper" "$destination/Contents/Helpers/SpinnetPrivilegedToolHelper"
    cat > "$destination/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$HOST_ID</string>
<key>CFBundleName</key><string>Spinnet Lifecycle Tests</string>
<key>CFBundleDisplayName</key><string>Spinnet Lifecycle Tests</string>
<key>CFBundleExecutable</key><string>SpinnetBackgroundLifecycleProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
    cat > "$destination/Contents/Library/LaunchDaemons/$LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>BundleProgram</key><string>Contents/Helpers/SpinnetPrivilegedToolHelper</string>
<key>AssociatedBundleIdentifiers</key><array><string>$HOST_ID</string></array>
<key>MachServices</key><dict>
<key>$SERVICE.host</key><true/><key>$SERVICE.runner</key><true/><key>$SERVICE.client</key><true/>
<key>$SERVICE.inspection.host</key><true/><key>$SERVICE.inspection.client</key><true/>
</dict></dict></plist>
PLIST
    codesign --force --options runtime --identifier "$LABEL" --sign "$IDENTITY" "$destination/Contents/Helpers/SpinnetPrivilegedToolHelper"
    codesign --force --options runtime --sign "$IDENTITY" "$destination"
    codesign --verify --deep --strict "$destination"
    bash "$ROOT_DIR/script/check_background_helper.sh" "$destination/Contents/Helpers/SpinnetPrivilegedToolHelper"
}
INPUT_HASH="$(
    {
        printf '%s\n' "$IDENTITY"
        swift --version
        shasum -a 256 "$ROOT_DIR/Package.swift" "$ROOT_DIR/script/check_background_lifecycle.sh" "$ROOT_DIR/script/check_background_helper.sh"
        fd --type f -0 . "$ROOT_DIR/Sources/SpinnetCore" "$ROOT_DIR/Sources/SpinnetPrivilegedToolHelper" "$ROOT_DIR/Sources/SpinnetBackgroundLifecycleProbe" | sort -z | xargs -0 shasum -a 256
    } | shasum -a 256 | cut -d ' ' -f 1
)"
if [[ ! -f "$WORK/build-input.sha256" || "$(cat "$WORK/build-input.sha256")" != "$INPUT_HASH" || ! -d "$WORK/baseline.app" || ! -d "$WORK/next.app" ]]; then
    build_variant baseline
    build_variant next
    printf '%s\n' "$INPUT_HASH" > "$WORK/build-input.sha256"
fi
for variant in baseline next; do
    codesign --verify --deep --strict "$WORK/$variant.app"
    bash "$ROOT_DIR/script/check_background_helper.sh" "$WORK/$variant.app/Contents/Helpers/SpinnetPrivilegedToolHelper"
done
BASELINE_REVISION="$("$WORK/baseline.app/Contents/Helpers/SpinnetPrivilegedToolHelper" --verify-signature)"
NEXT_REVISION="$("$WORK/next.app/Contents/Helpers/SpinnetPrivilegedToolHelper" --verify-signature)"
[[ "$BASELINE_REVISION" != "$NEXT_REVISION" ]]
if [[ "$MODE" == --prepare ]]; then
    echo 'Prepared two signed isolated builds. Run with --run to test SMAppService and signed XPC.'
    exit 0
fi

HOLDER=""
RETAIN_APPROVAL=0
OWNS_REGISTRATION=0
PROBE="$APP/Contents/MacOS/SpinnetBackgroundLifecycleProbe"
cleanup() {
    local result=$?
    trap - EXIT
    if [[ -n "$HOLDER" ]]; then kill -TERM "$HOLDER" 2>/dev/null || true; wait "$HOLDER" 2>/dev/null || true; fi
    if [[ "$OWNS_REGISTRATION" == 1 && "$RETAIN_APPROVAL" == 0 ]]; then
        if ! "$PROBE" unregister > "$RESULTS/cleanup.json" 2> "$RESULTS/cleanup-error.txt"; then
            echo "Fixture cleanup failed; details: $RESULTS/cleanup-error.txt" >&2
            result=1
        fi
    fi
    rmdir "$WORK/lock"
    exit "$result"
}
trap cleanup EXIT
register_fixture() {
    local phase="$1" attempt=0 deadline=$((SECONDS + 10)) current_status
    OWNS_REGISTRATION=1
    while true; do
        attempt=$((attempt + 1))
        if "$PROBE" register > "$RESULTS/$phase.json" 2> "$RESULTS/$phase-error.txt"; then
            printf '%s\n' "$attempt" > "$RESULTS/$phase-attempts.txt"
            return
        fi
        if [[ "$(json_field "$RESULTS/$phase.json" approvalRequired 2>/dev/null || true)" == True ]]; then
            RETAIN_APPROVAL=1
            echo "PENDING ($phase): approve Spinnet Lifecycle Tests in macOS Login Items, then rerun --run. The complete suite has not passed. Results: $RESULTS" >&2
            exit 77
        fi
        cp "$RESULTS/$phase-error.txt" "$RESULTS/$phase-attempt-$attempt-error.txt"
        # Only this suite's already-approved, explicitly unregistered service
        # may retry EPERM while macOS finishes its unregister bookkeeping.
        # https://developer.apple.com/forums/thread/783539
        "$PROBE" status > "$RESULTS/$phase-state.json"
        current_status="$(json_field "$RESULTS/$phase-state.json" status)"
        if [[ "$phase" == reregistered && "$SECONDS" -lt "$deadline" && ( "$current_status" == 0 || "$current_status" == 3 ) ]] &&
            rg -q -F '(SMAppServiceErrorDomain 1)' "$RESULTS/$phase-error.txt"; then
            sleep 2
            continue
        fi
        cat "$RESULTS/$phase-error.txt" >&2
        exit 1
    done
}
wait_unregistered() {
    local removed=0
    for attempt in {1..100}; do
        if ! launchctl print "system/$LABEL" > "$RESULTS/remaining-job.txt" 2>&1; then removed=1; break; fi
        sleep 0.1
    done
    [[ "$removed" == 1 ]] || { echo 'FAIL: unregistered fixture still has a launchd job' >&2; exit 1; }
}
# Fixed fixture path only; the production .app and service are never replaced.
if [[ ! -d "$APP" ]]; then ditto "$WORK/baseline.app" "$APP"; fi
"$PROBE" status > "$RESULTS/initial-status.json"
INITIAL_STATUS="$(json_field "$RESULTS/initial-status.json" status)"
register_fixture registration
# Resume after manual approval, then establish a known baseline using the
# same authenticated update handoff that the real Host uses.
rm -rf "$APP"
ditto "$WORK/baseline.app" "$APP"
"$PROBE" probe > "$RESULTS/baseline.json"
"$PROBE" probe > "$RESULTS/reconnected.json"
BASELINE_PID="$(json_field "$RESULTS/baseline.json" pid)"
[[ "$(json_field "$RESULTS/reconnected.json" pid)" == "$BASELINE_PID" ]]
[[ "$(json_field "$RESULTS/baseline.json" revision)" == "$BASELINE_REVISION" ]]
[[ "$(json_field "$RESULTS/baseline.json" variant)" == baseline ]]

"$PROBE" hold "$RESULTS/journal" "$RESULTS/ready.json" > "$RESULTS/holder.log" 2>&1 &
HOLDER=$!
for attempt in {1..100}; do
    [[ -f "$RESULTS/ready.json" ]] && break
    kill -0 "$HOLDER" 2>/dev/null || { cat "$RESULTS/holder.log" >&2; exit 1; }
    sleep 0.1
done
[[ -f "$RESULTS/ready.json" ]]
rm -rf "$APP"
ditto "$WORK/next.app" "$APP"
if "$PROBE" probe > "$RESULTS/busy-update.json" 2> "$RESULTS/busy-update-error.txt"; then
    echo 'FAIL: an active Root admission did not block helper replacement' >&2; exit 1
fi
rg -q -F 'wait for the active Task or inspection to finish' "$RESULTS/busy-update-error.txt"
"$PROBE" snapshot > "$RESULTS/busy-snapshot.json"
[[ "$(json_field "$RESULTS/busy-snapshot.json" pid)" == "$BASELINE_PID" ]]
# Simulate loss of the initiating Host. Root must release its own expired
# admission; the next Host only queries status and must never replay work.
kill -TERM "$HOLDER"
wait "$HOLDER" 2>/dev/null || true
HOLDER=""
UPDATED=0
for attempt in {1..100}; do
    if "$PROBE" probe > "$RESULTS/updated.json" 2> "$RESULTS/update-error.txt"; then UPDATED=1; break; fi
    rg -q -F 'wait for the active Task or inspection to finish' "$RESULTS/update-error.txt" || { cat "$RESULTS/update-error.txt" >&2; exit 1; }
    sleep 0.1
done
[[ "$UPDATED" == 1 ]]
[[ "$(json_field "$RESULTS/updated.json" pid)" != "$BASELINE_PID" ]]
[[ "$(json_field "$RESULTS/updated.json" revision)" == "$NEXT_REVISION" ]]
[[ "$(json_field "$RESULTS/updated.json" variant)" == next ]]
"$PROBE" recover "$RESULTS/journal" > "$RESULTS/recovery.json"
"$PROBE" unregister > "$RESULTS/unregistered.json"
OWNS_REGISTRATION=0
wait_unregistered
# A quiet interval is important: repeated register calls can keep macOS's
# post-unregister bookkeeping unsettled, even after the job has disappeared.
sleep 2
register_fixture reregistered
"$PROBE" probe > "$RESULTS/reregistered-probe.json"
[[ "$(json_field "$RESULTS/reregistered-probe.json" revision)" == "$NEXT_REVISION" ]]
"$PROBE" unregister > "$RESULTS/final-cleanup.json"
OWNS_REGISTRATION=0
wait_unregistered
uv --cache-dir /tmp/spinnet-uv-cache run --no-project python - "$RESULTS" "$INITIAL_STATUS" <<'PY'
import json,sys
from pathlib import Path
root=Path(sys.argv[1])
report={'result':'passed','initialStatus':int(sys.argv[2]),'reregisterAttempts':int((root/'reregistered-attempts.txt').read_text()),'checks':['registration','signed_xpc_reconnection','busy_update_refusal','idle_binary_handoff','host_loss_cleanup','terminal_task_recovery','unregister_reregister']}
(root/'report.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report))
PY
