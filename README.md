# CachyOS Update Script

Safe, simple updater for CachyOS (Arch-based). This script detects and
uses one primary Arch-style package tool (`pamac`, `paru`, `yay`, or
`pacman`) to avoid duplicate work, with optional updates for `flatpak`
and `snap`. It provides interactive prompts, a non-interactive mode,
dry-run support, logging, sudo keepalive, better reboot detection, and
live terminal progress passthrough for long-running downloads.

---

## Table of Contents
- [Status](#status)
- [Features](#features)
- [Requirements](#requirements)
- [Usage](#usage)
- [Examples](#examples)
- [Design Notes](#design-notes)
- [Limitations & Next Steps](#limitations--next-steps)
- [Contributing](#contributing)
- [License](#license)

## Status
- Basic, stable script for local interactive and automated updates on
  CachyOS and other Arch-based systems. Verified locally.

## Features
- Detects Arch-style package tools and selects one primary updater: `pamac`, `paru`, `yay`, or `pacman`.
- Runs AUR helpers as the original non-root user when invoked through `sudo`, and skips unsafe root-only AUR runs.
- Updates `flatpak` system installs and user installs separately when possible.
- Updates `snap` if present.
- Interactive prompt with `--auto` for non-interactive runs.
- `--dry-run` mode to show commands without executing them.
- Keeps the sudo ticket warm for the full update so long updates do not ask for the password again.
- Preserves package-manager progress output by running updates through a PTY when available.
- Logs output to volatile storage by default, or to `/var/log/cachyos-update.log` / `$HOME/.cache/cachyos-update.log` when `--no-volatile-log` is used.
- Detects reboot requirements from update output, reboot marker files, and kernel mismatches.

## Requirements
- CachyOS or another Arch-based distro (recommended).
- One or more of: `pacman`, `pamac`, `yay`, `paru` (optional), `flatpak` (optional), `snap` (optional).
- `sudo` when running as non-root for system-level updates.

## Usage
1. Make executable (run from the `Update CachyOS` directory):

```bash
chmod +x update_all.sh
```

2. Run interactively (recommended, from the same directory):

```bash
./update_all.sh
```

3. Non-interactive automatic update (assumes yes):

```bash
./update_all.sh --auto
```

4. Dry-run (no changes, useful for checking what will run):

```bash
./update_all.sh --dry-run
```

Options:
- `--auto` — assume yes to prompts and reboot automatically if required.
- `--dry-run` — show the commands that would be executed (no root required).
- `--no-reboot` — never reboot even if updates require it.
- `--no-volatile-log` — force persistent logging to `/var/log` (when root) or `$HOME/.cache`.

Notes:
- By default the updater writes logs to volatile storage (prefers `/dev/shm`, then `/tmp`) so logs are automatically cleared on reboot. Use `--no-volatile-log` to keep logs persistent.
- The script asks for sudo only when a system-level update step is about to run, then keeps that ticket alive until the script exits.

## Examples
- Interactive update (will prompt before running and request sudo only when needed):

```bash
./update_all.sh
```

- Automatic update (no prompts, will reboot if necessary):

```bash
./update_all.sh --auto
```

- Dry-run to verify commands:

```bash
./update_all.sh --dry-run
```

## Design Notes
- The script prefers `pamac` when available. If it is absent, it falls back to `paru`, then `yay`, then `pacman`.
- Only one primary Arch updater runs per execution, which avoids redundant syncs and conflicting update passes.
- AUR helpers are executed as the invoking non-root user when the script is run under `sudo` to avoid running AUR builds as root.
- Package-manager commands are run inside a PTY when `script(1)` is available so progress bars remain visible during large downloads.
- Logging is volatile by default; use `--no-volatile-log` to keep logs after reboot.
- The script continues executing remaining update commands even if one
  command fails, but it exits non-zero afterward so automation can detect partial failures.

## Limitations & Next Steps
- This script does not create a systemd timer or service to run
  automatically on a schedule — that can be added if desired.
- Use caution with `--auto` on systems with manual package pinning or
  partial upgrades; review output when in doubt.
- Kernel and lower-level updates may still need human judgment; the script improves reboot detection, but package-specific instructions should still be respected.

## Contributing
- Suggest improvements or open a PR. When adding features, prefer
  conservative defaults and keep AUR operations executed as the
  non-root user by default.

## License
- MIT
