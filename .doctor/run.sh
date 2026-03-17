#!/usr/bin/env bash
# .doctor — Project-wide verification runner
# Runs all checks and reports per-check pass/fail.
#
# Usage: bash .doctor/run.sh [--ci] [src-dir]
#        --ci   Emit GitHub Actions annotations (::error / ::warning)
#        Also auto-detected when CI=true (set by GitHub Actions)
# Exit:  0 if all checks pass, 1 if any check fails

set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

# ─── CI mode detection ──────────────────────────────────────
CI_MODE=false
if [[ "${1:-}" == "--ci" ]]; then
  CI_MODE=true
  shift
elif [[ "${CI:-}" == "true" ]]; then
  CI_MODE=true
fi

SRC="${1:-src}"
FAIL=0
RESULTS=()

# All available checks (namespace/name)
ALL_CHECKS=("react/file-naming" "react/component-format" "react/name-match" "react/unused-files" "react/duplicates" "react/max-file-size" "react/import-depth" "react/tailwind-consistency" "react/index-reexports")

# Load disabled checks from config (if present)
DISABLED=()
CHECKS_CONFIG="$DIR/config/checks"
if [ -f "$CHECKS_CONFIG" ]; then
  while IFS= read -r line; do
    line="${line%%#*}"          # strip comments
    line="$(echo "$line" | tr -d '[:space:]')"  # trim
    [ -z "$line" ] && continue
    DISABLED+=("$line")
  done < "$CHECKS_CONFIG"
fi

is_disabled() {
  local check="$1"
  for d in "${DISABLED[@]+"${DISABLED[@]}"}"; do
    [ "$d" = "$check" ] && return 0
  done
  return 1
}

# ─── CI annotation emitter ──────────────────────────────────
# Parses script output lines and emits GitHub Actions annotations.
# Always prints the original line. In CI mode, also emits ::error / ::warning.
emit_ci_annotations() {
  local line
  while IFS= read -r line; do
    # Always print the original output
    echo "$line"

    [[ "$CI_MODE" != "true" ]] && continue

    local level="" file="" linenum="" msg=""

    case "$line" in
      FAIL:*|UNUSED:*)
        level="error"
        local rest="${line#*: }"
        # Format: "path/file.ts:42 — message" or "path/file.ts — message" or "path/file.ts"
        if [[ "$rest" =~ ^([^[:space:]]+):([0-9]+)[[:space:]]—[[:space:]](.+)$ ]]; then
          file="${BASH_REMATCH[1]}"; linenum="${BASH_REMATCH[2]}"; msg="${BASH_REMATCH[3]}"
        elif [[ "$rest" =~ ^([^[:space:]]+)[[:space:]]—[[:space:]](.+)$ ]]; then
          file="${BASH_REMATCH[1]}"; msg="${BASH_REMATCH[2]}"
        elif [[ "$rest" =~ ^([^[:space:]]+)$ ]]; then
          file="${BASH_REMATCH[1]}"; msg="unused file"
        fi
        ;;
      DUPE:*|BLOCK:*|TYPE:*)
        level="error"
        local rest="${line#*: }"
        # Extract first file:line from "file:1-5 <-> ..."
        if [[ "$rest" =~ ^([^:]+):([0-9]+) ]]; then
          file="${BASH_REMATCH[1]}"; linenum="${BASH_REMATCH[2]}"
        fi
        msg="$line"
        ;;
      WARN:*)
        level="warning"
        local rest="${line#WARN: }"
        if [[ "$rest" =~ ^([^[:space:]]+)[[:space:]]—[[:space:]](.+)$ ]]; then
          file="${BASH_REMATCH[1]}"; msg="${BASH_REMATCH[2]}"
        else
          msg="$rest"
        fi
        ;;
      MAGIC:*|HOOK:*)
        level="warning"
        msg="$line"
        if [[ "$line" =~ ^HOOK:[[:space:]]([^:]+):([0-9]+) ]]; then
          file="${BASH_REMATCH[1]}"; linenum="${BASH_REMATCH[2]}"
        fi
        ;;
      *)
        continue
        ;;
    esac

    if [[ -n "$level" ]]; then
      local annotation="::${level}"
      if [[ -n "$file" ]]; then
        annotation+=" file=${file}"
        if [[ -n "$linenum" ]]; then
          annotation+=",line=${linenum}"
        fi
      fi
      annotation+="::${msg:-$line}"
      echo "$annotation"
    fi
  done
}

for check in "${ALL_CHECKS[@]}"; do
  if is_disabled "$check"; then
    RESULTS+=("  - ${check} (disabled)")
    continue
  fi

  # namespace/name → scripts/namespace/name.sh
  script="$DIR/scripts/${check}.sh"
  echo ""
  echo "── ${check} ─────────────────────────────────────────"

  script_exit=0
  output=$(bash "$script" "$SRC" 2>&1) || script_exit=$?

  echo "$output" | emit_ci_annotations

  if [ "$script_exit" -eq 0 ]; then
    RESULTS+=("  ✓ ${check}")
  else
    RESULTS+=("  ✗ ${check}")
    FAIL=1
  fi
done

echo ""
echo "── Summary ─────────────────────────────────────────"
for r in "${RESULTS[@]}"; do
  echo "$r"
done
echo ""

if [ "$FAIL" -eq 0 ]; then
  echo "All checks passed."
else
  echo "Some checks failed."
fi

exit $FAIL
