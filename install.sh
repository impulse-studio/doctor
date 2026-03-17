#!/usr/bin/env bash
set -euo pipefail

# ─── Constants ───────────────────────────────────────────────
REPO="impulse-studio/doctor"
REPO_URL="https://github.com/$REPO"
BRANCH="main"
DOCTORRC=".doctor/config/.doctorrc"
SKILL_PLATFORMS_AVAILABLE=("claude" "cursor" "windsurf" "codex")

# ─── Colors (disabled if not a terminal) ────────────────────
if [ -t 1 ] || [ -t 2 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
  BLUE='\033[0;34m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; DIM=''; RESET=''
fi

# ─── Logging ────────────────────────────────────────────────
info()    { printf "${BLUE}[doctor]${RESET} %s\n" "$1"; }
ok()      { printf "${GREEN}[doctor]${RESET} %s\n" "$1"; }
warn()    { printf "${YELLOW}[doctor]${RESET} %s\n" "$1"; }
err()     { printf "${RED}[doctor]${RESET} %s\n" "$1" >&2; }
section() { printf "\n${BOLD}%s${RESET}\n" "$1"; }

# ─── Portable hashing ───────────────────────────────────────
hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    err "No sha256sum or shasum found"; exit 1
  fi
}

hash_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

files_identical() {
  [ -f "$1" ] && [ -f "$2" ] && [ "$(hash_file "$1")" = "$(hash_file "$2")" ]
}

# ─── User prompts (read from /dev/tty for curl|bash compat) ─
can_prompt() {
  [ -e /dev/tty ] && return 0 || return 1
}

ask_yes_no() {
  local prompt="$1" default="${2:-y}"
  local hint="[Y/n]"
  [ "$default" = "n" ] && hint="[y/N]"

  if ! can_prompt; then
    [ "$default" = "y" ] && return 0 || return 1
  fi

  printf "${BOLD}[doctor]${RESET} %s %s " "$prompt" "$hint"
  local answer
  read -r answer </dev/tty
  answer="${answer:-$default}"
  case "$answer" in
    [Yy]*) return 0 ;;
    *) return 1 ;;
  esac
}

ask_multi_select() {
  local prompt="$1"; shift
  local options=("$@")
  REPLY=""

  if ! can_prompt; then
    REPLY=$(IFS=,; echo "${options[*]}")
    return 0
  fi

  info "$prompt"
  for i in "${!options[@]}"; do
    printf "  ${BOLD}%d)${RESET} %s\n" "$((i + 1))" "${options[$i]}"
  done
  printf "${BOLD}[doctor]${RESET} Enter numbers (e.g. 1,3,4) or 'all': "
  local answer
  read -r answer </dev/tty

  if [ "$answer" = "all" ] || [ "$answer" = "a" ]; then
    REPLY=$(IFS=,; echo "${options[*]}")
    return 0
  fi

  local selected=()
  IFS=',' read -ra nums <<< "$answer"
  for num in "${nums[@]}"; do
    num=$(echo "$num" | tr -d ' ')
    if [ "$num" -ge 1 ] 2>/dev/null && [ "$num" -le "${#options[@]}" ] 2>/dev/null; then
      selected+=("${options[$((num - 1))]}")
    fi
  done

  if [ "${#selected[@]}" -eq 0 ]; then
    return 1
  fi

  REPLY=$(IFS=,; echo "${selected[*]}")
  return 0
}

# ─── .doctorrc reader/writer ────────────────────────────────
read_rc() {
  local key="$1" default="${2:-}"
  if [ -f "$DOCTORRC" ]; then
    local val
    val=$(grep "^${key}=" "$DOCTORRC" 2>/dev/null | head -1 | cut -d'=' -f2-) || true
    echo "${val:-$default}"
  else
    echo "$default"
  fi
}

