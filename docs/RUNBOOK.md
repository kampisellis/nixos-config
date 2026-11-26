# Operations & Disaster Recovery Runbook

## 1. Safe Deployment & Rollback

Validate and inspect package diffs before activating changes on the headless server:

```bash
cd /etc/nixos
just check
just lint
just diff homelab
just test homelab     # Temporary activation (reverts on reboot)
```

Keep the current SSH session open, verify a second SSH login and core services, then persist:

```bash
just switch homelab
```

- **Live rollback (no reboot):** `sudo nixos-rebuild switch --rollback`
- **Bootloader rollback:** Select the previous generation in `systemd-boot` (up to 5 generations are retained).

### Headless Gigabyte B660M DS3H DDR4 Safeguards & Wake-on-LAN

- **EFI NVRAM lockout protection:** `boot.loader.efi.canTouchEfiVariables = false;` is required on the Gigabyte B660M DS3H DDR4 (boot via the board's `UEFI OS` fallback entry). **Never** run `bootctl` or enable EFI variable writes, as NVRAM writes trigger BIOS `"Boot failure detected"` lockouts.
- **Watchdog:** `intel_oc_wdt` is blacklisted so `iTCO_wdt` reliably owns `/dev/watchdog0` (`RuntimeWatchdogSec = "30s"`).
- **Accidental power/sleep guard:** `services.logind` ignores `HandlePowerKey`, `HandleSuspendKey`, and `HandleHibernateKey`.
- **Wake-on-LAN recovery (`nic0`):** `WakeOnLan=magic` is pinned in `10-nic0.link` (`MAC d8:5e:d3:9c:11:15`). To wake `homelab` remotely from the MikroTik router:
  ```routeros
  /tool wol interface=bridge mac=D8:5E:D3:9C:11:15
  ```
- **Automated updates:** `homelab` disables `system.autoUpgrade` (relying on the Monday `update-flake-lock.yml` PR + manual `just diff`/`just test`/`just switch`). `laptop` runs `system.autoUpgrade` weekly (`Tue 12:00`, `operation = "boot"` on AC power, `allowReboot = false`).

---

## 2. Bare-Metal Boot SSD Recovery (`homelab`)

Use this procedure if the boot SSD fails while the ZFS pools (`tank`, `backup`) remain intact.

### Partition & Format Replacement SSD

Verify the target device with `lsblk -o NAME,SIZE,MODEL,SERIAL` and `/dev/disk/by-id/`. Never touch ZFS pool disks.

```bash
DISK="/dev/disk/by-id/<NEW_BOOT_SSD_ID>"

sudo parted "$DISK" -- mklabel gpt
sudo parted "$DISK" -- mkpart ESP fat32 1MiB 512MiB
sudo parted "$DISK" -- set 1 esp on
sudo parted "$DISK" -- mkpart root ext4 512MiB 100%

sudo mkfs.fat -F 32 -n NIXBOOT "${DISK}-part1"
sudo mkfs.ext4 -F -L NIXROOT "${DISK}-part2"
```

### Mount Filesystems & Import ZFS Pools

```bash
sudo mount /dev/disk/by-label/NIXROOT /mnt
sudo mkdir -p /mnt/boot
sudo mount -o fmask=0077,dmask=0077 /dev/disk/by-label/NIXBOOT /mnt/boot

sudo zpool import -f -R /mnt tank
sudo zpool import -f -R /mnt backup

sudo mkdir -p /mnt/var/lib /mnt/mnt/nas-data
sudo mount -t zfs tank/var-lib /mnt/var/lib
sudo mount -t zfs tank/data /mnt/mnt/nas-data
```

### Clone & Install

```bash
sudo nixos-generate-config --no-filesystems --root /mnt
sudo cp /mnt/etc/nixos/hardware-configuration.nix /tmp/hardware-configuration.nix
sudo rm -f /mnt/etc/nixos/configuration.nix /mnt/etc/nixos/hardware-configuration.nix
sudo git clone https://github.com/kampisellis/nixos-config.git /mnt/etc/nixos
sudo cp /tmp/hardware-configuration.nix /mnt/etc/nixos/hosts/homelab/hardware-configuration.nix
sudo git -C /mnt/etc/nixos add hosts/homelab/hardware-configuration.nix

sudo nixos-install --root /mnt --flake /mnt/etc/nixos#homelab

# Required because boot.zfs.forceImportRoot = false (hostId = "8425e349"):
# cleanly export pools imported under the Live ISO before rebooting so first boot imports both pools.
sudo umount -R /mnt
sudo zpool export tank backup
```

After rebooting, restore repository ownership and recreate local and Samba passwords (SMB3-only on TCP `445`, with NetBIOS/`nmbd`/`winbindd` disabled) if `/etc/shadow` was reset:

```bash
sudo chown -R <USER>:users /etc/nixos
sudo passwd <USER>
sudo smbpasswd -a <USER>
```

---

## 3. Runtime Secrets Bootstrap

Runtime credentials are stored out-of-band in `/var/lib/secrets` (`0700`, `root:root`) and are never committed to Git. When bootstrapping from scratch, provision:

- `/var/lib/secrets/caddy.env` (`0400`, `root:root`) — `CLOUDFLARE_API_TOKEN=<TOKEN>` for Caddy wildcard TLS via Cloudflare DNS-01.
- `/var/lib/secrets/searx.env` (`0400`, `root:root`) — `SEARX_SECRET_KEY=<HEX_KEY>` (generated via `openssl rand -hex 32`) for SearXNG.
- `/var/lib/secrets/upsmon.pass` (`0440`, `root:nutmon`) — `<UPSMON_PASSWORD>` (single-line password) for NUT `upsmon`.
- `/var/lib/secrets/restic.pass` (`0400`, `root:root`) — `<RESTIC_PASSWORD>` (single-line passphrase) for the encrypted Restic repository; keep an offline copy outside the server.
- `/var/lib/secrets/rclone-backup.conf` (`0600`, `root:root`) — rclone configuration defining the `gdrive` remote for offsite Restic and cloud sync.
- `/var/lib/secrets/rclone.conf` (`0600`, `root:root`) — optional rclone configuration defining the `gdrive-roms-crypt` remote (`0600` is required so `rclone` can persist refreshed OAuth2 tokens; an empty file keeps `gdrive-roms.service` cleanly skipped).
- `/var/lib/secrets/healthcheck-url` (`0400`, `root:root`) — optional single-line dead-man's-switch URL pinged by `rclone-gdrive-backup.service` after a successful nightly sync (safe no-op if absent or empty).

---

## 4. ZFS Maintenance & Syncoid

### Dataset Defaults

```bash
sudo zfs set atime=off compression=lz4 tank/var-lib
sudo zfs set atime=off compression=lz4 tank/data
zfs get atime,compression,recordsize,mountpoint tank/var-lib tank/data
```

### Manual Pre-Change Snapshot

Snapshot only `tank` (avoid creating matching tags manually on `backup` to prevent Syncoid collisions):

```bash
sudo zfs snapshot -r "tank@manual-$(date +%Y%m%d-%H%M)"
```

If Syncoid reports a duplicate snapshot on `backup`:

```bash
sudo zfs rename backup/var-lib@<snap> backup/var-lib@local-<snap>
sudo systemctl start syncoid-state-backup.service
```

---

## 5. Updating Caddy Plugin Hash

When a `nixpkgs` update changes Caddy or Go dependencies in `modules/homelab/caddy.nix`:

1. Set `hash = lib.fakeHash;` and run `just build homelab`.
2. Copy the `got: sha256-...` value from the build error into `modules/homelab/caddy.nix`.
3. Run `just lint` and `just diff homelab`.

---

## 6. Backup Verification & Restore Drills

### Immich PostgreSQL Non-Destructive Restore Drill

Daily dumps are written to `/var/lib/backup/postgresql/immich.sql.gz` at `02:15`. Because `pg_dump` includes `\connect immich`, filter everything up to that line so the restore targets only the temporary database:

```bash
sudo gzip -t /var/lib/backup/postgresql/immich.sql.gz && echo "gzip OK"

sudo -u postgres dropdb --if-exists immich_restore_test
sudo -u postgres createdb -T template0 -E UTF8 -l en_US.UTF-8 -O immich immich_restore_test

sudo zcat /var/lib/backup/postgresql/immich.sql.gz \
  | awk 'found { print } $0 == "\\connect immich" { found = 1 }' \
  | sudo -u postgres psql -v ON_ERROR_STOP=1 -d immich_restore_test > /dev/null

sudo -u postgres psql -P pager=off -d immich_restore_test -c "SELECT count(*) AS restored_assets FROM asset;"
sudo -u postgres dropdb --if-exists immich_restore_test
```

### Vaultwarden SQLite Backup Verification

Daily consistent SQLite backups are written to `/var/lib/backup/vaultwarden/`. Verify the latest backup passes SQLite integrity checks in read-only mode:

```bash
LATEST_VW_DB="$(sudo ls -1t /var/lib/backup/vaultwarden/*.sqlite3 | head -n 1)"
echo "Checking: $LATEST_VW_DB"
sudo nix-shell -p sqlite --run "sqlite3 -readonly '$LATEST_VW_DB' 'PRAGMA integrity_check;'"
```

### Offsite Restic Verification

Both encrypted repositories (`system-encrypted` and `other-backups-encrypted`, covering `Library/Backups` and `Games/saves`) are automatically verified every Sunday at `04:30` by `restic-check-gdrive.service` (`--read-data-subset=5%`). To inspect or run manual checks:

```bash
sudo restic-gdrive-system snapshots
sudo restic-gdrive-system check

sudo restic-gdrive-other-backups snapshots
sudo restic-gdrive-other-backups check

# Or trigger the weekly 5% data read-back service manually:
sudo systemctl start restic-check-gdrive.service
```

---

## 7. Controlled UPS Shutdown Test

Verify battery state before triggering a forced shutdown test (confirm BIOS is set to **Restore on AC Power Loss = Power On**):

```bash
sudo zfs snapshot -r tank@pre-ups-test
upsc myups@localhost | grep -E 'battery.charge|ups.status|battery.runtime'

# Triggers a real graceful OS shutdown
sudo upsmon -c fsd
```

---

## 8. Clean Laptop Install (`laptop`)

GPT layout on `/dev/nvme0n1`: `1 GiB` FAT32 ESP (`NIXBOOT`) mounted at `/boot`, remaining space `ext4` (`NIXROOT`) mounted at `/`.

```bash
DISK="/dev/nvme0n1"
sudo parted -s "$DISK" mklabel gpt
sudo parted -s "$DISK" mkpart ESP fat32 1MiB 1025MiB
sudo parted -s "$DISK" set 1 esp on
sudo parted -s "$DISK" mkpart root ext4 1025MiB 100%
sudo udevadm settle

sudo mkfs.fat -F 32 -n NIXBOOT "${DISK}p1"
sudo mkfs.ext4 -F -L NIXROOT "${DISK}p2"

sudo mount "${DISK}p2" /mnt
sudo mkdir -p /mnt/boot /mnt/tmp
sudo mount -o fmask=0077,dmask=0077 "${DISK}p1" /mnt/boot

nix-shell -p git --run "sudo git clone https://github.com/kampisellis/nixos-config.git /mnt/etc/nixos"
sudo nixos-generate-config --root /mnt --show-hardware-config | sudo tee /mnt/etc/nixos/hosts/laptop/hardware-configuration.nix > /dev/null
sudo TMPDIR=/mnt/tmp nixos-install --root /mnt --flake /mnt/etc/nixos#laptop
sudo rm -rf /mnt/tmp/*
sudo nixos-enter --root /mnt -c 'passwd <USER>'
```
