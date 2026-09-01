#!/bin/zsh
set -euo pipefail

prototype_dir="${0:A:h}"
mkdir -p "$prototype_dir/.build"

xcrun swiftc -warnings-as-errors -O \
  -framework AppKit \
  -framework Carbon \
  "$prototype_dir/Sources/NativeHostBaseline.swift" \
  -o "$prototype_dir/.build/native-host-baseline-verify"

"$prototype_dir/.build/native-host-baseline-verify" verify-geometry
