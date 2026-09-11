#!/bin/bash
# Build a separate, verified Gopher64-Both copy; never modify the original.
# Both gopher64 and gopher64-cli are required. Quit the generated app first.
# SDL3_LIBRARY or --library selects the rebuilt compatible SDL library.
set -euo pipefail
exec python3 "$(cd "$(dirname "$0")" && pwd)/install_gopher64.py" "$@"
