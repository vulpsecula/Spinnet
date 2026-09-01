#!/bin/zsh
set -euo pipefail

prototype_dir="${0:A:h}"

if [[ $# -eq 0 ]]; then
  set -- --iterations 200 --warmups 20 --output "$prototype_dir/measurements/automated-latest"
fi

exec "$prototype_dir/run.sh" benchmark "$@"