write_rc() {
  local key="$1" value="$2"
  mkdir -p "$(dirname "$DOCTORRC")"
  if [ -f "$DOCTORRC" ] && grep -q "^${key}=" "$DOCTORRC" 2>/dev/null; then
    local tmp="${DOCTORRC}.tmp"
    sed "s|^${key}=.*|${key}=${value}|" "$DOCTORRC" > "$tmp"
    mv "$tmp" "$DOCTORRC"
  else
    echo "${key}=${value}" >> "$DOCTORRC"
  fi
}

# ─── Semver comparison ──────────────────────────────────────
version_gt() {
  # Returns 0 if $1 > $2
  local v1="$1" v2="$2"
  [ "$v1" = "$v2" ] && return 1

  local IFS='.'
  read -ra a <<< "$v1"
  read -ra b <<< "$v2"

  for i in 0 1 2; do
    local n1="${a[$i]:-0}" n2="${b[$i]:-0}"
    if [ "$n1" -gt "$n2" ] 2>/dev/null; then return 0; fi
    if [ "$n1" -lt "$n2" ] 2>/dev/null; then return 1; fi
  done
  return 1
}

# ─── SKILL.md frontmatter parsing ───────────────────────────
extract_frontmatter_field() {
  local file="$1" field="$2"
  awk '/^---$/{n++; next} n==1{print}' "$file" \
    | grep "^${field}:" \
    | sed "s/^${field}:[[:space:]]*//"
}

extract_content_after_frontmatter() {
  awk 'BEGIN{n=0} /^---$/{n++; if(n==2){found=1; next}} found{print}' "$1"
}

# ─── Download repo ──────────────────────────────────────────
DOWNLOAD_DIR=""
CLEANUP_DIR=""

cleanup() {
  [ -n "$CLEANUP_DIR" ] && rm -rf "$CLEANUP_DIR"
}

download_repo() {
  local tmp_dir
  tmp_dir=$(mktemp -d) || { err "Failed to create temp dir"; exit 1; }
  CLEANUP_DIR="$tmp_dir"
  trap cleanup EXIT

  info "Downloading doctor from $REPO..."

  if ! curl -fsSL "${REPO_URL}/archive/refs/heads/${BRANCH}.tar.gz" \
       -o "$tmp_dir/doctor.tar.gz" 2>/dev/null; then
    err "Failed to download. Check your internet connection."
    exit 1
  fi

  tar -xzf "$tmp_dir/doctor.tar.gz" -C "$tmp_dir" 2>/dev/null \
    || { err "Failed to extract archive"; exit 1; }

  DOWNLOAD_DIR="$tmp_dir/doctor-${BRANCH}"

  if [ ! -d "$DOWNLOAD_DIR" ]; then
    # Fallback: find the first directory
    DOWNLOAD_DIR=$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d | head -1)
  fi

  if [ ! -d "$DOWNLOAD_DIR/.doctor" ]; then
    err "Downloaded archive does not contain .doctor/ directory"
    exit 1
  fi
}

# ─── Get remote commit hash ────────────────────────────────
get_remote_commit() {
  if command -v git >/dev/null 2>&1; then
    git ls-remote "$REPO_URL" HEAD 2>/dev/null | cut -f1 | head -c 7 || echo "unknown"
  else
    echo "unknown"
  fi
}

# ─── Skill installation per platform ───────────────────────
skill_path_for_platform() {
  local platform="$1" skill_name="$2"
  case "$platform" in
    windsurf) echo ".windsurf/rules/${skill_name}.md" ;;
    codex)    echo ".codex/skills/${skill_name}/SKILL.md" ;;
    *)        echo ".${platform}/skills/${skill_name}/SKILL.md" ;;
  esac
}

install_skill_for_platform() {
  local platform="$1" skill_name="$2" skill_file="$3"
  local dest
  dest=$(skill_path_for_platform "$platform" "$skill_name")

  mkdir -p "$(dirname "$dest")"

  case "$platform" in
    windsurf)
      # Windsurf: flat .md, content only (no source frontmatter)
      extract_content_after_frontmatter "$skill_file" > "$dest"
      ;;
    *)
      # Claude, Cursor, Codex, etc: copy SKILL.md as-is
      cp "$skill_file" "$dest"
      ;;
  esac
}

