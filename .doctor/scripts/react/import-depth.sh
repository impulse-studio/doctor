#!/usr/bin/env bash
# Verify import depth (max 2 levels of ../) and no cross-feature imports
# Features = direct children of src/ (excluding "shared")
# "shared" imports are always allowed from any feature

set -euo pipefail

DOCTOR_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "$DOCTOR_DIR/utils/list-files.sh"

SRC_DIR="${1:-src}"
ERRORS=0

# Auto-detect feature directories (direct children of src/, excluding "shared")
FEATURE_DIRS=()
while IFS= read -r dir; do
  dirname=$(basename "$dir")
  [[ "$dirname" == "shared" ]] && continue
  FEATURE_DIRS+=("$dirname")
done < <(doctor_list_dirs "$SRC_DIR" | grep -v "^${SRC_DIR}$" | while IFS= read -r d; do
  rel="${d#"$SRC_DIR"/}"
  echo "$rel" | grep -q '/' && continue
  echo "$d"
done)

while IFS= read -r file; do
  # Extract all import paths
  while IFS= read -r imp; do
    [[ -z "$imp" ]] && continue

    # Skip non-relative imports (node_modules, aliases)
    [[ "$imp" != ./* && "$imp" != ../* ]] && continue

    # Check for 3+ levels of ../
    depth=$(echo "$imp" | grep -c '\.\.\/' || true)
    if [[ "$depth" -ge 3 ]]; then
      echo "FAIL: $file — import depth $depth (max 2): from \"$imp\""
      ERRORS=$((ERRORS + 1))
      continue
    fi

    # Check for cross-feature imports
    rel_path="${file#"$SRC_DIR"/}"
    file_feature=$(echo "$rel_path" | cut -d/ -f1)

    # Resolve import path using Node.js
    file_dir=$(dirname "$file")
    resolved=$(node -e "const p=require('path');process.stdout.write(p.normalize(p.join('$file_dir','$imp')))" 2>/dev/null || echo "")
    [[ -z "$resolved" ]] && continue

    # Must be under src/
    case "$resolved" in
      "$SRC_DIR"/*) ;;
      *) continue ;;
    esac

    target_rel="${resolved#"$SRC_DIR"/}"
    target_feature=$(echo "$target_rel" | cut -d/ -f1)

    # Allow: shared, same feature
    [[ "$target_feature" == "shared" ]] && continue
    [[ "$target_feature" == "$file_feature" ]] && continue

    # Check if both source and target are feature dirs
    source_is_feature=false
    target_is_feature=false
    for fd in "${FEATURE_DIRS[@]}"; do
      [[ "$file_feature" == "$fd" ]] && source_is_feature=true
      [[ "$target_feature" == "$fd" ]] && target_is_feature=true
    done

    if $source_is_feature && $target_is_feature; then
      echo "FAIL: $file — cross-feature import from '$file_feature' to '$target_feature': from \"$imp\""
      ERRORS=$((ERRORS + 1))
    fi

  done < <(grep -oE "(from|import) [\"'][^\"']+[\"']" "$file" 2>/dev/null \
    | sed -E "s/(from|import) [\"']([^\"']+)[\"']/\2/" || true)

done < <(doctor_list_files "$SRC_DIR" ts tsx | grep -v '\.d\.ts$')

if [[ $ERRORS -eq 0 ]]; then
  echo "OK: All imports within depth limit and no cross-feature imports"
else
  echo ""
  echo "TOTAL: $ERRORS import violation(s)"
  exit 1
fi
