#!/usr/bin/env bash
# Verify .tsx files have exactly one "export default [async] function ComponentName"
# Verify .tsx files have no inline constants (top-level const before export default function)
# Verify .ts files have at most one export (exception: type-only files, stores, API layers)
# Skip: vite-env.d.ts, main.tsx, widget-app.tsx (entry points)

set -euo pipefail

DOCTOR_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "$DOCTOR_DIR/utils/list-files.sh"

SRC_DIR="${1:-src}"
ERRORS=0

# --- Check .tsx files ---
while IFS= read -r file; do
  basename=$(basename "$file")

  # Skip entry points and index re-export files
  [[ "$basename" == "main.tsx" ]] && continue
  [[ "$basename" == "widget-app.tsx" ]] && continue
  [[ "$basename" == "index.tsx" ]] && continue

  # Count "export default [async] function" occurrences
  default_count=$(grep -cE "^export default (async )?function " "$file" 2>/dev/null || true)

  if [[ "$default_count" -eq 0 ]]; then
    echo "FAIL: $file — missing 'export default function'"
    ERRORS=$((ERRORS + 1))
  elif [[ "$default_count" -gt 1 ]]; then
    echo "FAIL: $file — multiple 'export default function' ($default_count)"
    ERRORS=$((ERRORS + 1))
  fi

  # Check for non-default exported functions (sub-components)
  named_fn_exports=$(grep -cE "^export (async )?function " "$file" 2>/dev/null || true)
  if [[ "$named_fn_exports" -gt 0 ]]; then
    echo "WARN: $file — has $named_fn_exports named function export(s) (prefer separate files)"
  fi

  # Check for inline constants (top-level const declarations before export default function)
  export_line=$(grep -nE "^export default (async )?function " "$file" 2>/dev/null | head -1 | cut -d: -f1)
  if [[ -n "$export_line" && "$export_line" -gt 1 ]]; then
    inline_consts=$(head -n "$((export_line - 1))" "$file" | grep -c "^const " || true)
    if [[ "$inline_consts" -gt 0 ]]; then
      echo "FAIL: $file — has $inline_consts inline constant(s) before component (extract to separate .ts files)"
      ERRORS=$((ERRORS + 1))
    fi

    # Check for top-level helper functions before the component (should be in separate files)
    inline_fns=$(head -n "$((export_line - 1))" "$file" | grep -c "^function " || true)
    if [[ "$inline_fns" -gt 0 ]]; then
      echo "FAIL: $file — has $inline_fns top-level function(s) before component (extract to separate .ts files)"
      ERRORS=$((ERRORS + 1))
    fi
  fi

done < <(doctor_list_files "$SRC_DIR" tsx)

# --- Check .ts files (non-type files) ---
while IFS= read -r file; do
  basename=$(basename "$file")

  # Skip vite-env.d.ts
  [[ "$basename" == "vite-env.d.ts" ]] && continue

  # Skip known exceptions: stores, API layers, event definitions
  [[ "$file" == *"/stores/"* ]] && continue
  [[ "$basename" == "tauri-commands.ts" ]] && continue
  [[ "$basename" == "tauri-events.ts" ]] && continue

  # Count all exports (excluding type/interface exports)
  runtime_exports=$(grep -cE "^export (default |default async |const |function |async function )" "$file" 2>/dev/null || true)

  if [[ "$runtime_exports" -gt 1 ]]; then
    echo "FAIL: $file — has $runtime_exports runtime exports (should be 1 per file)"
    ERRORS=$((ERRORS + 1))
  fi

done < <(doctor_list_files "$SRC_DIR" ts | grep -v '\.d\.ts$')

if [[ $ERRORS -eq 0 ]]; then
  echo "OK: All components follow the export default function pattern"
else
  echo ""
  echo "TOTAL: $ERRORS format violation(s)"
  exit 1
fi
