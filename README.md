# Kampisellis NixOS Configuration

Modular, flake-based NixOS configuration managing:

- **`homelab`** — Headless self-hosted server (Intel Core i3-12100, ZFS `tank` + `backup`, Caddy + Cloudflare DNS-01, NetBird, Technitium DNS, UPS/NUT, Sanoid/Syncoid).
- **`laptop`** — ASUS TUF FX505DY (AMD Ryzen 5 3550H + RX 560X, KDE Plasma 6 Wayland, GRUB EFI on `/efi`, preserves existing `/home`).

## Repository Layout

```text
.
├── flake.nix                  # Inputs (nixpkgs, nixpkgs-unstable), hosts, checks, devShell
├── justfile                   # Safe validation, diff, test, and switch recipes
├── statix.toml                # Linter rules
├── bin/
│   └── generate-services-table.nix
├── docs/
│   └── RUNBOOK.md             # Operations, rollback, upgrade, and install procedures
├── hosts/
│   ├── homelab/               # Server host entry + hardware-configuration.nix
│   └── laptop/                # Laptop host entry + hardware-configuration.nix
└── modules/
    ├── common.nix             # Shared Nix/Lix settings, locale, CLI tools
    ├── devshell.nix           # Dev shell with nixfmt, statix, deadnix, nvd, just
    └── homelab/               # Single-source-of-truth homelab options, infra & services
```

## Service Registry

All subdomains, Caddy reverse proxies, and Homepage dashboard entries are generated from `homelab.services` (`modules/homelab/options.nix`).

To print the live Markdown table at any time:

```bash
cat "$(nix build .#services-table --no-link --print-out-paths)"
```

## Common Workflows

```bash
# Enter dev shell (nixfmt, statix, deadnix, nvd, just)
nix develop

# Format, lint, and evaluate all hosts
just check

# Build homelab and preview package changes without activating
just diff homelab

# Activate temporarily (reverts on reboot)
just test homelab

# Activate permanently and write bootloader entry
just switch homelab
```

## Secrets

Secrets are stored out-of-repo in `/var/lib/secrets` (`0700 root:root`):

- `caddy.env` — `CLOUDFLARE_API_TOKEN` for wildcard ACME DNS-01
- `searx.env` — `SEARX_SECRET_KEY`
- `upsmon.pass` — NUT primary monitor password
- `rclone.conf` — Encrypted Google Drive ROMs remote (optional; service skips cleanly if empty)

See `docs/RUNBOOK.md` for backup/restore, upgrade procedures, and troubleshooting.
