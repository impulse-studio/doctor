#!/usr/bin/env bash
# Detect unused source files by analyzing the import graph
# Walks all imports from entry points and flags unreachable files
# macOS compatible (uses python3 for path normalization)

set -euo pipefail

DOCTOR_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "$DOCTOR_DIR/utils/list-files.sh"

SRC_DIR="${1:-src}"
ERRORS=0

# --- Collect all source files ---
all_files=()
while IFS= read -r f; do
  all_files+=("$f")
done < <(doctor_list_files "$SRC_DIR" ts tsx | grep -v '\.d\.ts$')

# --- Entry points (always considered used) ---
entry_points=()
ENTRY_CONFIG="$DOCTOR_DIR/config/entry-points"
if [[ -f "$ENTRY_CONFIG" ]]; then
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -z "$line" ]] && continue
    entry_points+=("$line")
  done < "$ENTRY_CONFIG"
fi

# Fallback if no config or empty
if [[ ${#entry_points[@]} -eq 0 ]]; then
  entry_points=("$SRC_DIR/main.tsx")
fi

# --- Build set of imported file paths ---
imported_set=$(mktemp)
trap "rm -f $imported_set" EXIT

for file in "${all_files[@]}"; do
  file_dir=$(dirname "$file")

  # Extract all import/export-from paths
  while IFS= read -r imp; do
    [[ -z "$imp" ]] && continue
    # Resolve @/ alias to SRC_DIR/
    if [[ "$imp" == @/* ]]; then
      raw="$SRC_DIR/${imp#@/}"
    elif [[ "$imp" == ./* || "$imp" == ../* ]]; then
      raw="$file_dir/$imp"
    else
      # Skip package imports (not relative, not alias)
      continue
    fi

    # Try extensions: .ts, .tsx, /index.ts, /index.tsx
    for ext in ".ts" ".tsx" "/index.ts" "/index.tsx"; do
      candidate="${raw}${ext}"
      # Normalize path using python3 (handles ../ correctly)
      norm=$(python3 -c "import os.path; print(os.path.normpath('$candidate'))" 2>/dev/null || echo "")
      if [[ -f "$norm" ]]; then
        echo "$norm" >> "$imported_set"
        break
      fi
    done
  done < <(grep -oE "from [\"'][^\"']+[\"']" "$file" 2>/dev/null | sed -E "s/from [\"']([^\"']+)[\"']/\1/" || true)
done

# Sort + deduplicate
sort -u "$imported_set" -o "$imported_set"

# --- Check each file ---
for file in "${all_files[@]}"; do
  # Skip entry points (unquoted $ep enables glob pattern matching)
  is_entry=false
  for ep in "${entry_points[@]}"; do
    if [[ "$file" == $ep ]]; then
      is_entry=true
      break
    fi
  done
  $is_entry && continue

  # Check if this file is imported by any other file
  if ! grep -qx "$file" "$imported_set"; then
    echo "UNUSED: $file"
    ERRORS=$((ERRORS + 1))
  fi
done

if [[ $ERRORS -eq 0 ]]; then
  echo "OK: No unused files detected"
else
  echo ""
  echo "TOTAL: $ERRORS unused file(s)"
  exit 1
fi
