#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

PROG_NAME=$(basename "$0")

AUTO=0
DRY_RUN=0
NO_REBOOT=0
VOLATILE_LOG=${VOLATILE_LOG:-1}

LOGDIR=""
LOGFILE=""
USE_PTY=0
ROOT_REQUIRED=0
NEED_REBOOT=0
REBOOT_REASON=""
SUDO_KEEPALIVE_PID=""
FAILED_CMDS=()
DETECTED=()

PKG_PACMAN=0
PKG_PAMAC=0
PKG_YAY=0
PKG_PARU=0
PKG_FLATPAK=0
PKG_SNAP=0
PRIMARY_MANAGER=""
AUR_SKIPPED_REASON=""

_green() { printf "\033[1;32m%s\033[0m\n" "$*"; }
_yellow() { printf "\033[1;33m%s\033[0m\n" "$*"; }
_red() { printf "\033[1;31m%s\033[0m\n" "$*"; }

print_header() {
  cat <<'HEADER'

┌────────────────────────────────────────────────────────┐
│                CachyOS System Updater                  │
│                 Safe updater for CachyOS               │
└────────────────────────────────────────────────────────┘

This script is tailored for CachyOS (Arch-based). It picks one
primary package tool to avoid duplicate work, can refresh your
sudo ticket until updates finish, and also updates `flatpak`
and `snap` when present.

HEADER
}

usage() {
  cat <<USAGE
Usage: $PROG_NAME [options]

Options:
  --auto             Run non-interactively (assume yes)
  --dry-run          Show planned commands without executing them
  --no-reboot        Never reboot even if required
  --no-volatile-log  Force persistent logs (write to /var/log or \$HOME/.cache)
  --help             Show this help

Examples:
  ./$PROG_NAME
  ./$PROG_NAME --auto
  ./$PROG_NAME --dry-run

By default this script writes logs to volatile storage (prefer `/dev/shm`, then `/tmp`) so
logs are cleared on reboot. To force persistent logging set `--no-volatile-log` or
`VOLATILE_LOG=0` in the environment.
USAGE
}

cleanup() {
  if [ -n "$SUDO_KEEPALIVE_PID" ]; then
    kill "$SUDO_KEEPALIVE_PID" >/dev/null 2>&1 || true
    wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  fi
}

trap cleanup EXIT

parse_flags() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --auto) AUTO=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --no-reboot) NO_REBOOT=1 ;;
      --no-volatile-log) VOLATILE_LOG=0 ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        _red "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
    shift
  done
}

normalize_settings() {
  case "$VOLATILE_LOG" in
    0|1) ;;
    *)
      _yellow "Invalid VOLATILE_LOG value '$VOLATILE_LOG'; defaulting to 1."
      VOLATILE_LOG=1
      ;;
  esac
}

setup_logging() {
  local volatile_log_name="cachyos-update-${EUID}.log"

  if [ "$VOLATILE_LOG" -eq 1 ]; then
    if [ -d /dev/shm ] && [ -w /dev/shm ]; then
      LOGDIR=/dev/shm
    else
      LOGDIR=/tmp
    fi
    mkdir -p "$LOGDIR"
    LOGFILE="$LOGDIR/$volatile_log_name"
    _yellow "Using volatile log location: $LOGFILE"
    return
  fi

  local varlog_tmpfs=0
  if grep -q 'tmpfs /var/log ' /proc/mounts 2>/dev/null; then
    varlog_tmpfs=1
  fi

  if [ "$EUID" -eq 0 ]; then
    LOGDIR=/var/log
  else
    LOGDIR="$HOME/.cache"
  fi

  mkdir -p "$LOGDIR"
  LOGFILE="$LOGDIR/cachyos-update.log"

  if [ "$LOGDIR" = "/var/log" ] && [ "$varlog_tmpfs" -eq 1 ]; then
    _yellow "/var/log is mounted as tmpfs; logs there will still be cleared on reboot"
  fi
  _yellow "Log: $LOGFILE"
}

