---
name: react-best-practices
description: Enforces React/TypeScript project conventions including kebab-case file naming, export default function components, one-export-per-file for utilities/constants, no inline constants in components, and proper component structure. Use when creating or modifying React components, TypeScript utilities, or reviewing code structure.
compatibility: Requires bash, grep, find, python3, node, typescript. Designed for React + TypeScript projects using Vite.
allowed-tools: Bash(bash:*) Read
---

# React Best Practices

## File Naming

All source files under `src/` must use **kebab-case**:
- `dashboard-page.tsx` (not `DashboardPage.tsx`)
- `use-invoke.ts` (not `UseInvoke.ts`)
- `agent-store.ts` (not `AgentStore.ts`)

Folders must also be kebab-case. Config files at root keep their tool-imposed names (`vite.config.ts`, `tsconfig.json`).

## Component Format (.tsx)

Every `.tsx` file must follow this structure:

```tsx
import { useState } from "react";
import SomeComponent from "../shared/components/some-component";

interface ComponentNameProps {
  title: string;
  count: number;
}

export default function ComponentName({ title, count }: ComponentNameProps) {
  // hooks, state, logic here

  return (
    <div>...</div>
  );
}
```

Rules:
- **One component per file** — `export default function ComponentName`
- Props interface named `ComponentNameProps` (omit if no props)
- No other interfaces/types allowed (only `ComponentNameProps`)
- No inline sub-components — extract to separate files and import
- **No inline constants/data arrays** — extract to separate `.ts` files (no top-level `const` before the component)
- **No top-level helper functions** — extract to separate `.ts` files (no `function foo()` before the component). Arrow functions inside hooks/callbacks are fine.
- All imports at the top, no dynamic imports
- The component name must match the file name: `dashboard-page.tsx` → `DashboardPage`

### Component Folder Pattern

When a component has related sub-files (style maps, constants, helpers), use a folder with an `index.tsx` re-export:

```
components/
  button/
    index.tsx          # re-export: export { default } from "./button";
    button.tsx         # the actual component
    button-variant-styles.ts
    button-size-styles.ts
  card.tsx             # standalone — no folder needed
```

- `index.tsx` only contains re-exports, no logic
- Standalone components (no sub-files) stay as single files
- Import path stays the same: `import Button from "../shared/components/button"`

## Feature Folder Organization

Feature folders (e.g., `dashboard/`, `transcripts/`) should be organized into **sub-folders by section** when they contain multiple distinct UI sections or concerns:

```
dashboard/
  dashboard-page.tsx       # page-level orchestrator
  stats/
    stats-row.tsx
    stat-placeholders.ts
  activity/
    activity-chart.tsx
    fill-date-gaps.ts
    format-chart-label.ts
    period-to-days.ts
    stat-periods.ts
  recent/
    recent-transcripts.tsx
```

Rules:
- **Group related files** — components + their helpers/constants go in the same sub-folder
- **Page file stays at root** — the page orchestrator (`dashboard-page.tsx`) remains at the feature root
- **Flat is fine for small features** — if a feature has ≤3 files (besides the page), sub-folders are optional
- **Split when sections are distinct** — if a feature has 2+ visually separate sections (e.g., stats row, activity chart, recent list), each section gets its own sub-folder
- Apply this when creating or refactoring feature folders — don't dump all files flat

## Utility & Constant Files (.ts)

