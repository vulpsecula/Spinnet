#!/bin/zsh
set -euo pipefail

prototype_dir="${0:A:h}"
exec uv run "$prototype_dir/run.py" "$@"
