#!/usr/bin/env bash
# Prints the packages directory consumed by packaging and shipped-package tests.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK_FILE="${1:-$ROOT_DIR/bundled-plugins.lock.json}"
fail() { echo "error: $*" >&2; exit 1; }
validate_packages() {
    local package count=0
    for package in "$1"/*.spinnetplugin; do
        [[ -d "$package" && -f "$package/manifest.json" ]] || continue
        count=$((count + 1))
    done
    [[ "$count" -gt 0 ]] || fail "no Plugin packages found in $1"
}

# The existing development variable names a packages directory, not a repo.
if [[ -n "${SPINNET_BUNDLED_PLUGINS_DIR:-}" ]]; then
    [[ -d "$SPINNET_BUNDLED_PLUGINS_DIR" ]] || fail "missing development Plugin directory: $SPINNET_BUNDLED_PLUGINS_DIR"
    directory="$(cd "$SPINNET_BUNDLED_PLUGINS_DIR" && pwd)"
    validate_packages "$directory"
    echo "$directory"
    exit 0
fi
repository="$(plutil -extract repository raw -o - "$LOCK_FILE")"
revision="$(plutil -extract revision raw -o - "$LOCK_FILE")"
[[ -n "$repository" && "$repository" != -* ]] || fail "invalid Plugin repository in $LOCK_FILE"
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || fail "Plugin revision must be a full commit SHA in $LOCK_FILE"
key="$(printf '%s' "$repository" | shasum -a 256 | cut -d ' ' -f 1)"
cache="${SPINNET_BUNDLED_PLUGINS_CACHE:-$ROOT_DIR/.build/bundled-plugins}/$key"
mkdir -p "$cache"
# Serialize writers, including parallel tests and builds sharing this cache.
attempt=0
until mkdir "$cache/lock" 2>/dev/null; do
    attempt=$((attempt + 1))
    [[ "$attempt" -lt 300 ]] || fail "Plugin cache is busy: $cache/lock (remove a stale lock after an interrupted resolver)"
    sleep 0.1
done
staging=""
trap '[[ -z "$staging" ]] || rm -rf "$staging"; rmdir "$cache/lock"' EXIT
mirror="$cache/repository.git"
if [[ ! -d "$mirror" ]]; then git init --bare "$mirror" >&2; fi
if ! git -C "$mirror" cat-file -e "$revision^{commit}" 2>/dev/null; then
    git -C "$mirror" fetch --depth=1 -- "$repository" "$revision:refs/heads/revision-$revision" >&2
fi
snapshot="$cache/$revision"
if [[ ! -d "$snapshot" ]]; then
    staging="$(mktemp -d "$cache/staging.XXXXXX")"
    git clone --shared --no-checkout "$mirror" "$staging" >&2
    git -C "$staging" -c advice.detachedHead=false checkout --detach "$revision" >&2
    mv "$staging" "$snapshot"
    staging=""
fi
[[ "$(git -C "$snapshot" rev-parse HEAD)" == "$revision" ]] || fail "wrong revision in Plugin cache: $snapshot"
[[ -z "$(git -C "$snapshot" status --porcelain --untracked-files=all)" ]] || fail "modified Plugin cache: $snapshot; remove it and resolve again, or use SPINNET_BUNDLED_PLUGINS_DIR for development"
validate_packages "$snapshot/Plugins"
echo "$snapshot/Plugins"
