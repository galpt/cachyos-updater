# CachyOS Update Script

Safe, simple updater for CachyOS (Arch-based). This script detects and
uses Arch-style package tools (pacman/pamac) and common AUR helpers
(`yay`, `paru`) to perform system updates, with optional updates for
`flatpak` and `snap`. It provides interactive prompts, a non-interactive
mode, dry-run support, logging, and an optional reboot prompt.

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
- Detects Arch-style package tools: `pacman` and `pamac`.
- Detects and runs AUR helpers: `yay`, `paru` (runs them as the original user when invoked with `sudo`).
- Updates `flatpak` and `snap` if present.
- Interactive prompt with `--auto` for non-interactive runs.
- `--dry-run` mode to show commands without executing them.
- Logs output to `/var/log/cachyos-update.log` when run as root,
  or `$HOME/.cache/cachyos-update.log` for non-root dry-runs.
- Detects whether a reboot is likely required and prompts to reboot.

## Requirements
- CachyOS or another Arch-based distro (recommended).
- One or more of: `pacman`, `pamac`, `yay`, `paru` (optional), `flatpak` (optional), `snap` (optional).
- `sudo` when running as non-root.

## Usage
1. Make executable (run from the `Update CachyOS` directory):

```bash
chmod +x update_all.sh
```

2. Run interactively (recommended, from the same directory):

```bash
sudo ./update_all.sh
```

3. Non-interactive automatic update (assumes yes):

```bash
sudo ./update_all.sh --auto
```

4. Dry-run (no changes, useful for checking what will run):

```bash
./update_all.sh --dry-run
```

Options:
- `--auto` — assume yes to prompts and reboot automatically if required.
- `--dry-run` — show the commands that would be executed (no root required).
- `--no-reboot` — never reboot even if updates require it.

## Examples
- Interactive update (will prompt before running):

```bash
sudo ./update_all.sh
```

- Automatic update (no prompts, will reboot if necessary):

```bash
sudo ./update_all.sh --auto
```

- Dry-run to verify commands:

```bash
./update_all.sh --dry-run
```

## Design Notes
- The script prefers `pamac` when available because it can handle both
  official packages and AUR packages (when configured). If `pamac` is
  absent it falls back to `pacman` + detected AUR helper.
- AUR helpers detected (`yay`, `paru`) are executed as the invoking
  non-root user when the script is run under `sudo` to avoid running
  AUR builds as root.
- Logging: when run as root logs are appended to `/var/log/cachyos-update.log`.
- The script continues executing remaining update commands even if one
  command fails — this favors completing as many updates as possible.

## Limitations & Next Steps
- This script does not create a systemd timer or service to run
  automatically on a schedule — that can be added if desired.
- Use caution with `--auto` on systems with manual package pinning or
  partial upgrades; review output when in doubt.
- Kernel and lower-level updates may require a reboot — the script
  prompts for this and can reboot automatically in `--auto` mode.

## Contributing
- Suggest improvements or open a PR. When adding features, prefer
  conservative defaults and keep AUR operations executed as the
  non-root user by default.

## License
- MIT
