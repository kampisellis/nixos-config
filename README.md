# nixos-config

Declarative NixOS flake managing my home server (`homelab`) and daily workstation (`laptop`).

## Hosts

| Host | Hardware | Role | Release |
| --- | --- | --- | --- |
| `homelab` | Intel Core i3-12100, 240 GB boot SSD, ZFS mirror (`tank`) + backup HDD (`backup`), 2.5GbE, PowerWalker UPS | Headless self-hosted server & NAS | NixOS 26.05 (`stateVersion = 25.11`) |
| `laptop` | ASUS TUF FX505DY (Ryzen 5 3550H, RX 560X) | Daily workstation (KDE Plasma 6 / Wayland) | NixOS 26.05 (`stateVersion = 26.05`) |

## Layout

```text
.
├── flake.nix                    # Inputs (nixos-26.05, nixpkgs-unstable), host builder, formatter, checks
├── justfile                     # Validation, diff, test, switch, and update recipes
├── statix.toml                  # Nix linter rules
├── bin/
│   └── generate-services-table.nix
├── docs/
│   └── RUNBOOK.md               # Quick-reference recovery, ZFS maintenance, and restore procedures
├── hosts/
│   ├── homelab/                 # Server entry point and hardware config
│   └── laptop/                  # Workstation config (default, desktop, gaming, tray bridge, Dell EDID)
└── modules/
    ├── common.nix               # Shared Nix settings, locale, timezone, base CLI tools
    ├── devshell.nix             # Dev shell (just, nvd, statix, deadnix, nixfmt)
    └── homelab/
        ├── options.nix          # Shared options and service registry schema
        ├── base.nix             # Boot, Intel GPU, SSH, Cockpit, zramSwap, failure alerts
        ├── networking.nix       # Interface aliases, firewall, Technitium DNS, NetBird
        ├── storage.nix          # ZFS mounts, HDD spindown, rclone mount, ZED & smartd
        ├── backup.nix           # PostgreSQL dumps, Sanoid, Syncoid, Restic, and rclone sync
        ├── samba.nix            # SMB3-only shares (no NetBIOS) restricted to LAN and VPN subnets
        ├── ups.nix              # NUT monitoring, udev rules, and power event alerts
        ├── caddy.nix            # Cloudflare DNS-01 reverse proxy + native Hugo site builder
        ├── homepage.nix         # Dashboard generated from the service registry
        ├── motd.nix             # SSH login summary (uptime, load, failed units, ZFS health)
        └── services/            # One self-contained module per application
```

## Design & Architecture

### Single Service Registry

Web applications are declared once under `homelab.services`. From that definition, Nix generates:

- Reverse-proxy handles in Caddy (`modules/homelab/caddy.nix`)
- Dashboard entries in Homepage (`modules/homelab/homepage.nix`)
- A Markdown overview table via `just services-table`

Adding a new service means adding a module under `modules/homelab/services/`, registering it in `homelab.services`, and importing it in `modules/homelab/default.nix`.

### Pinning & Updates

Both hosts track `nixos-26.05`. `nixpkgs-unstable` is exposed separately as `pkgs-unstable` and used only for packages that need newer releases (currently Immich, NetBird, and SearXNG). A weekly GitHub Actions workflow (`update-flake-lock.yml`) opens a validated PR for stable `nixpkgs` updates; `homelab` disables `system.autoUpgrade` so changes are always deployed intentionally via `just diff`/`just test`/`just switch`, while `laptop` stages updates weekly via `system.autoUpgrade` (Tuesdays `12:00`, `operation = "boot"` on AC power, `allowReboot = false`). `just update` bumps only the stable `nixpkgs` input and prints a package diff via `nvd` without switching; `just update-unstable` is run manually when inspecting database-backed services.

### Networking & Access Control

The server runs on a single 2.5GbE interface (`nic0`, Wake-on-LAN enabled) with dedicated LAN IP aliases separating host management, DNS (Technitium), the reverse proxy (Caddy), and the internal static site listener.

