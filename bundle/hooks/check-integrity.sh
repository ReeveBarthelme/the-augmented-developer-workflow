#!/usr/bin/env bash
# Run from a consumer repository; failures propagate to the caller.
set -euo pipefail
root=$(git rev-parse --show-toplevel)
exec python3 "$root/.workflow/vendor/sync.py" --check --target "$root"