generate_skill_content() {
  local platform="$1" skill_name="$2" skill_file="$3"
  case "$platform" in
    windsurf)
      extract_content_after_frontmatter "$skill_file"
      ;;
    *)
      cat "$skill_file"
      ;;
  esac
}

# ─── Fresh install ──────────────────────────────────────────
install_doctor_dir() {
  info "Installing .doctor/ scripts and configs..."

  if [ -d ".doctor" ]; then
    # Partial install exists — merge carefully
    # Copy scripts (overwrite)
    cp -R "$DOWNLOAD_DIR/.doctor/scripts" .doctor/
    cp -R "$DOWNLOAD_DIR/.doctor/utils" .doctor/
    cp "$DOWNLOAD_DIR/.doctor/run.sh" .doctor/run.sh
    # Copy configs that don't exist yet
    for f in "$DOWNLOAD_DIR"/.doctor/config/*; do
      [ -f "$f" ] || continue
      local basename
      basename=$(basename "$f")
      [ -f ".doctor/config/$basename" ] || cp "$f" ".doctor/config/$basename"
    done
  else
    cp -R "$DOWNLOAD_DIR/.doctor" ./.doctor
  fi

  chmod +x .doctor/run.sh
  find .doctor/scripts -name "*.sh" -exec chmod +x {} \;
  find .doctor/utils -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

  ok "Scripts and configs installed"
}

WORKFLOWS_ENABLED="false"

install_workflows_interactive() {
  section "GitHub CI Workflow"

  if ask_yes_no "Install GitHub CI workflow? (.github/workflows/doctor.yml)" "y"; then
    mkdir -p .github/workflows
    cp "$DOWNLOAD_DIR/.github/workflows/doctor.yml" .github/workflows/doctor.yml
    WORKFLOWS_ENABLED="true"
    ok "Workflow installed"
  else
    WORKFLOWS_ENABLED="false"
    info "Skipped workflow installation"
  fi
}

HOOKS_ENABLED="false"
DOCTOR_HOOK_MARKER="# doctor:hook"

install_hooks_interactive() {
  section "Git Hook"

  if ! ask_yes_no "Add doctor checks to pre-commit hook?" "y"; then
    HOOKS_ENABLED="false"
    info "Skipped git hook installation"
    return
  fi

  install_hook
  HOOKS_ENABLED="true"
  ok "Git hook installed"
}

install_hook() {
  local hook_line="bash .doctor/run.sh src ${DOCTOR_HOOK_MARKER}"

  if [ -d ".husky" ]; then
    # Husky detected
    local hook_file=".husky/pre-commit"
    if [ -f "$hook_file" ] && grep -qF "$DOCTOR_HOOK_MARKER" "$hook_file" 2>/dev/null; then
      return  # already present
    fi
    # Append to existing hook or create it
    echo "$hook_line" >> "$hook_file"
    chmod +x "$hook_file"
    info "  Added to .husky/pre-commit"
  elif [ -d ".git" ]; then
    # Plain git hook
    local hook_file=".git/hooks/pre-commit"
    if [ -f "$hook_file" ] && grep -qF "$DOCTOR_HOOK_MARKER" "$hook_file" 2>/dev/null; then
      return  # already present
    fi
    mkdir -p .git/hooks
    if [ ! -f "$hook_file" ]; then
      echo "#!/usr/bin/env bash" > "$hook_file"
    fi
    echo "$hook_line" >> "$hook_file"
    chmod +x "$hook_file"
    info "  Added to .git/hooks/pre-commit"
  else
    warn "No .husky/ or .git/ found, skipping hook"
    HOOKS_ENABLED="false"
  fi
}

remove_hook() {
  for hook_file in ".husky/pre-commit" ".git/hooks/pre-commit"; do
    if [ -f "$hook_file" ] && grep -qF "$DOCTOR_HOOK_MARKER" "$hook_file" 2>/dev/null; then
      local tmp="${hook_file}.tmp"
      grep -vF "$DOCTOR_HOOK_MARKER" "$hook_file" > "$tmp"
      mv "$tmp" "$hook_file"
      chmod +x "$hook_file"
    fi
  done
}

SKILLS_PLATFORMS=""

install_skills_interactive() {
  section "AI Coding Skills"

  if ! ask_yes_no "Install AI coding skills?" "y"; then
    SKILLS_PLATFORMS=""
    info "Skipped skills installation"
    return
  fi

  if ! ask_multi_select "Select AI platforms:" "${SKILL_PLATFORMS_AVAILABLE[@]}"; then
    SKILLS_PLATFORMS=""
    info "No platforms selected, skipping skills"
    return
  fi
  SKILLS_PLATFORMS="$REPLY"

  for skill_dir in "$DOWNLOAD_DIR"/skills/*/; do
    [ -d "$skill_dir" ] || continue
    local skill_name
    skill_name=$(basename "$skill_dir")
    local skill_file="$skill_dir/SKILL.md"
    [ -f "$skill_file" ] || continue

    IFS=',' read -ra plat_arr <<< "$SKILLS_PLATFORMS"
    for platform in "${plat_arr[@]}"; do
      platform=$(echo "$platform" | tr -d ' ')
      install_skill_for_platform "$platform" "$skill_name" "$skill_file"
    done
  done

  ok "Skills installed for: $SKILLS_PLATFORMS"
}

