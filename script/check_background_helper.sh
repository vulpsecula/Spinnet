#!/usr/bin/env bash
set -euo pipefail

# Read-only startup validation: no Root identity, XPC listeners or recovery writes.
HELPER_PATH="$1"
[[ "$HELPER_PATH" == /* ]]
EXPECTED_REVISION="$("$HELPER_PATH" --verify-signature)"
[[ "$EXPECTED_REVISION" =~ ^[a-f0-9]{40,64}$ ]]
for launch_name in Contents/Helpers/SpinnetPrivilegedToolHelper SpinnetPrivilegedToolHelper; do
    ACTUAL_REVISION="$(cd / && exec -a "$launch_name" "$HELPER_PATH" --verify-signature)"
    [[ "$ACTUAL_REVISION" == "$EXPECTED_REVISION" ]]
done
echo "Background component signature verified with absolute, relative and basename launch names"
