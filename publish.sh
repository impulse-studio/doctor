#!/usr/bin/env bash
set -euo pipefail

# ─── Constants ───────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION_FILE="$SCRIPT_DIR/VERSION"
CHANGELOG_FILE="$SCRIPT_DIR/CHANGELOG.md"

# ─── Colors ─────────────────────────────────────────────────
if [ -t 1 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
  BLUE='\033[0;34m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; DIM=''; RESET=''
fi

info()    { printf "${BLUE}[doctor]${RESET} %s\n" "$1"; }
ok()      { printf "${GREEN}[doctor]${RESET} %s\n" "$1"; }
warn()    { printf "${YELLOW}[doctor]${RESET} %s\n" "$1"; }
err()     { printf "${RED}[doctor]${RESET} %s\n" "$1" >&2; }

ask_yes_no() {
  local prompt="$1" default="${2:-y}"
  local hint="[Y/n]"
  [ "$default" = "n" ] && hint="[y/N]"
  printf "${BOLD}[doctor]${RESET} %s %s " "$prompt" "$hint"
  local answer
  read -r answer
  answer="${answer:-$default}"
  case "$answer" in
    [Yy]*) return 0 ;;
    *) return 1 ;;
  esac
}

# ─── Read current version ───────────────────────────────────
if [ -f "$VERSION_FILE" ]; then
  CURRENT=$(tr -d '[:space:]' < "$VERSION_FILE")
else
  CURRENT="0.0.0"
fi

printf "\n${BOLD}  doctor publish${RESET}\n\n"
info "Current version: v${CURRENT}"

# ─── Check for uncommitted changes ─────────────────────────
if command -v git >/dev/null 2>&1; then
  if ! git -C "$SCRIPT_DIR" diff --quiet 2>/dev/null || \
     ! git -C "$SCRIPT_DIR" diff --cached --quiet 2>/dev/null; then
    warn "You have uncommitted changes."
    if ! ask_yes_no "Continue anyway? (changes will be included in the release commit)" "y"; then
      info "Aborted. Commit or stash your changes first."
      exit 0
    fi
  fi
fi

# ─── Ask bump type ──────────────────────────────────────────
echo ""
printf "  ${BOLD}1)${RESET} patch  ${DIM}(bug fixes, script tweaks)${RESET}\n"
printf "  ${BOLD}2)${RESET} minor  ${DIM}(new scripts, new features)${RESET}\n"
printf "  ${BOLD}3)${RESET} major  ${DIM}(breaking changes)${RESET}\n"
echo ""
printf "${BOLD}[doctor]${RESET} Select bump type [1/2/3]: "
read -r bump_choice

IFS='.' read -ra parts <<< "$CURRENT"
major="${parts[0]:-0}"
minor="${parts[1]:-0}"
patch="${parts[2]:-0}"

case "$bump_choice" in
  1|patch)  patch=$((patch + 1)) ;;
  2|minor)  minor=$((minor + 1)); patch=0 ;;
  3|major)  major=$((major + 1)); minor=0; patch=0 ;;
  *) err "Invalid choice"; exit 1 ;;
esac

NEW_VERSION="${major}.${minor}.${patch}"
info "New version: v${NEW_VERSION}"

# ─── Collect changelog entries ──────────────────────────────
echo ""
info "Enter changelog entries (empty line to finish):"
entries=()
while true; do
  printf "  - "
  read -r entry
  [ -z "$entry" ] && break
  # Strip leading "- " or "* " if user pasted a markdown list
  entry="${entry#- }"
  entry="${entry#\* }"
  entries+=("$entry")
done

if [ "${#entries[@]}" -eq 0 ]; then
  err "At least one changelog entry is required"
  exit 1
fi

# ─── Update VERSION ────────────────────────────────────────
echo "$NEW_VERSION" > "$VERSION_FILE"
ok "Updated VERSION to ${NEW_VERSION}"

# ─── Update CHANGELOG.md ───────────────────────────────────
changelog_block="## ${NEW_VERSION}"$'\n'
for entry in "${entries[@]}"; do
  changelog_block+="- ${entry}"$'\n'
done
changelog_block+=$'\n'

tmp_changelog=$(mktemp)
if [ -f "$CHANGELOG_FILE" ]; then
  # Insert new block after "# Changelog" header, keep the rest
  echo "# Changelog" > "$tmp_changelog"
  echo "" >> "$tmp_changelog"
  printf '%s' "$changelog_block" >> "$tmp_changelog"
  # Append everything after the first line from the original
  tail -n +2 "$CHANGELOG_FILE" >> "$tmp_changelog"
else
  echo "# Changelog" > "$tmp_changelog"
  echo "" >> "$tmp_changelog"
  printf '%s' "$changelog_block" >> "$tmp_changelog"
fi
mv "$tmp_changelog" "$CHANGELOG_FILE"
ok "Updated CHANGELOG.md"

# ─── Preview ───────────────────────────────────────────────
echo ""
info "Changelog entry:"
for entry in "${entries[@]}"; do
  printf "  - %s\n" "$entry"
done

# ─── Git operations ────────────────────────────────────────
if ! command -v git >/dev/null 2>&1; then
  warn "git not found. Please commit, tag, and push manually."
  exit 0
fi

echo ""
if ! ask_yes_no "Commit and tag v${NEW_VERSION}?" "y"; then
  info "Files updated but not committed. Run manually:"
  echo "  git add VERSION CHANGELOG.md"
  echo "  git commit -m \"release: v${NEW_VERSION}\""
  echo "  git tag -a v${NEW_VERSION} -m \"v${NEW_VERSION}\""
  exit 0
fi

cd "$SCRIPT_DIR"
git add -A
git commit -m "release: v${NEW_VERSION}"
git tag -a "v${NEW_VERSION}" -m "v${NEW_VERSION}"
ok "Committed and tagged v${NEW_VERSION}"

echo ""
if ask_yes_no "Push to remote?" "y"; then
  git push && git push --tags
  ok "Pushed v${NEW_VERSION}!"
else
  info "Not pushed. Run manually:"
  echo "  git push && git push --tags"
fi
