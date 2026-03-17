# Changelog

## 0.0.2
- fix: github workflow running in the origin repository


## 0.0.1
- Gitignore support — checks skip files ignored by `.gitignore` via `git ls-files`
- CI mode (`--ci`) — GitHub Actions `::error` / `::warning` annotations
- Severity levels — warnings no longer fail the build
- `status.sh` — display installed version, checks, workflow, hook, skills
- Shared file discovery utility (`.doctor/utils/list-files.sh`)


## 0.0.0
- Initial release
- React verification scripts: file naming, component format, name matching, unused files, code duplication, max file size, import depth, Tailwind consistency, index re-exports
- GitHub Actions CI workflow
- AI skills: create-best-practice, react-best-practices
- Install/update script via curl | bash
