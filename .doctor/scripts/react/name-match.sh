#!/usr/bin/env bash
# Verify that file names match their default export names
# kebab-case filename → PascalCase component (for .tsx)
# kebab-case filename → camelCase constant/function (for .ts)
# Also verify props interface naming: ComponentNameProps only
# macOS compatible (no grep -P, no bash 4+ features)

set -euo pipefail

DOCTOR_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "$DOCTOR_DIR/utils/list-files.sh"

SRC_DIR="${1:-src}"
ERRORS=0

kebab_to_pascal() {
  echo "$1" | awk -F'-' '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)}1' OFS=''
}

kebab_to_camel() {
  local pascal
  pascal=$(kebab_to_pascal "$1")
  echo "$pascal" | awk '{print tolower(substr($0,1,1)) substr($0,2)}'
}

# --- Check .tsx files ---
while IFS= read -r file; do
  basename_f=$(basename "$file")
  [[ "$basename_f" == "main.tsx" ]] && continue
  [[ "$basename_f" == "widget-app.tsx" ]] && continue
  [[ "$basename_f" == "index.tsx" ]] && continue

  name="${basename_f%.tsx}"
  expected_pascal=$(kebab_to_pascal "$name")

  # Extract export default [async] function name (macOS grep compatible)
  actual=$(grep -E "^export default (async )?function " "$file" 2>/dev/null | head -1 | sed -E 's/^export default (async )?function ([A-Za-z0-9]+).*/\2/' || true)

  if [[ -z "$actual" ]]; then
    echo "FAIL: $file — no 'export default [async] function' found"
    ERRORS=$((ERRORS + 1))
  elif [[ "$actual" != "$expected_pascal" ]]; then
    echo "FAIL: $file — export is '$actual', expected '$expected_pascal'"
    ERRORS=$((ERRORS + 1))
  fi

  # Check props interface naming: only *Props interfaces must match ComponentNameProps
  while IFS= read -r iface; do
    [[ -z "$iface" ]] && continue
    # Only validate interfaces ending in "Props"
    [[ "$iface" != *Props ]] && continue
    if [[ "$iface" != "${expected_pascal}Props" ]]; then
      echo "FAIL: $file — props interface '$iface' should be '${expected_pascal}Props'"
      ERRORS=$((ERRORS + 1))
    fi
  done < <(grep "^interface " "$file" 2>/dev/null | sed -E 's/^interface ([A-Za-z0-9]+).*/\1/' || true)

done < <(doctor_list_files "$SRC_DIR" tsx)

# --- Check .ts utility files ---
while IFS= read -r file; do
  basename_f=$(basename "$file")
  [[ "$basename_f" == "vite-env.d.ts" ]] && continue

  # Skip type files, stores, API layers, events
  [[ "$file" == *"/types/"* ]] && continue
  [[ "$file" == *"/stores/"* ]] && continue
  [[ "$basename_f" == "tauri-commands.ts" ]] && continue
  [[ "$basename_f" == "tauri-events.ts" ]] && continue

  name="${basename_f%.ts}"
  expected_camel=$(kebab_to_camel "$name")
  expected_pascal=$(kebab_to_pascal "$name")

  # Check for export default [async] function
  actual_fn=$(grep -E "^export default (async )?function " "$file" 2>/dev/null | head -1 | sed -E 's/^export default (async )?function ([a-zA-Z0-9]+).*/\2/' || true)

  # Check for "export default <identifier>" (not function)
  actual_default=$(grep "^export default " "$file" 2>/dev/null | grep -v "function" | head -1 | sed -E 's/^export default ([a-zA-Z][a-zA-Z0-9]*).*/\1/' || true)

  if [[ -n "$actual_fn" ]]; then
    if [[ "$actual_fn" != "$expected_camel" && "$actual_fn" != "$expected_pascal" ]]; then
      echo "FAIL: $file — function '$actual_fn', expected '$expected_camel'"
      ERRORS=$((ERRORS + 1))
    fi
  elif [[ -n "$actual_default" ]]; then
    if [[ "$actual_default" != "$expected_camel" && "$actual_default" != "$expected_pascal" ]]; then
      echo "FAIL: $file — export default '$actual_default', expected '$expected_camel'"
      ERRORS=$((ERRORS + 1))
    fi
  fi

done < <(doctor_list_files "$SRC_DIR" ts | grep -v '\.d\.ts$')

if [[ $ERRORS -eq 0 ]]; then
  echo "OK: All file names match their exports"
else
  echo ""
  echo "TOTAL: $ERRORS name mismatch(es)"
  exit 1
fi
