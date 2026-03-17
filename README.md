# Doctor

Automated code quality checks for your projects. Doctor installs verification scripts, CI workflows, and AI coding skills into your project — and keeps them up to date.

Checks are organized by **namespace** (e.g. `react`, `next`, etc.). Each namespace contains its own set of scripts.

## Quick Install / Update

```bash
curl -fsSL https://raw.githubusercontent.com/impulse-studio/doctor/main/install.sh | bash
```

- **First run**: installs scripts, optionally sets up GitHub CI, git hooks, and AI skills
- **Subsequent runs**: updates scripts automatically, asks before touching workflows or skills

## Available checks

### `react/`

| Check | What it does |
|-------|-------------|
| `react/file-naming` | Enforces kebab-case for files and folders |
| `react/component-format` | One `export default function` per `.tsx` file |
| `react/name-match` | Filename must match export name |
| `react/unused-files` | Detects files not reachable from entry points |
| `react/duplicates` | Multi-technique code duplication detection |
| `react/max-file-size` | Fails above 500 lines, warns above 350 |
| `react/import-depth` | Blocks deep `../../../` imports and cross-feature deps |
| `react/tailwind-consistency` | Conditional classes must use `cn()`, CSS in `@layer` |
| `react/index-reexports` | Index files in component dirs must be pure re-exports |

## Usage

Run all checks:

```bash
bash .doctor/run.sh
```

Run in CI mode (GitHub Actions annotations):

```bash
bash .doctor/run.sh --ci
```

Run a single check:

```bash
bash .doctor/scripts/react/file-naming.sh
```

Check installation status:

```bash
bash status.sh
# or remotely:
curl -fsSL https://raw.githubusercontent.com/impulse-studio/doctor/main/status.sh | bash
```

Disable a check by adding it to `.doctor/config/checks`:

```
react/tailwind-consistency
```

## Skills

- [React Best Practices](skills/react-best-practices/SKILL.md) — project conventions enforced by the checks
- [Create Best Practice](skills/create-best-practice/SKILL.md) — guide for adding new checks

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/impulse-studio/doctor/main/uninstall.sh | bash
```

## Docs

- [Contributing](docs/contributing.md) — adding checks, namespaces, and publishing versions
- [Configuration](docs/configuration.md) — disabling checks, update behavior, project structure