detect_environment() {
  if command -v script >/dev/null 2>&1; then
    USE_PTY=1
  fi

  if command -v pacman >/dev/null 2>&1; then
    PKG_PACMAN=1
    DETECTED+=(pacman)
  fi
  if command -v pamac >/dev/null 2>&1; then
    PKG_PAMAC=1
    DETECTED+=(pamac)
  fi
  if command -v yay >/dev/null 2>&1; then
    PKG_YAY=1
    DETECTED+=(yay)
  fi
  if command -v paru >/dev/null 2>&1; then
    PKG_PARU=1
    DETECTED+=(paru)
  fi
  if command -v flatpak >/dev/null 2>&1; then
    PKG_FLATPAK=1
    ROOT_REQUIRED=1
    DETECTED+=(flatpak)
  fi
  if command -v snap >/dev/null 2>&1; then
    PKG_SNAP=1
    ROOT_REQUIRED=1
    DETECTED+=(snap)
  fi

  if [ ${#DETECTED[@]} -eq 0 ]; then
    _red "No supported package manager detected. Exiting."
    exit 1
  fi
}

select_primary_manager() {
  if [ "$PKG_PAMAC" -eq 1 ]; then
    PRIMARY_MANAGER="pamac"
    ROOT_REQUIRED=1
    return
  fi

  if [ "$PKG_PARU" -eq 1 ]; then
    if [ "$EUID" -eq 0 ] && [ -z "${SUDO_USER:-}" ]; then
      if [ -z "$AUR_SKIPPED_REASON" ]; then
        AUR_SKIPPED_REASON="Detected paru, but the script was started as root directly so AUR updates were skipped."
      fi
    else
      PRIMARY_MANAGER="paru"
      return
    fi
  fi

  if [ "$PKG_YAY" -eq 1 ] && [ -z "$PRIMARY_MANAGER" ]; then
    if [ "$EUID" -eq 0 ] && [ -z "${SUDO_USER:-}" ]; then
      if [ -z "$AUR_SKIPPED_REASON" ]; then
        AUR_SKIPPED_REASON="Detected yay, but the script was started as root directly so AUR updates were skipped."
      fi
    else
      PRIMARY_MANAGER="yay"
      return
    fi
  fi

  if [ "$PKG_PACMAN" -eq 1 ]; then
    PRIMARY_MANAGER="pacman"
    ROOT_REQUIRED=1
  fi
}

show_environment_summary() {
  local cachy=0
  local detected_list=""

  if [ -f /etc/os-release ] && grep -qi 'cachyos' /etc/os-release; then
    cachy=1
  fi

  echo
  if [ "$cachy" -eq 1 ]; then
    _green "CachyOS detected. Proceeding with Arch-style updates."
  else
    _yellow "Warning: CachyOS not detected; continuing with Arch-style update commands."
  fi
  printf -v detected_list '%s ' "${DETECTED[@]}"
  detected_list=${detected_list% }
  _green "Detected tools: $detected_list"

  if [ -n "$PRIMARY_MANAGER" ]; then
    _green "Primary updater: $PRIMARY_MANAGER"
  fi
  if [ -n "$AUR_SKIPPED_REASON" ]; then
    _yellow "$AUR_SKIPPED_REASON"
  fi
  if [ "$PKG_FLATPAK" -eq 1 ]; then
    _green "Flatpak updates enabled."
  fi
  if [ "$PKG_SNAP" -eq 1 ]; then
    _green "Snap updates enabled."
  fi
  if [ "$USE_PTY" -eq 1 ]; then
    _green "Interactive progress passthrough enabled."
  else
    _yellow "PTY helper not found; some package managers may show less detailed progress."
  fi
  echo
}

ensure_primary_manager() {
  if [ -n "$PRIMARY_MANAGER" ]; then
    return
  fi

  if [ "$PKG_FLATPAK" -eq 1 ] || [ "$PKG_SNAP" -eq 1 ]; then
    _yellow "No primary Arch package updater selected; continuing with Flatpak/Snap updates only."
    return
  fi

  _red "No safe update path was found for this system."
  exit 1
}

confirm_run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    _yellow "Running in dry-run mode; no changes will be made."
    return
  fi

  if [ "$AUTO" -eq 0 ]; then
    read -rp "Proceed with the planned updates? [Y/n]: " resp
    resp=${resp:-Y}
    if ! [[ "$resp" =~ ^([yY][eE][sS]|[yY])$ ]]; then
      echo "Aborted."
      exit 0
    fi
  fi
}

start_sudo_keepalive() {
  if [ "$EUID" -eq 0 ] || [ -n "$SUDO_KEEPALIVE_PID" ]; then
    return
  fi

  local parent_pid=$$
  (
    while true; do
      sudo -n true >/dev/null 2>&1 || exit 0
      sleep 50
      kill -0 "$parent_pid" >/dev/null 2>&1 || exit 0
    done
  ) &
  SUDO_KEEPALIVE_PID=$!
}

require_sudo_ticket() {
  if [ "$DRY_RUN" -eq 1 ] || [ "$ROOT_REQUIRED" -eq 0 ] || [ "$EUID" -eq 0 ]; then
    return
  fi

  _yellow "Requesting sudo access for system updates..."
  sudo -v
  start_sudo_keepalive
}

mark_reboot_required() {
  local reason=$1

  NEED_REBOOT=1
  if [ -z "$REBOOT_REASON" ]; then
    REBOOT_REASON=$reason
  fi
}

scan_reboot_hints() {
  local cmd_log=$1
  local label=$2
  local reboot_regex='(reboot|restart).*(required|recommended|needed|suggested)|((required|recommended|needed|suggested).*(reboot|restart))|please reboot|system restart'

  if tr '\r' '\n' < "$cmd_log" | grep -Eiq "$reboot_regex"; then
    mark_reboot_required "Update output from '$label' requested a reboot."
  fi
}

run_command_with_logging() {
  local cmd_log=$1
  local cmd_string=$2

  if [ "$USE_PTY" -eq 1 ]; then
    script -qefc "$cmd_string" /dev/null | tee -a "$LOGFILE" "$cmd_log"
  else
    bash -lc "$cmd_string" 2>&1 | tee -a "$LOGFILE" "$cmd_log"
  fi
}

run_logged_cmd() {
  local mode=$1
  local display=$2
  shift 2

  local -a cmd=("$@")
  local -a exec_cmd=()
  local cmd_log
  local cmd_string

  case "$mode" in
    root)
      if [ "$EUID" -eq 0 ]; then
        exec_cmd=("${cmd[@]}")
      else
        exec_cmd=(sudo "${cmd[@]}")
      fi
      ;;
    user)
      if [ "$EUID" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
        exec_cmd=(sudo -H -u "$SUDO_USER" "${cmd[@]}")
      else
        exec_cmd=("${cmd[@]}")
      fi
      ;;
    current)
      exec_cmd=("${cmd[@]}")
      ;;
    *)
      _red "Unknown execution mode: $mode"
      exit 1
      ;;
  esac

  printf -v cmd_string '%q ' "${exec_cmd[@]}"
  cmd_string=${cmd_string% }

  _yellow "> $display"
  {
    printf -- '---- %s ----\n' "$display"
    printf '%s CMD: %s\n' "$(date --iso-8601=seconds)" "$cmd_string"
  } >> "$LOGFILE"

  if [ "$DRY_RUN" -eq 1 ]; then
    printf '(dry-run) %s\n' "$display"
    return 0
  fi

  cmd_log=$(mktemp "$LOGDIR/cachyos-update-step.XXXXXX")

  if ! run_command_with_logging "$cmd_log" "$cmd_string"; then
    FAILED_CMDS+=("$display")
    _red "Command failed: $display"
    _red "See $LOGFILE for details."
  fi

  scan_reboot_hints "$cmd_log" "$display"
  rm -f "$cmd_log"
}