fresh_install() {
  section "Fresh Install (v${REMOTE_VERSION})"

  install_doctor_dir
  install_workflows_interactive
  install_hooks_interactive
  install_skills_interactive

  # Write state
  local commit_hash
  commit_hash=$(get_remote_commit)
  write_rc "DOCTOR_VERSION" "$REMOTE_VERSION"
  write_rc "DOCTOR_COMMIT" "$commit_hash"
  write_rc "WORKFLOWS_ENABLED" "$WORKFLOWS_ENABLED"
  write_rc "HOOKS_ENABLED" "$HOOKS_ENABLED"
  write_rc "SKILLS_PLATFORMS" "$SKILLS_PLATFORMS"

  section "Done!"
  ok "Doctor v${REMOTE_VERSION} installed successfully!"
  info "Run checks:  bash .doctor/run.sh src"
}

# ─── Update mode ────────────────────────────────────────────
show_changelog_diff() {
  local from_version="$1"
  local changelog="$DOWNLOAD_DIR/CHANGELOG.md"

  if [ ! -f "$changelog" ]; then
    return
  fi

  info "Changes:"
  echo ""

  # Print all changelog entries for versions newer than from_version
  awk -v from="$from_version" '
    /^## / {
      ver = $2
      if (ver == from) { printing = 0; next }
      else { printing = 1 }
    }
    printing { print "  " $0 }
  ' "$changelog"
  echo ""
}

update_scripts() {
  section "Scripts"

  local updated=()

  # Update run.sh
  if [ -f ".doctor/run.sh" ]; then
    if ! files_identical ".doctor/run.sh" "$DOWNLOAD_DIR/.doctor/run.sh"; then
      cp "$DOWNLOAD_DIR/.doctor/run.sh" ".doctor/run.sh"
      chmod +x ".doctor/run.sh"
      updated+=(".doctor/run.sh")
    fi
  fi

  # Update all scripts
  while IFS= read -r remote_file; do
    local rel_path="${remote_file#$DOWNLOAD_DIR/}"
    local local_file="./$rel_path"

    if [ ! -f "$local_file" ]; then
      mkdir -p "$(dirname "$local_file")"
      cp "$remote_file" "$local_file"
      [ "${local_file##*.}" = "sh" ] && chmod +x "$local_file"
      updated+=("$rel_path ${DIM}(new)${RESET}")
    elif ! files_identical "$local_file" "$remote_file"; then
      cp "$remote_file" "$local_file"
      [ "${local_file##*.}" = "sh" ] && chmod +x "$local_file"
      updated+=("$rel_path")
    fi
  done < <(find "$DOWNLOAD_DIR/.doctor/scripts" "$DOWNLOAD_DIR/.doctor/utils" -type f 2>/dev/null)

  if [ "${#updated[@]}" -eq 0 ]; then
    ok "Scripts: already up to date"
  else
    ok "Scripts: ${#updated[@]} file(s) updated"
    for f in "${updated[@]}"; do
      printf "  ${DIM}~${RESET} %b\n" "$f"
    done
  fi
}

