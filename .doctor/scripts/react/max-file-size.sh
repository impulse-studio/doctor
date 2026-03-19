#!/usr/bin/env bash
# Verify no .ts/.tsx file exceeds the maximum line count
# Reads thresholds from .doctor/config/max-file-size
# Supports per-file overrides with glob patterns

set -euo pipefail

DOCTOR_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "$DOCTOR_DIR/utils/list-files.sh"

SRC_DIR="${1:-src}"
ERRORS=0
WARNINGS=0

# ─── Defaults ────────────────────────────────────────────────
DEFAULT_WARN=350
DEFAULT_FAIL=500

# ─── Parse config ────────────────────────────────────────────
OVERRIDE_PATTERNS=()
OVERRIDE_WARN=()
OVERRIDE_FAIL=()

CONFIG_FILE="$DOCTOR_DIR/config/max-file-size"
if [[ -f "$CONFIG_FILE" ]]; then
  while IFS= read -r line; do
    # Skip comments and blank lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -z "$line" ]] && continue

    # Default line: just "warn=N" or "fail=N"
    if [[ "$line" =~ ^warn= ]]; then
      DEFAULT_WARN="${line#warn=}"
      continue
    fi
    if [[ "$line" =~ ^fail= ]]; then
      DEFAULT_FAIL="${line#fail=}"
      continue
    fi

    # Per-file override: <pattern> warn=N fail=N
    # Extract pattern (everything before the first warn= or fail=)
    pattern=$(echo "$line" | sed -E 's/[[:space:]]+(warn|fail)=.*//')
    w="$DEFAULT_WARN"
    f="$DEFAULT_FAIL"

    if [[ "$line" =~ warn=(-?[0-9]+) ]]; then
      w="${BASH_REMATCH[1]}"
    fi
    if [[ "$line" =~ fail=(-?[0-9]+) ]]; then
      f="${BASH_REMATCH[1]}"
    fi

    OVERRIDE_PATTERNS+=("$pattern")
    OVERRIDE_WARN+=("$w")
    OVERRIDE_FAIL+=("$f")
  done < "$CONFIG_FILE"
fi

# ─── Get limits for a file ───────────────────────────────────
get_limits() {
  local file="$1"
  LIMIT_WARN="$DEFAULT_WARN"
  LIMIT_FAIL="$DEFAULT_FAIL"

  # Last matching pattern wins
  for i in "${!OVERRIDE_PATTERNS[@]}"; do
    if [[ "$file" == ${OVERRIDE_PATTERNS[$i]} ]]; then
      LIMIT_WARN="${OVERRIDE_WARN[$i]}"
      LIMIT_FAIL="${OVERRIDE_FAIL[$i]}"
    fi
  done
}

# ─── Check files ─────────────────────────────────────────────
while IFS= read -r file; do
  lines=$(wc -l < "$file" | tr -d ' ')
  get_limits "$file"

  # -1 means no limit
  if [[ "$LIMIT_FAIL" -ne -1 ]] && [[ "$lines" -gt "$LIMIT_FAIL" ]]; then
    echo "FAIL: $file — $lines lines (max $LIMIT_FAIL)"
    ERRORS=$((ERRORS + 1))
  elif [[ "$LIMIT_WARN" -ne -1 ]] && [[ "$lines" -gt "$LIMIT_WARN" ]]; then
    echo "WARN: $file — $lines lines (warn at $LIMIT_WARN)"
    WARNINGS=$((WARNINGS + 1))
  fi
done < <(doctor_list_files "$SRC_DIR" ts tsx | grep -v '\.d\.ts$')

if [[ $ERRORS -eq 0 ]]; then
  if [[ $WARNINGS -gt 0 ]]; then
    echo "OK: No files exceed limit ($WARNINGS warning(s))"
  else
    echo "OK: All files are within limits"
  fi
else
  echo ""
  echo "TOTAL: $ERRORS file(s) exceed their limit"
  exit 1
fi
