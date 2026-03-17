#!/usr/bin/env bash
set -euo pipefail

# ─── Constants ───────────────────────────────────────────────
DOCTORRC=".doctor/config/.doctorrc"
DOCTOR_HOOK_MARKER="# doctor:hook"

# ─── Colors ─────────────────────────────────────────────────
if [ -t 1 ] || [ -t 2 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
  BLUE='\033[0;34m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; DIM=''; RESET=''
fi

info()    { printf "${BLUE}[doctor]${RESET} %s\n" "$1"; }
ok()      { printf "${GREEN}[doctor]${RESET} %s\n" "$1"; }
warn()    { printf "${YELLOW}[doctor]${RESET} %s\n" "$1"; }
err()     { printf "${RED}[doctor]${RESET} %s\n" "$1" >&2; }

# ─── .doctorrc reader ───────────────────────────────────────
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

# ─── Skill path per platform ───────────────────────────────
skill_path_for_platform() {
  local platform="$1" skill_name="$2"
  case "$platform" in
    windsurf) echo ".windsurf/rules/${skill_name}.md" ;;
    codex)    echo ".codex/skills/${skill_name}/SKILL.md" ;;
    *)        echo ".${platform}/skills/${skill_name}/SKILL.md" ;;
  esac
}

# ─── Collect everything to delete ───────────────────────────
main() {
  printf "\n${BOLD}  doctor uninstall${RESET}\n\n"

  if [ ! -d ".doctor" ]; then
    err "Doctor is not installed in this project."
    exit 1
  fi

  local dirs_to_delete=()
  local files_to_delete=()
  local lines_to_remove=()

  # 1. .doctor/ directory
  dirs_to_delete+=(".doctor/")

  # 2. GitHub workflow
  local workflows_enabled
  workflows_enabled=$(read_rc "WORKFLOWS_ENABLED" "false")
  if [ "$workflows_enabled" = "true" ] && [ -f ".github/workflows/doctor.yml" ]; then
    files_to_delete+=(".github/workflows/doctor.yml")
  fi

  # 3. Git hooks (partial file edit, not full delete)
  for hook_file in ".husky/pre-commit" ".git/hooks/pre-commit"; do
    if [ -f "$hook_file" ] && grep -qF "$DOCTOR_HOOK_MARKER" "$hook_file" 2>/dev/null; then
      local line_num
      line_num=$(grep -nF "$DOCTOR_HOOK_MARKER" "$hook_file" | head -1 | cut -d: -f1)
      lines_to_remove+=("${hook_file}:${line_num}")
    fi
  done

  # 4. Skills per platform
  local platforms
  platforms=$(read_rc "SKILLS_PLATFORMS" "")

  if [ -n "$platforms" ]; then
    IFS=',' read -ra plat_arr <<< "$platforms"
    for platform in "${plat_arr[@]}"; do
      platform=$(echo "$platform" | tr -d ' ')

      # Find all skill directories/files for this platform
      case "$platform" in
        windsurf)
          for f in .windsurf/rules/*.md; do
            [ -f "$f" ] && files_to_delete+=("$f")
          done
          ;;
        *)
          local skills_dir=".${platform}/skills"
          if [ -d "$skills_dir" ]; then
            for skill_dir in "$skills_dir"/*/; do
              [ -d "$skill_dir" ] && [ -f "${skill_dir}SKILL.md" ] && dirs_to_delete+=("$skill_dir")
            done
          fi
          ;;
      esac
    done
  fi

  # ─── Show summary ──────────────────────────────────────────
  info "The following will be removed:"
  echo ""

  if [ "${#dirs_to_delete[@]}" -gt 0 ]; then
    for d in "${dirs_to_delete[@]}"; do
      printf "  ${RED}rm -rf${RESET}  %s\n" "$d"
    done
  fi

  if [ "${#files_to_delete[@]}" -gt 0 ]; then
    for f in "${files_to_delete[@]}"; do
      printf "  ${RED}rm${RESET}      %s\n" "$f"
    done
  fi

  if [ "${#lines_to_remove[@]}" -gt 0 ]; then
    for entry in "${lines_to_remove[@]}"; do
      local file="${entry%%:*}"
      local line="${entry##*:}"
      printf "  ${YELLOW}edit${RESET}    %s ${DIM}(line %s)${RESET}\n" "$file" "$line"
    done
  fi

  echo ""

  # ─── Ask confirmation ──────────────────────────────────────
  if [ ! -e /dev/tty ]; then
    err "Non-interactive mode. Aborting."
    exit 1
  fi

  printf "${BOLD}[doctor]${RESET} Confirm uninstall? [y/N] "
  local answer
  read -r answer </dev/tty
  case "$answer" in
    [Yy]*) ;;
    *) info "Cancelled."; exit 0 ;;
  esac

  echo ""

  # ─── Delete ────────────────────────────────────────────────

  # Remove lines from hook files first (before deleting dirs)
  for entry in "${lines_to_remove[@]}"; do
    local file="${entry%%:*}"
    local tmp="${file}.tmp"
    grep -vF "$DOCTOR_HOOK_MARKER" "$file" > "$tmp"
    mv "$tmp" "$file"
    chmod +x "$file"
    ok "Removed doctor hook from $file"
  done

  # Delete files
  for f in "${files_to_delete[@]}"; do
    rm -f "$f"
    ok "Deleted $f"
  done

  # Delete directories
  for d in "${dirs_to_delete[@]}"; do
    rm -rf "$d"
    ok "Deleted $d"
  done

  # Clean up empty parent directories left behind
  for platform in "${plat_arr[@]+"${plat_arr[@]}"}"; do
    platform=$(echo "$platform" | tr -d ' ')
    case "$platform" in
      windsurf)
        rmdir ".windsurf/rules" 2>/dev/null || true
        rmdir ".windsurf" 2>/dev/null || true
        ;;
      *)
        rmdir ".${platform}/skills" 2>/dev/null || true
        rmdir ".${platform}" 2>/dev/null || true
        ;;
    esac
  done

  # Clean up empty .github/workflows if we deleted the only file
  if [ -d ".github/workflows" ]; then
    rmdir ".github/workflows" 2>/dev/null || true
    rmdir ".github" 2>/dev/null || true
  fi

  echo ""
  ok "Doctor has been uninstalled."
}

main "$@"
