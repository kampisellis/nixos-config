# NixOS Configuration

Flake-based NixOS configuration for my home server (`homelab`) and daily laptop (`laptop`).

## Hosts

| Host | Hardware | Role | Release / State |
| --- | --- | --- | --- |
| `homelab` | Intel Core i3-12100, 240GB SSD + ZFS (`tank`, `backup`), 2.5GbE, PowerWalker VFI 1000 UPS | Headless self-hosted server | NixOS 26.05 (`stateVersion = 25.11`) |
| `laptop` | ASUS TUF FX505DY (Ryzen 5 3550H + RX 560X) | Daily workstation (KDE Plasma 6 / Wayland) | NixOS 26.05 (`stateVersion = 26.05`) |

## Repository Structure

```text
.
├── flake.nix                  # Inputs (nixos-26.05, unstable), mkHost helper, formatter, checks
├── justfile                   # Local commands for validation, diff, test, and switch
├── statix.toml                # Linter configuration
├── bin/
│   └── generate-services-table.nix
├── docs/
│   └── RUNBOOK.md             # Recovery, ZFS, backup drills, and host migration procedures
├── hosts/
│   ├── homelab/               # Server entry point and hardware-configuration.nix
│   └── laptop/                # Laptop entry point and hardware-configuration.nix
└── modules/
    ├── common.nix             # Shared Nix/Lix settings, locale, timezone, base CLI tools
    ├── devshell.nix           # Dev shell (just, nvd, statix, deadnix, nixfmt)
    └── homelab/
        ├── options.nix        # Network constants and homelab.services registry
        ├── base.nix           # Boot, Intel GPU, SSH, Cockpit, zramSwap, ntfy failure alerts
        ├── networking.nix     # nic0 aliases, firewall, Technitium DNS, NetBird
        ├── storage.nix        # ZFS mounts, HDD spindown, rclone mount, ZED & smartd alerts
        ├── backup.nix         # Daily PostgreSQL dumps, Sanoid snapshots, Syncoid replication
        ├── samba.nix          # SMB3 shares restricted to LAN/VPN subnets
        ├── ups.nix            # NUT integration and udev rules
        ├── caddy.nix          # Cloudflare DNS-01 wildcard reverse proxy + static site
        ├── homepage.nix       # Dashboard generated from homelab.services
        ├── motd.nix           # Login summary (uptime, load, failed units, ZFS health)
        └── services/          # One self-contained module per service
```

## How the Server Is Built

### Single Service Registry

Every web service is declared once under `homelab.services` in `modules/homelab/options.nix`. From that attribute set, the configuration automatically generates:

- Caddy virtual hosts and reverse-proxy rules (`modules/homelab/caddy.nix`)
- Homepage dashboard categories and links (`modules/homelab/homepage.nix`)
- A Markdown overview table via `just services-table`

### Channel & Pinning Policy

Both hosts track `nixos-26.05` by default. `nixpkgs-unstable` is exposed via `pkgs-unstable` and used selectively only where a service requires a newer build (currently Immich for database compatibility and NetBird to stay in sync with peers). Weekly GitHub Actions PRs update only the stable `nixpkgs` input so database-backed services are never bumped unexpectedly.

### Networking

The server uses a single 2.5GbE interface (`nic0`) with dedicated LAN aliases on `10.10.10.0/24`:

| Address | Role |
| --- | --- |
| `10.10.10.5` | Host management and SSH |
| `10.10.10.101` | Technitium DNS (`:53`, `:5380`) |
| `10.10.10.105` | Caddy wildcard reverse proxy (`:80`, `:443`) |
| `10.10.10.109` | Internal static Hugo site (`:8085`), fronted by an external VPS over NetBird |

Internal admin tools such as Cockpit bind strictly to `127.0.0.1` and are exposed only through Caddy.

### Storage, Backups & Health

- **OS disk (`240GB SSD`):** `/boot` (`NIXBOOT`, FAT32) and `/` (`NIXROOT`, ext4).
- **Primary pool (`tank`):** `tank/var-lib` mounted on `/var/lib` (`neededForBoot`) for service state and databases; `tank/data` mounted on `/mnt/nas-data` for NAS files and Immich media.
- **Backup pool (`backup`):** 1TB SATA HDD that spins down after 15 minutes of inactivity. `sanoid` manages snapshots on `tank`, `syncoid` replicates `var-lib` and `data` to `backup`, and PostgreSQL dumps run daily at `02:15`.
- **Monitoring & UPS:** `smartd`, ZFS ZED, and systemd `OnFailure` hooks send alerts to local `ntfy`. NUT monitors the PowerWalker UPS and initiates a clean shutdown at 20% battery.

## Workflow

```bash
# Enter dev shell with linters and helper tools
nix develop

# Evaluate all hosts and run formatting/lint checks
just check
just lint

# Build and inspect package changes without activating
just diff homelab

# Test live (reverts automatically on reboot)
just test homelab

# Persist configuration to bootloader
just switch homelab

# Update stable nixpkgs only and review the diff
just update homelab

# Print the generated service registry table
just services-table
```

Disaster recovery, ZFS maintenance, backup restore drills, and laptop migration notes live in [docs/RUNBOOK.md](docs/RUNBOOK.md).