update_configs() {
  section "Configs"

  local added=()

  while IFS= read -r remote_file; do
    local basename
    basename=$(basename "$remote_file")
    local local_file=".doctor/config/$basename"

    # Never overwrite .doctorrc
    [ "$basename" = ".doctorrc" ] && continue

    if [ ! -f "$local_file" ]; then
      mkdir -p "$(dirname "$local_file")"
      cp "$remote_file" "$local_file"
      added+=("$basename")
    fi
  done < <(find "$DOWNLOAD_DIR/.doctor/config" -type f 2>/dev/null)

  if [ "${#added[@]}" -eq 0 ]; then
    ok "Configs: no new files"
  else
    ok "Configs: ${#added[@]} new file(s) added"
    for f in "${added[@]}"; do
      printf "  ${DIM}+${RESET} %s\n" "$f"
    done
  fi
}

update_workflows() {
  section "Workflow"

  local enabled
  enabled=$(read_rc "WORKFLOWS_ENABLED" "false")

  if [ "$enabled" != "true" ]; then
    if [ -f "$DOWNLOAD_DIR/.github/workflows/doctor.yml" ]; then
      if ask_yes_no "GitHub CI workflow available but not installed. Install?" "n"; then
        mkdir -p .github/workflows
        cp "$DOWNLOAD_DIR/.github/workflows/doctor.yml" .github/workflows/doctor.yml
        write_rc "WORKFLOWS_ENABLED" "true"
        ok "Workflow installed"
      else
        info "Workflow: skipped"
      fi
    fi
    return
  fi

  local remote_wf="$DOWNLOAD_DIR/.github/workflows/doctor.yml"
  local local_wf=".github/workflows/doctor.yml"

  if [ ! -f "$local_wf" ]; then
    mkdir -p .github/workflows
    cp "$remote_wf" "$local_wf"
    ok "Workflow: reinstalled (was missing)"
    return
  fi

  if files_identical "$local_wf" "$remote_wf"; then
    ok "Workflow: already up to date"
    return
  fi

  warn "Workflow has been updated upstream"
  if ask_yes_no "Update .github/workflows/doctor.yml?" "y"; then
    cp "$remote_wf" "$local_wf"
    ok "Workflow: updated"
  else
    info "Workflow: kept current version"
  fi
}

update_hooks() {
  section "Git Hook"

  local enabled
  enabled=$(read_rc "HOOKS_ENABLED" "false")

  if [ "$enabled" != "true" ]; then
    if ask_yes_no "Git pre-commit hook available but not installed. Install?" "n"; then
      install_hook
      write_rc "HOOKS_ENABLED" "true"
      ok "Git hook installed"
    else
      info "Hook: skipped"
    fi
    return
  fi

  # Hook is enabled — make sure it's still present (could have been removed by husky reinstall etc.)
  local found=false
  for hook_file in ".husky/pre-commit" ".git/hooks/pre-commit"; do
    if [ -f "$hook_file" ] && grep -qF "$DOCTOR_HOOK_MARKER" "$hook_file" 2>/dev/null; then
      found=true
      break
    fi
  done

  if [ "$found" = "false" ]; then
    install_hook
    ok "Hook: reinstalled (was missing)"
  else
    ok "Hook: already installed"
  fi
}

