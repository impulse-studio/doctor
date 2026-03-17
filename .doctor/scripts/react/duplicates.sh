#!/usr/bin/env bash
# Detect duplicate/similar code in TypeScript/TSX files
# Requires: node, typescript (devDependency)
#
# Usage: bash verify-duplicates.sh [src-dir] [--verbose]
# Env vars (optional):
#   DUPE_FUNC_THRESHOLD  — min similarity for functions  (default 0.70)
#   DUPE_BLOCK_THRESHOLD — min similarity for sub-blocks (default 0.80)
#   DUPE_TYPE_THRESHOLD  — min field overlap for types   (default 0.70)
#   DUPE_SEM_THRESHOLD   — min semantic similarity       (default 0.50)
#   DUPE_MIN_STMTS       — min statements to analyze     (default 3)
#   DUPE_BLOCK_WINDOW    — sub-block window size          (default 3)
#   DUPE_MAX_RESULTS     — max reported duplications      (default 50)

set -euo pipefail

SRC_DIR="${1:-src}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Check typescript is available
if ! node -e "require('typescript')" 2>/dev/null; then
  echo "FAIL: typescript not found in node_modules (run npm install)"
  exit 1
fi

# Forward all args to the Node.js engine
node "$SCRIPT_DIR/utils/detect-duplicates.mjs" "$@"