Rules:
- **One export per file** — either one function OR one constant OR one type/interface
- No monolith files (no `utils.ts` with 5 functions)
- Prefer folders over single files: `utils/relative-time.ts` over `utils.ts`
- Function files: `export default function functionName`
- Constant files: use camelCase `const name = ...; export default name;`
- **No UPPERCASE/SCREAMING_SNAKE** — since constants are in dedicated sub-files, camelCase is sufficient
- Type files: can export multiple related types/interfaces (they're compile-time only)

Exceptions:
- Store files (zustand) — one store per file with its interface
- API/service layers (e.g., `tauri-commands.ts`) — cohesive API modules are fine
- Event definitions — related event constants + payload types can coexist
- Hook files — one hook per file

## Name Matching

The file name (kebab-case) must convert to the export name:
- `dashboard-page.tsx` → `export default function DashboardPage` (PascalCase for components)
- `relative-time.ts` → `export default function relativeTime` (camelCase for functions)
- `stat-placeholders.ts` → `export default statPlaceholders` (camelCase for constants)

The optional props interface must be: `{ComponentName}Props`
- `dashboard-page.tsx` → `DashboardPageProps` (not `DashboardProps`, `DashPageProps`)

## Conditional ClassNames

Always use the `cn()` utility (`src/shared/lib/utils/cn.ts`) for conditional classNames. It wraps `clsx` + `tailwind-merge` for deduplication and conflict resolution.

```tsx
// GOOD
className={cn("base classes", condition && "conditional", variant === "primary" ? "bg-accent" : "bg-bg-card")}

// BAD — template literals
className={`base ${condition ? "a" : "b"}`}

// BAD — string concatenation
className={"base " + (condition ? "a" : "b")}
```

Rules:
- Static classNames (`className="text-sm"`) are fine without `cn()`
- Any dynamic/conditional className **must** use `cn()`
- Never use template literals or string concatenation for classNames
- CSS files must have all rules inside `@layer` blocks (Tailwind v4 requirement)

## Verification Scripts (.doctor)

Run all checks at once: `bash .doctor/run.sh src`

Or run individually:

1. **File naming**: `bash .doctor/scripts/react/file-naming.sh src`
2. **Component format**: `bash .doctor/scripts/react/component-format.sh src`
3. **Name matching**: `bash .doctor/scripts/react/name-match.sh src`
4. **Unused files**: `bash .doctor/scripts/react/unused-files.sh src`
5. **Code duplication**: `bash .doctor/scripts/react/duplicates.sh src`
6. **Max file size**: `bash .doctor/scripts/react/max-file-size.sh src`
7. **Import depth**: `bash .doctor/scripts/react/import-depth.sh src`
8. **Tailwind consistency**: `bash .doctor/scripts/react/tailwind-consistency.sh src`
9. **Index re-exports**: `bash .doctor/scripts/react/index-reexports.sh src`

CI runs these automatically via `.github/workflows/doctor.yml`.

## Code Duplication

Avoid duplicate or near-duplicate code across the project:

- **Similar functions** — if two functions share the same structure with only different variable names or minor additions, merge them into a single configurable function. Uses token n-gram Jaccard + call signature fingerprinting + semantic TF-IDF filtering.
  - Type 1: exact copy-paste
  - Type 2: same structure with renamed variables
  - Type 3: similar structure with added/removed statements
  - Semantic filter: structurally similar code that serves a different purpose is skipped (e.g., `formatDuration` vs `formatMinutes`)
- **Similar sub-blocks** — if the same 3+ line pattern appears in multiple functions, extract it into a shared utility. Hook/store boilerplate lines are filtered out.
- **Hook reuse** — if a component uses `useEffect` + calls APIs that a shared custom hook already wraps, refactor to use the hook instead of reimplementing the pattern.
- **Overlapping types** — if two interfaces share 70%+ of their fields, consider merging into a base type with extensions.
- **Magic strings** — hardcoded identifier-like strings (`kebab-case`, `camelCase`, `snake_case`, dot notation, special chars like `alt+space`) repeated in 2+ files should be extracted to constants. Plain-text strings are flagged at 4+ files.

Tune detection thresholds via environment variables:
- `DUPE_FUNC_THRESHOLD` — min similarity for functions (default `0.70`, range 0.0–1.0)
- `DUPE_BLOCK_THRESHOLD` — min similarity for sub-blocks (default `0.80`)
- `DUPE_TYPE_THRESHOLD` — min field overlap for types (default `0.70`)
- `DUPE_SEM_THRESHOLD` — min semantic similarity to keep a match (default `0.50`)
- `DUPE_MIN_STMTS` — min statements to consider a function (default `3`)
- `DUPE_BLOCK_WINDOW` — sub-block sliding window size (default `3`)
- `DUPE_MAX_RESULTS` — max reported duplications (default `50`)

Use `--verbose` flag to see the actual code, semantic descriptions, and field details.
Use `--no-cache` to bypass the file-level cache (`.cache/react-checks/duplicates/`).

### Ignoring False Positives

Edit `.doctor/config/dupe-ignore` to suppress known false positives. This file is committed to git and shared across team/CI. Format:

```
MAGIC:very-high         # not a real identifier, just an enum variant
DUPE:LoginForm/RegisterForm  # intentionally similar, different domains
TYPE:ModelStatus/ModelInfo    # keep separate for API boundaries
BLOCK:parentA/parentB
HOOK:useTauriEvent/Widget
```

Lines starting with `#` are comments. Pair rules match in either order.