update_skills() {
  section "Skills"

  local platforms
  platforms=$(read_rc "SKILLS_PLATFORMS" "")

  if [ -z "$platforms" ]; then
    if [ -d "$DOWNLOAD_DIR/skills" ]; then
      if ask_yes_no "AI skills available but not installed. Install?" "n"; then
        install_skills_interactive
        write_rc "SKILLS_PLATFORMS" "$SKILLS_PLATFORMS"
      else
        info "Skills: skipped"
      fi
    fi
    return
  fi

  local skill_updated=0
  local skill_skipped=0

  for skill_dir in "$DOWNLOAD_DIR"/skills/*/; do
    [ -d "$skill_dir" ] || continue
    local skill_name
    skill_name=$(basename "$skill_dir")
    local remote_skill="$skill_dir/SKILL.md"
    [ -f "$remote_skill" ] || continue

    IFS=',' read -ra plat_arr <<< "$platforms"
    for platform in "${plat_arr[@]}"; do
      platform=$(echo "$platform" | tr -d ' ')
      local local_skill
      local_skill=$(skill_path_for_platform "$platform" "$skill_name")

      if [ ! -f "$local_skill" ]; then
        # New skill — install silently
        install_skill_for_platform "$platform" "$skill_name" "$remote_skill"
        ok "  + Added: ${skill_name} (${platform})"
        skill_updated=$((skill_updated + 1))
        continue
      fi

      # Compare what the file should look like vs what it is
      local expected_hash current_hash
      expected_hash=$(generate_skill_content "$platform" "$skill_name" "$remote_skill" | hash_stdin)
      current_hash=$(hash_file "$local_skill")

      if [ "$current_hash" != "$expected_hash" ]; then
        if ask_yes_no "  Skill '${skill_name}' (${platform}) has changed. Update?" "y"; then
          install_skill_for_platform "$platform" "$skill_name" "$remote_skill"
          ok "  ~ Updated: ${skill_name} (${platform})"
          skill_updated=$((skill_updated + 1))
        else
          info "  Kept: ${skill_name} (${platform})"
          skill_skipped=$((skill_skipped + 1))
        fi
      fi
    done
  done

  if [ "$skill_updated" -eq 0 ] && [ "$skill_skipped" -eq 0 ]; then
    ok "Skills: already up to date"
  elif [ "$skill_updated" -gt 0 ]; then
    ok "Skills: ${skill_updated} updated"
  fi
}

update_mode() {
  local LOCAL_VERSION
  LOCAL_VERSION=$(read_rc "DOCTOR_VERSION" "0.0.0")

  if [ "$LOCAL_VERSION" = "$REMOTE_VERSION" ]; then
    ok "Already up to date (v${LOCAL_VERSION})"
    return
  fi

  if ! version_gt "$REMOTE_VERSION" "$LOCAL_VERSION"; then
    warn "Local version (${LOCAL_VERSION}) is newer than remote (${REMOTE_VERSION}). Skipping."
    return
  fi

  section "Update available: v${LOCAL_VERSION} → v${REMOTE_VERSION}"
  show_changelog_diff "$LOCAL_VERSION"

  if ! ask_yes_no "Proceed with update?" "y"; then
    info "Update cancelled"
    return
  fi

  update_scripts
  update_configs
  update_workflows
  update_hooks
  update_skills

  # Update state
  local commit_hash
  commit_hash=$(get_remote_commit)
  write_rc "DOCTOR_VERSION" "$REMOTE_VERSION"
  write_rc "DOCTOR_COMMIT" "$commit_hash"

  section "Done!"
  ok "Doctor updated to v${REMOTE_VERSION}!"
}

# ─── Main ───────────────────────────────────────────────────
main() {
  printf "\n${BOLD}  doctor${RESET} ${DIM}— code quality tools by impulse-studio${RESET}\n\n"

  download_repo

  REMOTE_VERSION=$(cat "$DOWNLOAD_DIR/VERSION" 2>/dev/null | tr -d '[:space:]' || echo "0.0.0")

  if [ -d ".doctor" ] && [ -f "$DOCTORRC" ]; then
    update_mode
  else
    fresh_install
  fi
}

main "$@"
