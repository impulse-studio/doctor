---
name: create-best-practice
description: Guides the AI through creating a new doctor verification script for the .doctor/ infrastructure. Use when adding a new automated code quality check.
compatibility: Requires bash, grep, node. Works with any project using the .doctor/ infrastructure.
allowed-tools: Bash(bash:*) Read Edit Write
---

# Create Best Practice Check

This skill teaches you how to create a new `.doctor/` verification script that enforces a code convention automatically.

## When to Create a Check

Create a check when:
- A pattern should be consistent across the codebase (naming, imports, structure)
- The rule appeared in 2+ code reviews or was violated 2+ times
- It can be detected mechanically (grep, AST, line counting)
- **Always ask the user first** before creating a new check

Do NOT create a check for:
- One-off style preferences
- Rules that require human judgment
- Patterns that exist in only 1 file

## Script Location & Naming

```
.doctor/scripts/react/<check-name>.sh
```

- `<check-name>` must be kebab-case (e.g. `max-file-size`, `import-depth`)
- One concern per script

## Script Template

Every script must follow this pattern:

```bash
#!/usr/bin/env bash
# <check-name>.sh — <One-line description>
set -euo pipefail

SRC_DIR="${1:-src}"
ERRORS=0

# --- Detection logic ---
# Use: find, grep, node -e "..." for complex path/AST work
# NEVER use Python — use Node.js if shell is insufficient

while IFS= read -r -d '' file; do
  # check logic per file
  # On failure:
  #   echo "FAIL: $file — reason"
  #   ERRORS=$((ERRORS + 1))
  # On warning (non-fatal):
  #   echo "WARN: $file — reason"
done < <(find "$SRC_DIR" -type f -name "*.ts" -o -name "*.tsx" -print0)

if [ "$ERRORS" -gt 0 ]; then
  echo ""
  echo "Found $ERRORS error(s)"
  exit 1
else
  echo "OK: <Summary message>"
  exit 0
fi
```

### Key Rules

1. **`set -euo pipefail`** — strict mode, always
2. **`SRC_DIR="${1:-src}"`** — configurable source directory
3. **Generic** — no project-specific paths or names. Must work on any codebase
4. **macOS compatible** — use `grep -E` not `grep -P`, no GNU-only flags
5. **No Python** — use `node -e "..."` for complex logic (path resolution, AST)
6. **FAIL vs WARN** — only FAIL increments `ERRORS` and causes exit 1. WARN is informational
7. **Environment variables** for thresholds (e.g. `MAX_FILE_LINES="${MAX_FILE_LINES:-500}"`)
8. **Skip `.d.ts` files** — `! -name "*.d.ts"`
9. **Clear output** — `FAIL: <file> — <reason>` / `WARN: <file> — <reason>` / `OK: <summary>`

### Gotchas

- `grep` returns exit 1 when no match — use `grep -c ... || true` with pipefail
- `grep -o ... | wc -l` fails under pipefail if no matches — use `grep -c` instead
- macOS `find` doesn't support `-regex` well — use `-name` with multiple `-o` flags
- Quote all variables: `"$file"`, `"$SRC_DIR"`

## Registration Checklist

After creating the script, register it in 3 places:

### 1. `.doctor/run.sh`

Add the check name to the `ALL_CHECKS` array:

```bash
ALL_CHECKS=("react/file-naming" "react/component-format" ... "react/<check-name>")
```

### 2. `.github/workflows/doctor.yml`

Add a new step:

```yaml
      - name: <Check display name>
        run: bash .doctor/scripts/react/<check-name>.sh src
```

### 3. `.claude/skills/react-best-practices/SKILL.md`

Add to the "Verification Scripts" numbered list:

```
N. **<Check name>**: `bash .doctor/scripts/react/<check-name>.sh src`
```

Also add a section explaining the convention the script enforces.

## Testing

Before committing, always:

1. Run the script against the real codebase: `bash .doctor/scripts/react/<check-name>.sh src`
2. Verify it catches known violations (if any exist — create a temp file to test if needed)
3. Verify no false positives on clean code
4. Run the full suite: `bash .doctor/run.sh src`
5. Run TypeScript: `npx tsc --noEmit`

## Existing Checks (for reference)

| # | Script | What it checks |
|---|--------|----------------|
| 1 | `file-naming.sh` | kebab-case filenames |
| 2 | `component-format.sh` | `export default function` pattern |
| 3 | `name-match.sh` | filename ↔ export name consistency |
| 4 | `unused-files.sh` | files not imported anywhere |
| 5 | `duplicates.sh` | code duplication (Node.js-based) |
| 6 | `max-file-size.sh` | max 500 lines (warn at 350) |
| 7 | `import-depth.sh` | max 2 `../` levels, no cross-feature |
| 8 | `tailwind-consistency.sh` | `cn()` usage, CSS `@layer` |
| 9 | `index-reexports.sh` | component index files are pure re-exports |
