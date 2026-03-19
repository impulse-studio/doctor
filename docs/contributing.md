# Contributing

## Adding a new check

1. Create `.doctor/scripts/<namespace>/<name>.sh`
2. Register it in `.doctor/run.sh` (`ALL_CHECKS` array as `<namespace>/<name>`)
3. Optionally, document it in an existing skill or create a new one

See the [Create Best Practice](../skills/create-best-practice/SKILL.md) skill for a full script template and registration checklist.

## Adding a new namespace

Namespaces group related checks (e.g. `react`, `next`, `node`).

1. Create the directory `.doctor/scripts/<namespace>/`
2. Add your scripts there (one `.sh` per check)
3. Add entries to `ALL_CHECKS` in `.doctor/run.sh` as `<namespace>/<name>`

You don't need a skill or any other configuration — just the scripts and the registration.

## Publishing a new version

Interactive mode:

```bash
bash publish.sh
```

Non-interactive mode (AI-compatible):

```bash
bash publish.sh --bump patch --push "fix: github workflow" "feat: configurable entry points"
```

Options:
- `--bump <patch|minor|major>` — version bump type (activates non-interactive mode)
- `--push` — push to remote after commit+tag (no confirmation)
- Positional arguments are changelog entries

This will:

1. Bump the version in `VERSION`
2. Prepend entries to `CHANGELOG.md`
3. Commit, tag, and push

## Project structure

```
.doctor/
  config/
    checks               # Disabled checks (one per line)
    dupe-ignore          # Duplicate detection ignore rules
    entry-points         # Entry points for unused-files check
    max-file-size        # Line count thresholds (default + per-file overrides)
  run.sh                 # Main runner (executes all checks, --ci for annotations)
  utils/
    list-files.sh        # Shared file discovery (respects .gitignore)
  scripts/
    react/               # React namespace
      *.sh               # Individual checks
      utils/             # Namespace-specific utilities (not checks)
workflows/
  doctor.yml             # CI workflow template (installed to .github/workflows/)
skills/
  react-best-practices/
    SKILL.md
  create-best-practice/
    SKILL.md
docs/                    # Documentation
install.sh               # Install/update script
check-updates.sh         # Dry-run update check
status.sh                # Show installation status
uninstall.sh             # Clean removal
publish.sh               # Version publishing tool
VERSION                  # Current version
CHANGELOG.md             # Version history
```
