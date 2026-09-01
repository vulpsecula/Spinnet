#!/bin/zsh
set -euo pipefail

prototype_dir="${0:A:h}"
build_dir="$prototype_dir/.build"
binary="$build_dir/native-host-baseline"
source_file="$prototype_dir/Sources/NativeHostBaseline.swift"

mkdir -p "$build_dir"

if [[ ! -x "$binary" || "$source_file" -nt "$binary" ]]; then
  xcrun swiftc \
    -O \
    -framework AppKit \
    -framework Carbon \
    "$source_file" \
    -o "$binary"
fi

if [[ $# -eq 0 ]]; then
  set -- interactive --output "$prototype_dir/measurements/manual-latest"
fi

exec "$binary" "$@"

