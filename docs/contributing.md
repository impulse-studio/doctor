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

```bash
bash publish.sh
```

This will:

1. Ask for bump type (patch / minor / major)
2. Ask for changelog entries (empty line to finish)
3. Update `VERSION` and `CHANGELOG.md`
4. Commit, tag, and push

## Project structure

```
.doctor/
  config/
    checks               # Disabled checks (one per line)
    dupe-ignore          # Duplicate detection ignore rules
  run.sh                 # Main runner (executes all checks, --ci for annotations)
  utils/
    list-files.sh        # Shared file discovery (respects .gitignore)
  scripts/
    react/               # React namespace
      *.sh               # Individual checks
      utils/             # Namespace-specific utilities (not checks)
.github/
  workflows/
    doctor.yml           # CI workflow (uses --ci for annotations)
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
