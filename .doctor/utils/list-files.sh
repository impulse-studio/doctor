#!/usr/bin/env bash
# .doctor/utils/list-files.sh — Shared file discovery respecting .gitignore
# Source this file from check scripts to use doctor_list_files / doctor_list_dirs.
#
# Usage:
#   source "path/to/.doctor/utils/list-files.sh"
#   doctor_list_files "src" ts tsx        # list .ts and .tsx files under src/
#   doctor_list_dirs "src"                # list directories containing tracked files

_DOCTOR_IN_GIT=""

_doctor_check_git() {
  if [ -z "$_DOCTOR_IN_GIT" ]; then
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      _DOCTOR_IN_GIT="yes"
    else
      _DOCTOR_IN_GIT="no"
    fi
  fi
}

# doctor_list_files <dir> <ext1> [ext2] ...
# Returns sorted list of files matching given extensions, respecting .gitignore.
doctor_list_files() {
  local dir="${1:-.}"
  shift
  local exts=("$@")

  _doctor_check_git

  if [ "$_DOCTOR_IN_GIT" = "yes" ]; then
    # Build grep pattern from extensions: \.(ts|tsx|css)$
    local pattern="\\.\($(IFS='|'; echo "${exts[*]}")\)$"
    git ls-files --cached --others --exclude-standard -- "$dir" \
      | grep -E "\.($(IFS='|'; echo "${exts[*]}"))$" \
      | sort
  else
    # Fallback: find with hardcoded exclusions
    local find_args=()
    for i in "${!exts[@]}"; do
      [ "$i" -gt 0 ] && find_args+=("-o")
      find_args+=(-name "*.${exts[$i]}")
    done
    find "$dir" -type f \( "${find_args[@]}" \) \
      -not -path "*/node_modules/*" \
      -not -path "*/.git/*" \
      -not -path "*/dist/*" \
      -not -path "*/.cache/*" \
      -not -path "*/target/*" \
      | sort
  fi
}

# doctor_list_dirs <dir>
# Returns sorted list of unique directories containing tracked files.
doctor_list_dirs() {
  local dir="${1:-.}"

  _doctor_check_git

  if [ "$_DOCTOR_IN_GIT" = "yes" ]; then
    # Get all directories that contain tracked/untracked-not-ignored files
    {
      git ls-files --cached --others --exclude-standard -- "$dir" \
        | while IFS= read -r f; do dirname "$f"; done
      # Also include the dir itself if it has files
      echo "$dir"
    } | sort -u
  else
    find "$dir" -type d \
      -not -path "*/node_modules/*" \
      -not -path "*/.git/*" \
      -not -path "*/dist/*" \
      -not -path "*/.cache/*" \
      -not -path "*/target/*" \
      | sort
  fi
}
