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
sudo git clone [https://github.com/kampisellis/nixos-config.git](https://github.com/kampisellis/nixos-config.git) /mnt/etc/nixos
sudo cp /tmp/hardware-configuration.nix /mnt/etc/nixos/hosts/homelab/hardware-configuration.nix
sudo git -C /mnt/etc/nixos add hosts/homelab/hardware-configuration.nix

sudo nixos-install --root /mnt --flake /mnt/etc/nixos#homelab
```

After rebooting, recreate local and Samba passwords if `/etc/shadow` was reset:

```bash
sudo passwd <USER>
sudo smbpasswd -a <USER>
```

---

## 3. Runtime Secrets Bootstrap

Runtime credentials are stored out-of-band in `/var/lib/secrets` (`0700`, `root:root`) and are never committed to Git. When bootstrapping from scratch, provision:

- **Cloudflare DNS-01 token** (`0400`, `root:root`) for Caddy wildcard TLS.
- **SearXNG secret key** (`0400`, `root:root`, generated via `openssl rand -hex 32`).
- **NUT upsmon password** (`0440`, `root:nutmon`).
- **Restic repository password** (`0400`, `root:root`) — keep an offline copy outside the server.
- **rclone backup config** (`0600`, `root:root`) for offsite Restic and cloud sync.
- **Optional rclone mount config** (`0400`, `root:root`; an empty file keeps the ROMs mount service disabled).

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

### Offsite Restic Verification

```bash
sudo restic-gdrive-system snapshots
sudo restic-gdrive-system check
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

nix-shell -p git --run "sudo git clone [https://github.com/kampisellis/nixos-config.git](https://github.com/kampisellis/nixos-config.git) /mnt/etc/nixos"
sudo nixos-generate-config --root /mnt --show-hardware-config | sudo tee /mnt/etc/nixos/hosts/laptop/hardware-configuration.nix > /dev/null
sudo TMPDIR=/mnt/tmp nixos-install --root /mnt --flake /mnt/etc/nixos#laptop
sudo rm -rf /mnt/tmp/*
sudo nixos-enter --root /mnt -c 'passwd <USER>'
```
