#!/usr/bin/env bash
set -euo pipefail

# ─── Constants ───────────────────────────────────────────────
DOCTORRC=".doctor/config/.doctorrc"
CHECKS_CONFIG=".doctor/config/checks"
DOCTOR_HOOK_MARKER="# doctor:hook"

# ─── Colors ─────────────────────────────────────────────────
if [ -t 1 ] || [ -t 2 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
  BLUE='\033[0;34m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; DIM=''; RESET=''
fi

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

# ─── Main ────────────────────────────────────────────────────
main() {
  printf "\n${BOLD}  doctor status${RESET}\n\n"

  if [ ! -d ".doctor" ]; then
    printf "  ${RED}Not installed.${RESET} Run install.sh to set up Doctor.\n\n"
    exit 1
  fi

  # ── Version ──────────────────────────────────────────────
  local version commit
  version=$(read_rc "DOCTOR_VERSION" "unknown")
  commit=$(read_rc "DOCTOR_COMMIT" "unknown")
  local short_commit="${commit:0:7}"
  printf "  ${BOLD}Version:${RESET}   %s ${DIM}(%s)${RESET}\n\n" "$version" "$short_commit"

  # ── Parse ALL_CHECKS from run.sh ─────────────────────────
  local ALL_CHECKS=()
  if [ -f ".doctor/run.sh" ]; then
    while IFS= read -r check; do
      check=$(echo "$check" | tr -d ' "')
      [ -z "$check" ] && continue
      ALL_CHECKS+=("$check")
    done < <(grep '^ALL_CHECKS=' .doctor/run.sh \
      | sed 's/ALL_CHECKS=(//' | sed 's/)//' \
      | tr ' ' '\n' | sed 's/^"//' | sed 's/"$//')
  fi

  # ── Load disabled checks ─────────────────────────────────
  local DISABLED=()
  if [ -f "$CHECKS_CONFIG" ]; then
    while IFS= read -r line; do
      line="${line%%#*}"
      line="$(echo "$line" | tr -d '[:space:]')"
      [ -z "$line" ] && continue
      DISABLED+=("$line")
    done < "$CHECKS_CONFIG"
  fi

  is_disabled() {
    local check="$1"
    for d in "${DISABLED[@]+"${DISABLED[@]}"}"; do
      [ "$d" = "$check" ] && return 0
    done
    return 1
  }

  # ── Display checks ───────────────────────────────────────
  local active=0 disabled=0
  printf "  ${BOLD}Checks:${RESET}\n"

  for check in "${ALL_CHECKS[@]}"; do
    if is_disabled "$check"; then
      printf "    ${DIM}-${RESET} ${DIM}%s (disabled)${RESET}\n" "$check"
      disabled=$((disabled + 1))
    else
      printf "    ${GREEN}✓${RESET} %s\n" "$check"
      active=$((active + 1))
    fi
  done

  echo ""
  printf "  %d active, %d disabled\n\n" "$active" "$disabled"

  # ── Workflow ─────────────────────────────────────────────
  local wf_enabled
  wf_enabled=$(read_rc "WORKFLOWS_ENABLED" "false")
  if [ "$wf_enabled" = "true" ] && [ -f ".github/workflows/doctor.yml" ]; then
    printf "  ${BOLD}Workflow:${RESET}  ${GREEN}installed${RESET} ${DIM}(.github/workflows/doctor.yml)${RESET}\n"
  elif [ "$wf_enabled" = "true" ]; then
    printf "  ${BOLD}Workflow:${RESET}  ${YELLOW}missing${RESET} ${DIM}(enabled but file not found)${RESET}\n"
  else
    printf "  ${BOLD}Workflow:${RESET}  ${DIM}not installed${RESET}\n"
  fi

  # ── Git Hook ─────────────────────────────────────────────
  local hooks_enabled
  hooks_enabled=$(read_rc "HOOKS_ENABLED" "false")
  local hook_location=""
  for hook_file in ".husky/pre-commit" ".git/hooks/pre-commit"; do
    if [ -f "$hook_file" ] && grep -qF "$DOCTOR_HOOK_MARKER" "$hook_file" 2>/dev/null; then
      hook_location="$hook_file"
      break
    fi
  done

  if [ -n "$hook_location" ]; then
    printf "  ${BOLD}Git Hook:${RESET}  ${GREEN}installed${RESET} ${DIM}(%s)${RESET}\n" "$hook_location"
  elif [ "$hooks_enabled" = "true" ]; then
    printf "  ${BOLD}Git Hook:${RESET}  ${YELLOW}missing${RESET} ${DIM}(enabled but hook not found)${RESET}\n"
  else
    printf "  ${BOLD}Git Hook:${RESET}  ${DIM}not installed${RESET}\n"
  fi

  # ── Skills ───────────────────────────────────────────────
  local platforms
  platforms=$(read_rc "SKILLS_PLATFORMS" "")
  if [ -n "$platforms" ]; then
    printf "  ${BOLD}Skills:${RESET}    ${GREEN}%s${RESET}\n" "$platforms"
  else
    printf "  ${BOLD}Skills:${RESET}    ${DIM}not installed${RESET}\n"
  fi

  echo ""
}

main "$@"
