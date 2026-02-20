#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# CachyOS updater: safe, automated updates tuned for CachyOS
# Author: github.com/galpt

PROG_NAME=$(basename "$0")

_green() { printf "\033[1;32m%s\033[0m\n" "$*"; }
_yellow() { printf "\033[1;33m%s\033[0m\n" "$*"; }
_red() { printf "\033[1;31m%s\033[0m\n" "$*"; }

print_header() {
  cat <<'HEADER'

┌────────────────────────────────────────────────────────┐
│                CachyOS System Updater                  │
│                 Safe updater for CachyOS               │
└────────────────────────────────────────────────────────┘

This script is tailored for CachyOS (Arch-based). It prefers
`pacman` and `pamac` for package updates and detects common
AUR helpers (`yay`, `paru`). It will also update `flatpak`
and `snap` if present.

HEADER
}

usage() {
  cat <<USAGE
Usage: $PROG_NAME [options]

Options:
  --auto        Run non-interactively (assume yes)
  --dry-run     Show what would be executed (no changes)
  --no-reboot   Never reboot even if required
  --help        Show this help

Examples:
  sudo $PROG_NAME            # interactive
  sudo $PROG_NAME --auto     # automatic, non-interactive
  $PROG_NAME --dry-run       # show commands only (no root required)

USAGE
  exit 0
}

check_root_or_sudo() {
  if [ "$EUID" -ne 0 ]; then
    echo
    echo "This script needs root — trying to re-run with sudo..."
    exec sudo bash "$0" "$@"
  fi
}

# Parse flags
AUTO=0
DRY_RUN=0
NO_REBOOT=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --auto) AUTO=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-reboot) NO_REBOOT=1; shift ;;
    --help|-h) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

main() {
  check_root_or_sudo
  print_header

  # Logging
  if [ "$EUID" -eq 0 ]; then
    LOGDIR=/var/log
  else
    LOGDIR="$HOME/.cache"
  fi
  mkdir -p "$LOGDIR"
  LOGFILE="$LOGDIR/cachyos-update.log"
  _yellow "Log: $LOGFILE"

  # Detect CachyOS and available tools
  CACHY=0
  if [ -f /etc/os-release ]; then
    if grep -qi 'cachyos' /etc/os-release; then
      CACHY=1
    fi
  fi

  DETECTED=()
  PKG_PACMAN=0; PKG_PAMAC=0; PKG_YAY=0; PKG_PARU=0; PKG_FLATPAK=0; PKG_SNAP=0

  if command -v pacman >/dev/null 2>&1; then PKG_PACMAN=1; DETECTED+=(pacman); fi
  if command -v pamac >/dev/null 2>&1; then PKG_PAMAC=1; DETECTED+=(pamac); fi
  if command -v yay >/dev/null 2>&1; then PKG_YAY=1; DETECTED+=(yay); fi
  if command -v paru >/dev/null 2>&1; then PKG_PARU=1; DETECTED+=(paru); fi
  if command -v flatpak >/dev/null 2>&1; then PKG_FLATPAK=1; DETECTED+=(flatpak); fi
  if command -v snap >/dev/null 2>&1; then PKG_SNAP=1; DETECTED+=(snap); fi

  if [ ${#DETECTED[@]} -eq 0 ]; then
    _red "No supported Arch-based package manager detected. Exiting."; exit 1
  fi

  echo
  if [ $CACHY -eq 1 ]; then
    _green "CachyOS detected. Proceeding with Arch-style updates."
  else
    _yellow "Warning: CachyOS not detected; continuing with Arch-style update commands." 
  fi
  _green "Detected tools: ${DETECTED[*]}"
  echo

  if [ "$DRY_RUN" -eq 1 ]; then
    _yellow "Running in dry-run mode — no changes will be made."
  fi

  if [ "$AUTO" -eq 0 ]; then
    read -rp "Proceed to update the above tools? [Y/n]: " resp
    resp=${resp:-Y}
    if ! [[ "$resp" =~ ^([yY][eE][sS]|[yY])$ ]]; then
      echo "Aborted."; exit 0
    fi
  fi

  # Build list of commands tuned for CachyOS (Arch-like)
  CMDS=()
  if [ "$PKG_PAMAC" -eq 1 ]; then
    CMDS+=("pamac upgrade -a --no-confirm")
  fi
  if [ "$PKG_PACMAN" -eq 1 ]; then
    CMDS+=("pacman -Syu --noconfirm")
  fi

  # AUR helpers (run as original user when invoked with sudo)
  if [ "$PKG_YAY" -eq 1 ]; then
    if [ -n "${SUDO_USER-}" ]; then
      CMDS+=("sudo -u $SUDO_USER yay -Syu --noconfirm")
    else
      CMDS+=("yay -Syu --noconfirm")
    fi
  fi
  if [ "$PKG_PARU" -eq 1 ]; then
    if [ -n "${SUDO_USER-}" ]; then
      CMDS+=("sudo -u $SUDO_USER paru -Syu --noconfirm")
    else
      CMDS+=("paru -Syu --noconfirm")
    fi
  fi

  if [ "$PKG_FLATPAK" -eq 1 ]; then
    CMDS+=("flatpak update -y")
  fi
  if [ "$PKG_SNAP" -eq 1 ]; then
    CMDS+=("snap refresh")
  fi

  # Execute commands
  for cmd in "${CMDS[@]}"; do
    _yellow "> $cmd"
    echo "---- $cmd ----" >> "$LOGFILE"
    echo "$(date --iso-8601=seconds) CMD: $cmd" >> "$LOGFILE"
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "(dry-run) $cmd"
      continue
    fi
    # Run the command and tee output to log
    if ! bash -c "$cmd" 2>&1 | tee -a "$LOGFILE"; then
      _red "Command failed: $cmd"
      _red "See $LOGFILE for details."
      # continue to next command rather than exiting, to attempt remaining updates
    fi
  done

  _green "Updates complete. Logs appended to: $LOGFILE"

  # Check for reboot requirement
  NEED_REBOOT=0
  if [ -f /var/run/reboot-required ]; then
    NEED_REBOOT=1
  elif command -v needs-restarting >/dev/null 2>&1; then
    if needs-restarting -r >/dev/null 2>&1; then
      NEED_REBOOT=1
    fi
  fi

  if [ "$NEED_REBOOT" -eq 1 ] && [ "$NO_REBOOT" -eq 0 ]; then
    if [ "$AUTO" -eq 1 ]; then
      _yellow "Reboot required — rebooting now (auto-mode)."
      shutdown -r now
    else
      read -rp "A reboot appears required. Reboot now? [y/N]: " rresp
      if [[ "$rresp" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        _yellow "Rebooting..."
        shutdown -r now
      else
        _yellow "Reboot skipped. You should reboot later to apply updates."
      fi
    fi
  elif [ "$NEED_REBOOT" -eq 1 ]; then
    _yellow "Reboot required but --no-reboot specified; please reboot manually later."
  else
    _green "No reboot required."
  fi

  _green "Done."
}

main "$@"
