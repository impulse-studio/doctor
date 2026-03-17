# Configuration

## Disabling checks

Edit `.doctor/config/checks` to disable specific checks. Add one check per line:

```
# Disable Tailwind check (not using Tailwind in this project)
react/tailwind-consistency

# Disable file size limit
react/max-file-size
```

Empty file or no file = all checks run.

## Update behavior

When you re-run `install.sh`:

| File type | Behavior |
|-----------|----------|
| Scripts (`.doctor/scripts/`, `.doctor/utils/`, `.doctor/run.sh`) | Updated automatically |
| Configs (`.doctor/config/*`) | Never overwritten, new files added |
| GitHub workflow | Asks before updating |
| Git hook (husky or plain) | Reinstalled if missing |
| AI skills | Asks before updating |

State is tracked in `.doctor/config/.doctorrc`.

## Check for updates without installing

```bash
curl -fsSL https://raw.githubusercontent.com/impulse-studio/doctor/main/check-updates.sh | bash
```

Exit codes: `0` = up to date, `1` = updates available, `2` = error.

## CI mode

Run with `--ci` to emit GitHub Actions annotations (`::error` / `::warning`) alongside normal output:

```bash
bash .doctor/run.sh --ci
```

CI mode is also auto-detected when `CI=true` (set by GitHub Actions). Warnings (`WARN:` lines) produce `::warning` annotations but do not fail the build. Errors (`FAIL:`, `UNUSED:`, `DUPE:`) produce `::error` annotations and fail the build.

## GitHub CI

The optional workflow (`.github/workflows/doctor.yml`) runs all checks on push to `main` and on pull requests with `--ci` for annotations. It also checks for doctor updates in a parallel job.

## AI Skills

Skills teach AI coding assistants your project conventions. Supported platforms:

| Platform | Install path |
|----------|-------------|
| Claude | `.claude/skills/<name>/SKILL.md` |
| Cursor | `.cursor/skills/<name>/SKILL.md` |
| Codex | `.codex/skills/<name>/SKILL.md` |
| Windsurf | `.windsurf/rules/<name>.md` |

## Gitignore support

All checks respect `.gitignore`. Files in ignored directories (`node_modules`, `dist`, etc.) are automatically excluded. This uses `git ls-files` when running inside a git repository, with a fallback to `find` with hardcoded exclusions outside of git.

## Git hook

Doctor can add a `pre-commit` hook that runs all checks before each commit. It auto-detects husky (`.husky/pre-commit`) or falls back to `.git/hooks/pre-commit`.

## Status

Check installation status:

```bash
bash status.sh
# or remotely:
curl -fsSL https://raw.githubusercontent.com/impulse-studio/doctor/main/status.sh | bash
```

Shows installed version, active/disabled checks, workflow, hook, and skill platforms.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/impulse-studio/doctor/main/uninstall.sh | bash
```

Lists everything that will be removed (scripts, configs, workflows, skills, hook lines) and asks for confirmation before deleting.
