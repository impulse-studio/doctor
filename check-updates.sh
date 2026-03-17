#!/usr/bin/env bash
set -euo pipefail

# ─── Constants ───────────────────────────────────────────────
REPO="impulse-studio/doctor"
REPO_URL="https://github.com/$REPO"
BRANCH="main"
DOCTORRC=".doctor/config/.doctorrc"

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

# ─── Portable hashing ───────────────────────────────────────
hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    err "No sha256sum or shasum found"; exit 2
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

# ─── Semver comparison ──────────────────────────────────────
version_gt() {
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
extract_content_after_frontmatter() {
  awk 'BEGIN{n=0} /^---$/{n++; if(n==2){found=1; next}} found{print}' "$1"
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

generate_skill_content() {
  local platform="$1" skill_name="$2" skill_file="$3"
  case "$platform" in
    windsurf) extract_content_after_frontmatter "$skill_file" ;;
    *)        cat "$skill_file" ;;
  esac
}

# ─── Download repo ──────────────────────────────────────────
DOWNLOAD_DIR=""
CLEANUP_DIR=""

cleanup() {
  [ -n "$CLEANUP_DIR" ] && rm -rf "$CLEANUP_DIR"
}

download_repo() {
  local tmp_dir
  tmp_dir=$(mktemp -d) || { err "Failed to create temp dir"; exit 2; }
  CLEANUP_DIR="$tmp_dir"
  trap cleanup EXIT

  info "Checking for updates..."

  if ! curl -fsSL "${REPO_URL}/archive/refs/heads/${BRANCH}.tar.gz" \
       -o "$tmp_dir/doctor.tar.gz" 2>/dev/null; then
    err "Failed to download. Check your internet connection."
    exit 2
  fi

  tar -xzf "$tmp_dir/doctor.tar.gz" -C "$tmp_dir" 2>/dev/null \
    || { err "Failed to extract archive"; exit 2; }

  DOWNLOAD_DIR="$tmp_dir/doctor-${BRANCH}"

  if [ ! -d "$DOWNLOAD_DIR" ]; then
    DOWNLOAD_DIR=$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d | head -1)
  fi

  if [ ! -d "$DOWNLOAD_DIR/.doctor" ]; then
    err "Downloaded archive does not contain .doctor/ directory"
    exit 2
  fi
}

# ─── Check logic ────────────────────────────────────────────
main() {
  # Doctor must be installed
  if [ ! -f "$DOCTORRC" ]; then
    warn "Doctor is not installed. Run install.sh first."
    exit 1
  fi

  download_repo

  local REMOTE_VERSION
  REMOTE_VERSION=$(cat "$DOWNLOAD_DIR/VERSION" 2>/dev/null | tr -d '[:space:]' || echo "0.0.0")
  local LOCAL_VERSION
  LOCAL_VERSION=$(read_rc "DOCTOR_VERSION" "0.0.0")

  local changes=0

  # ── Version check ──────────────────────────────────────────
  if [ "$LOCAL_VERSION" = "$REMOTE_VERSION" ]; then
    # Same version — still check individual file hashes
    :
  elif version_gt "$REMOTE_VERSION" "$LOCAL_VERSION"; then
    warn "New version available: v${LOCAL_VERSION} → v${REMOTE_VERSION}"
    changes=1
  fi

  # ── Scripts ────────────────────────────────────────────────
  if [ -f ".doctor/run.sh" ] && ! files_identical ".doctor/run.sh" "$DOWNLOAD_DIR/.doctor/run.sh"; then
    info "  Changed: .doctor/run.sh"
    changes=1
  fi

  while IFS= read -r remote_file; do
    local rel_path="${remote_file#$DOWNLOAD_DIR/}"
    local local_file="./$rel_path"

    if [ ! -f "$local_file" ]; then
      info "  New:     $rel_path"
      changes=1
    elif ! files_identical "$local_file" "$remote_file"; then
      info "  Changed: $rel_path"
      changes=1
    fi
  done < <(find "$DOWNLOAD_DIR/.doctor/scripts" "$DOWNLOAD_DIR/.doctor/utils" -type f 2>/dev/null)

  # ── Configs (only new files count) ─────────────────────────
  while IFS= read -r remote_file; do
    local basename
    basename=$(basename "$remote_file")
    [ "$basename" = ".doctorrc" ] && continue

    if [ ! -f ".doctor/config/$basename" ]; then
      info "  New config: $basename"
      changes=1
    fi
  done < <(find "$DOWNLOAD_DIR/.doctor/config" -type f 2>/dev/null)

  # ── Workflow ───────────────────────────────────────────────
  local workflows_enabled
  workflows_enabled=$(read_rc "WORKFLOWS_ENABLED" "false")

  if [ "$workflows_enabled" = "true" ] && [ -f ".github/workflows/doctor.yml" ]; then
    if ! files_identical ".github/workflows/doctor.yml" "$DOWNLOAD_DIR/.github/workflows/doctor.yml"; then
      info "  Changed: .github/workflows/doctor.yml"
      changes=1
    fi
  fi

  # ── Skills ─────────────────────────────────────────────────
  local platforms
  platforms=$(read_rc "SKILLS_PLATFORMS" "")

  if [ -n "$platforms" ]; then
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
          info "  New skill: ${skill_name} (${platform})"
          changes=1
        else
          local expected_hash current_hash
          expected_hash=$(generate_skill_content "$platform" "$skill_name" "$remote_skill" | hash_stdin)
          current_hash=$(hash_file "$local_skill")

          if [ "$current_hash" != "$expected_hash" ]; then
            info "  Changed: ${skill_name} (${platform})"
            changes=1
          fi
        fi
      done
    done
  fi

  # ── Result ─────────────────────────────────────────────────
  echo ""
  if [ "$changes" -eq 0 ]; then
    ok "Up to date (v${LOCAL_VERSION})"
    exit 0
  else
    warn "Updates available. Run install.sh to apply."
    exit 1
  fi
}

main "$@"
