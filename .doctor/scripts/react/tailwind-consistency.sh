#!/usr/bin/env bash
# Verify Tailwind usage consistency:
# 1. className must use cn() (or CN_UTIL env var) for conditional/dynamic classes
# 2. CSS files must have all rules inside @layer
# Env vars: CN_UTIL (default "cn")

set -euo pipefail

DOCTOR_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "$DOCTOR_DIR/utils/list-files.sh"

SRC_DIR="${1:-src}"
ERRORS=0
CN_UTIL="${CN_UTIL:-cn}"

# --- Check 1: className must use cn() for conditional classes ---
while IFS= read -r file; do
  line_num=0
  in_multiline_template=false

  while IFS= read -r line; do
    line_num=$((line_num + 1))

    # Detect className={` (template literal — single or multi-line start)
    if echo "$line" | grep -qE 'className=\{`'; then
      echo "FAIL: $file:$line_num — className uses template literal instead of ${CN_UTIL}()"
      ERRORS=$((ERRORS + 1))
      continue
    fi

    # Detect className={(...) => ` (arrow function with template literal)
    if echo "$line" | grep -qE 'className=\{.*=>[[:space:]]*`'; then
      echo "FAIL: $file:$line_num — className callback uses template literal instead of ${CN_UTIL}()"
      ERRORS=$((ERRORS + 1))
      continue
    fi

    # Detect className={`...${...}...`} on a single line (inline template)
    if echo "$line" | grep -qE 'className=\{`[^`]*\$\{[^`]*`\}'; then
      echo "FAIL: $file:$line_num — className uses template literal instead of ${CN_UTIL}()"
      ERRORS=$((ERRORS + 1))
      continue
    fi

    # Detect single-line ternary without cn():
    #   className={cond ? "a" : "b"} or className={`text ${cond ? ...}`}
    # Match: className={ NOT followed by cn( or "string" or CN_UTIL(
    # Only flag if line has className={ with a ternary (? and :) but no cn()
    if echo "$line" | grep -qE 'className=\{[^}]*\?[^}]*\}'; then
      # OK if wrapped in cn() or CN_UTIL()
      if echo "$line" | grep -qE "className=\\{${CN_UTIL}\\("; then
        continue
      fi
      # OK if function form with cn: className={(...) => cn(...)}
      if echo "$line" | grep -qE "className=\\{.*=>[[:space:]]*${CN_UTIL}\\("; then
        continue
      fi
      # OK if it's a simple className="static" (no braces at all, caught by different pattern)
      echo "FAIL: $file:$line_num — className uses ternary without ${CN_UTIL}()"
      ERRORS=$((ERRORS + 1))
      continue
    fi

  done < "$file"
done < <(doctor_list_files "$SRC_DIR" tsx)

# --- Check 2: CSS files — no styles outside @layer ---
while IFS= read -r cssfile; do
  depth=0
  in_allowed_block=false
  css_line_num=0

  while IFS= read -r cssline; do
    css_line_num=$((css_line_num + 1))

    # Strip leading whitespace for pattern matching
    trimmed=$(echo "$cssline" | sed 's/^[[:space:]]*//')

    # Skip empty lines and comments
    [[ -z "$trimmed" ]] && continue
    [[ "$trimmed" == "//"* ]] && continue
    [[ "$trimmed" == "/*"* ]] && continue
    [[ "$trimmed" == "*"* ]] && continue

    # Allowed top-level directives (no braces)
    [[ "$trimmed" == "@import "* ]] && continue
    [[ "$trimmed" == "@tailwindcss"* ]] && continue

    # Track allowed top-level blocks: @layer, @theme, @property
    if [[ "$depth" -eq 0 ]]; then
      if echo "$trimmed" | grep -qE '^@(layer|theme|property) '; then
        in_allowed_block=true
      fi
    fi

    # Count braces
    opens=$(echo "$cssline" | tr -cd '{' | wc -c | tr -d ' ')
    closes=$(echo "$cssline" | tr -cd '}' | wc -c | tr -d ' ')

    # Before updating depth, check if we're opening a rule at depth 0 without allowed block
    if [[ "$depth" -eq 0 && "$opens" -gt 0 && "$in_allowed_block" == false ]]; then
      # This line opens a block at top level without @layer/@theme/@property
      if echo "$trimmed" | grep -qE '^[a-zA-Z.#\[:&*]'; then
        echo "FAIL: $cssfile:$css_line_num — CSS rule outside @layer: $(echo "$trimmed" | head -c 80)"
        ERRORS=$((ERRORS + 1))
      fi
    fi

    depth=$((depth + opens - closes))

    if [[ "$depth" -eq 0 ]]; then
      in_allowed_block=false
    fi
  done < "$cssfile"

done < <(doctor_list_files "$SRC_DIR" css)

if [[ $ERRORS -eq 0 ]]; then
  echo "OK: All classNames use ${CN_UTIL}() and CSS is properly layered"
else
  echo ""
  echo "TOTAL: $ERRORS tailwind consistency violation(s)"
  exit 1
fi
