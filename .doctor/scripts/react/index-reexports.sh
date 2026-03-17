#!/usr/bin/env bash
# Verify index.tsx/index.ts files in component directories contain only re-exports
# Matches: components/, _components/, component/, _component/ at any depth
# Also warns about orphan folders (single .tsx in a component subfolder)

set -euo pipefail

DOCTOR_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "$DOCTOR_DIR/utils/list-files.sh"

SRC_DIR="${1:-src}"
ERRORS=0

# Find all index files in component-like directories
while IFS= read -r file; do
  line_num=0
  while IFS= read -r line; do
    line_num=$((line_num + 1))

    # Strip leading/trailing whitespace
    trimmed=$(echo "$line" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')

    # Skip empty lines
    [[ -z "$trimmed" ]] && continue
    # Skip single-line comments
    [[ "$trimmed" == //* ]] && continue
    # Skip multi-line comment markers
    [[ "$trimmed" == "/*"* ]] && continue
    [[ "$trimmed" == "*"* ]] && continue

    # Valid: export { ... } from "..."; or export type { ... } from "...";
    if echo "$trimmed" | grep -qE '^export[[:space:]]+(type[[:space:]]+)?\{.*\}[[:space:]]+from[[:space:]]+'; then
      continue
    fi

    # Invalid: any other content
    echo "FAIL: $file:$line_num — index file contains non-re-export content: $(echo "$trimmed" | head -c 80)"
    ERRORS=$((ERRORS + 1))
    break  # One error per file is enough
  done < "$file"

done < <(doctor_list_files "$SRC_DIR" tsx ts | grep -E '(^|/)index\.(tsx|ts)$' | grep -E '_?components?/' | sort)

# --- Check for orphan folders (single non-index file in component subfolder) ---
while IFS= read -r dir; do
  file_count=0
  while IFS= read -r f; do
    basename=$(basename "$f")
    [[ "$basename" == "index.tsx" || "$basename" == "index.ts" ]] && continue
    file_count=$((file_count + 1))
  done < <(find "$dir" -maxdepth 1 -type f \( -name "*.tsx" -o -name "*.ts" \) 2>/dev/null)

  if [[ "$file_count" -eq 1 ]]; then
    the_file=$(find "$dir" -maxdepth 1 -type f \( -name "*.tsx" -o -name "*.ts" \) ! -name "index.tsx" ! -name "index.ts" | head -1)
    echo "WARN: $dir/ — orphan folder with single file ($(basename "$the_file")). Consider flattening."
  fi
done < <(doctor_list_dirs "$SRC_DIR" | grep -E '_?components?/[^/]+$' | sort)

if [[ $ERRORS -eq 0 ]]; then
  echo "OK: All index files in component directories are pure re-exports"
else
  echo ""
  echo "TOTAL: $ERRORS index file violation(s)"
  exit 1
fi
