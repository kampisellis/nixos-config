# Homelab & Laptop Operations Runbook

## 1. Safe Deployment & Rollback

Always validate and diff before activating changes on the headless server:

```bash
cd /etc/nixos
just check
just diff homelab
just test homelab     # Temporary activation (reverts on reboot)
```

Keep your current SSH session open and verify a **second** SSH login + critical services before running:

```bash
just switch homelab   # Permanent activation + bootloader entry
```

### Emergency Rollback

- **Without reboot:**
  ```bash
  sudo nixos-rebuild switch --rollback
  ```
- **From systemd-boot menu (physical console):** Select the previous generation (up to 5 generations are retained on `/boot`).

---

## 2. ZFS Snapshots, Sanoid & Syncoid

### Manual Pre-Change Snapshot

Use distinct names on `tank` vs `backup` if snapshotting both manually so Syncoid does not hit a duplicate snapshot name collision:

```bash
TAG="manual-$(date +%Y%m%d-%H%M)"
sudo zfs snapshot -r "tank@${TAG}"
```

### Syncoid Duplicate Snapshot Collision

If `syncoid-state-backup` or `syncoid-data-backup` fails with `destination already exists`:

```bash
sudo zfs rename backup/var-lib@<conflicting-snap> backup/var-lib@local-<conflicting-snap>
sudo systemctl start syncoid-state-backup.service
```

### Pool Health & Scrubs

```bash
sudo zpool status -x
sudo zpool list
```

ZED (`zfs-zed`) and `smartd` forward alerts directly to `http://127.0.0.1:5055/homelab-alerts`.

---

## 3. Out-of-Repo Secrets (`/var/lib/secrets`)

Directory permissions are enforced as `0700 root:root` via `systemd.tmpfiles.rules`.

| File | Consumer | Contents / Notes |
| --- | --- | --- |
| `caddy.env` | `caddy.service` | `CLOUDFLARE_API_TOKEN=...` |
| `searx.env` | `searx.service` | `SEARX_SECRET_KEY=<64-hex-chars>` |
| `upsmon.pass` | `upsd` / `upsmon` | Plaintext password for NUT `upsmon` user |
| `rclone.conf` | `gdrive-roms.service` | Optional; service skips cleanly if empty |

Back up `/var/lib/secrets` encrypted off-host whenever any secret changes.

---

## 4. Updating Caddy Cloudflare Plugin Hash

When updating `nixpkgs` or bumping `github.com/caddy-dns/cloudflare` in `modules/homelab/caddy.nix`:

1. Temporarily set `hash = lib.fakeHash;`.
2. Run `nixos-rebuild build --flake .#homelab`.
3. Copy the `got: sha256-...` value from the error output back into `modules/homelab/caddy.nix`.
4. Re-run `just check` and `just diff homelab`.

---

## 5. NixOS Channel Upgrade Checklist (25.11 -> 26.05)

1. Take a pre-upgrade ZFS snapshot:
   ```bash
   sudo zfs snapshot -r tank@pre-2605
   ```
2. Check live versions vs `nixos-26.05` before toggling any `useUnstable` flags:
   - `immich` (must be >= live PostgreSQL schema version; never downgrade)
   - `vaultwarden` (must be >= live SQLite schema version)
   - `netbird` (must match self-hosted management server & mobile clients)
   - `postgresql` (explicitly pinned to `pkgs.postgresql_16` in `modules/homelab/services/immich.nix`)
3. Keep `boot.initrd.systemd.enable = false;` on this headless ZFS server unless testing with physical console access.
4. Update `nixpkgs.url` in `flake.nix` to `github:NixOS/nixpkgs/nixos-26.05` and run `nix flake update`.
5. Run `just check`, `just diff homelab`, `just test homelab`, verify all services + second SSH session, then `just switch homelab`.

---

## 6. Technitium DNS: Option A vs Option B

- **Option B (default, `homelab.technitium.useUnstable = false`):** Runs Technitium from stable `nixpkgs` with clean config.
- **Option A (`homelab.technitium.useUnstable = true`):** Use only if a legacy v15+ config requires a newer Technitium build from `nixpkgs-unstable`.

---

## 7. Retiring `netbird-local-route-fix`

Currently, `netbird-local-route-fix.service` bridges `netbird-rt-fwd` into `netbird-acl-input-rules` so VPN peers and the external VPS can reach local LAN alias IPs (`10.10.10.101`, `.105`, `.109`) hosted on `nic0`.

Once the external VPS and all NetBird peers target the server's NetBird peer IP (`100.76.70.223`) directly instead of LAN aliases:

1. Set `homelab.netbird.enableLocalRouteFix = false;` in `hosts/homelab/default.nix`.
2. Run `just test homelab`.
3. Verify external VPS -> static site (`:8085`), Caddy subdomains, and Technitium DNS over NetBird.
4. Run `just switch homelab`.

---

## 8. Installing NixOS on ASUS TUF FX505DY (`laptop`)

1. From the existing Arch install, verify UID/GID matches `1000:1000`:
   ```bash
   id giannis
   ```
2. Boot the NixOS 26.05 minimal/graphical ISO.
3. Format **only** the root partition (label `NIXLAPTOP`) — **do NOT format** `/home` (`nvme0n1p2`, label `HOME`) or `/efi` (100 MB ESP, label `EFI`).
4. Mount partitions under `/mnt`, `/mnt/home`, and `/mnt/efi`.
5. Generate hardware config into the cloned repo:
   ```bash
   nixos-generate-config --root /mnt --show-hardware-config > hosts/laptop/hardware-configuration.nix
   ```
6. Install from the flake:
   ```bash
   sudo nixos-install --flake .#laptop
   ```
7. After first boot, install optional Flatpaks (`eu.betterbird.Betterbird`, WhatsApp client if needed).