run_primary_updates() {
  case "$PRIMARY_MANAGER" in
    pamac)
      run_logged_cmd root "pamac upgrade -a --no-confirm" pamac upgrade -a --no-confirm
      ;;
    paru)
      run_logged_cmd user "paru -Syu --noconfirm" paru -Syu --noconfirm
      ;;
    yay)
      run_logged_cmd user "yay -Syu --noconfirm" yay -Syu --noconfirm
      ;;
    pacman)
      run_logged_cmd root "pacman -Syu --noconfirm" pacman -Syu --noconfirm
      ;;
  esac
}

run_flatpak_updates() {
  if [ "$PKG_FLATPAK" -ne 1 ]; then
    return
  fi

  if [ "$EUID" -eq 0 ]; then
    run_logged_cmd current "flatpak update -y --system" flatpak update -y --system
    if [ -n "${SUDO_USER:-}" ]; then
      run_logged_cmd user "flatpak update -y --user" flatpak update -y --user
    else
      _yellow "Skipping user Flatpak updates because no invoking user was provided."
    fi
    return
  fi

  run_logged_cmd root "flatpak update -y --system" flatpak update -y --system
  run_logged_cmd current "flatpak update -y --user" flatpak update -y --user
}

run_snap_updates() {
  if [ "$PKG_SNAP" -eq 1 ]; then
    run_logged_cmd root "snap refresh" snap refresh
  fi
}