- TLS certificates are issued via Cloudflare DNS-01 without exposing internal services directly to the public internet.
- Private subdomains (including LAN infrastructure proxies for MikroTik, Ubiquiti Switch, ZTE AP, ZTE 5G CPE, and PowerWalker UPS) are restricted in Caddy to LAN and NetBird VPN ranges.
- Local admin interfaces bind to loopback only.
- The public static site is built natively on the host by a Hugo watcher service and served through an external VPS over NetBird.

### Storage & Backups

- **OS disk:** Separate boot SSD (`FAT32` ESP + `ext4` root), keeping OS state decoupled from data pools.
- **Primary pool (`tank`):** ZFS mirror split between service state/databases and NAS data.
- **Local backup pool (`backup`):** Single SATA HDD configured to spin down when idle. All local replication and snapshot pruning runs in a single nightly window so the drive wakes up once per day.
- **Offsite backups:** Critical application state, databases, NixOS uid/gid maps, and runtime secrets are backed up daily with Restic (encrypted). Media, documents, and site source are synced separately to cloud storage with a delete-limit safeguard and a dated `--backup-dir` trash that expires after 30 days.

Nightly & weekly backup/monitoring sequence (all backup and capacity-monitoring timers below are persistent, so jobs missed while the server was off run at the next boot):

1. `23:00` — Consistent Vaultwarden SQLite backup to `/var/lib/backup/vaultwarden` (timer-only; does not run on every boot).
2. `02:15` — PostgreSQL dump of the Immich database.
3. `03:00` — Scheduled `sanoid` snapshots on `tank` (ordered after DB dumps on catch-up boots).
4. `03:05` — `syncoid` replication from `tank` to `backup` (ordered after `sanoid` and DB dumps).
5. `03:20` — Per-class pruning of older replicated snapshots on `backup`.
6. `03:45` — Encrypted offsite Restic backup (`system-encrypted`: databases, app state, `/var/lib/nixos`, and secrets).
7. `03:50` — Encrypted offsite Restic backup (`other-backups-encrypted`: `/mnt/nas-data/Giannis/Library/Backups` and `/mnt/nas-data/Games/saves`).
8. `04:00` — Offsite `rclone` sync of Immich media, documents, and Hugo site source (with 30-day `_deleted/` trash).
9. `08:00` — Daily storage capacity check (`disk-capacity-alert`, alerts `ntfy` if `/`, `/boot`, `tank`, or `backup` ≥ 80%).
10. `Sun 04:30` — Weekly Restic integrity check (`restic-check-gdrive`, `--read-data-subset=5%` on both repositories).

### Monitoring, Power & Secrets

- `smartd`, ZFS ZED, NUT UPS power events (`ONBATT`, `ONLINE`, `LOWBATT`), and systemd `OnFailure` hooks push alerts to a local `ntfy` instance.
- NUT monitors the UPS and initiates a graceful shutdown at 20% battery.
- Headless Gigabyte B660M DS3H DDR4 safeguards keep `boot.loader.efi.canTouchEfiVariables = false`, blacklist `intel_oc_wdt` (so `iTCO_wdt` owns `/dev/watchdog0`), ignore physical power/sleep key presses in `logind.conf`, and enable Wake-on-LAN (`magic`) on `nic0`.
- Runtime credentials never enter Git or the Nix store; they are provisioned out-of-band in a root-only directory on the host.

## Workflow

```bash
# Enter dev shell with formatting and lint tools
nix develop

# Format, evaluate all hosts, and run statix + deadnix
just fmt
just check
just lint

# Build and inspect package diffs without activating
just diff homelab

# Test live (reverts automatically on reboot)
just test homelab

# Persist to bootloader
just switch homelab

# Update stable nixpkgs only and review the diff
just update homelab

# Print the generated service registry table
just services-table
```

For quick-reference recovery, ZFS maintenance, and backup restore drill procedures, see [docs/RUNBOOK.md](docs/RUNBOOK.md).