running_kernel_is_stale() {
  local running_kernel

  running_kernel=$(uname -r)

  if [ ! -d /usr/lib/modules ]; then
    return 1
  fi

  if [ -d "/usr/lib/modules/$running_kernel" ]; then
    return 1
  fi

  if find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d | grep -q .; then
    return 0
  fi

  return 1
}

detect_reboot_requirement() {
  if [ -f /run/reboot-required ] || [ -f /var/run/reboot-required ] || [ -f /run/reboot-required.pkgs ] || [ -f /var/run/reboot-required.pkgs ]; then
    mark_reboot_required "The system created a reboot-required marker."
  fi

  if running_kernel_is_stale; then
    mark_reboot_required "The running kernel no longer matches the installed kernel modules."
  fi
}

handle_reboot() {
  detect_reboot_requirement

  if [ ${#FAILED_CMDS[@]} -gt 0 ] && [ "$NEED_REBOOT" -eq 0 ]; then
    _yellow "Some update steps failed, so reboot detection may be incomplete."
  fi

  if [ "$NEED_REBOOT" -eq 1 ] && [ "$NO_REBOOT" -eq 0 ]; then
    _yellow "Reboot required. Reason: $REBOOT_REASON"
    if [ "$AUTO" -eq 1 ]; then
      _yellow "Rebooting now because --auto was used."
      shutdown -r now
    else
      read -rp "Reboot now? [y/N]: " reboot_reply
      if [[ "$reboot_reply" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        _yellow "Rebooting..."
        shutdown -r now
      else
        _yellow "Reboot skipped. Please reboot later."
      fi
    fi
  elif [ "$NEED_REBOOT" -eq 1 ]; then
    _yellow "Reboot required but --no-reboot was specified. Reason: $REBOOT_REASON"
  else
    _green "No reboot required."
  fi
}

print_result_summary() {
  if [ ${#FAILED_CMDS[@]} -eq 0 ]; then
    _green "Updates complete. Logs appended to: $LOGFILE"
    return
  fi

  _yellow "Updates finished with some failures. Logs appended to: $LOGFILE"
  for failed_cmd in "${FAILED_CMDS[@]}"; do
    _yellow "Failed step: $failed_cmd"
  done
}

main() {
  parse_flags "$@"
  normalize_settings
  print_header
  setup_logging
  detect_environment
  select_primary_manager
  ensure_primary_manager
  show_environment_summary
  confirm_run
  require_sudo_ticket
  run_primary_updates
  run_flatpak_updates
  run_snap_updates
  print_result_summary
  handle_reboot

  if [ ${#FAILED_CMDS[@]} -gt 0 ]; then
    exit 1
  fi

  _green "Done."
}

main "$@"
