# Homelab Operations & Disaster Recovery Runbook

## 1. Safe Deployment & Emergency Rollback

Always validate and inspect diffs before activating on the headless server:

```bash
cd /etc/nixos
just check
just lint
just diff homelab
just test homelab     # Temporary activation (reverts on reboot)
```

Keep your existing SSH session open, verify a second SSH login and core services, then persist:

```bash
just switch homelab
```

### Rollback

- **Live rollback (without reboot):** `sudo nixos-rebuild switch --rollback`
- **From systemd-boot (physical console):** Select the previous generation (up to 5 are retained on `/boot`).

---

## 2. Bare-Metal Root SSD Recovery (`homelab`)

Use this procedure if the 240GB boot SSD fails while the ZFS pools (`tank`, `backup`) remain intact.

### Step 1: Partition & Format ONLY the Replacement Boot SSD

Verify the target disk via `lsblk -o NAME,SIZE,MODEL,SERIAL` and `/dev/disk/by-id/`. Never touch ZFS pool disks.

```bash
DISK="/dev/disk/by-id/<NEW_BOOT_SSD_ID>"

sudo parted "$DISK" -- mklabel gpt
sudo parted "$DISK" -- mkpart ESP fat32 1MiB 512MiB
sudo parted "$DISK" -- set 1 esp on
sudo parted "$DISK" -- mkpart root ext4 512MiB 100%

sudo mkfs.fat -F 32 -n NIXBOOT "${DISK}-part1"
sudo mkfs.ext4 -F -L NIXROOT "${DISK}-part2"
```

### Step 2: Mount Root, Boot, and Import Existing ZFS Pools

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

### Step 3: Clone Repo & Install NixOS

```bash
sudo nixos-generate-config --no-filesystems --root /mnt
sudo cp /mnt/etc/nixos/hardware-configuration.nix /tmp/hardware-configuration.nix
sudo rm -f /mnt/etc/nixos/configuration.nix /mnt/etc/nixos/hardware-configuration.nix
sudo git clone [https://github.com/kampisellis/nixos-config.git](https://github.com/kampisellis/nixos-config.git) /mnt/etc/nixos
sudo cp /tmp/hardware-configuration.nix /mnt/etc/nixos/hosts/homelab/hardware-configuration.nix
sudo git -C /mnt/etc/nixos add hosts/homelab/hardware-configuration.nix

sudo nixos-install --root /mnt --flake /mnt/etc/nixos#homelab
```

After rebooting, set user and Samba passwords if `/etc/shadow` was recreated:

```bash
sudo passwd gkampisellis
sudo smbpasswd -a gkampisellis
```

---

## 3. Clean Bootstrap of Runtime Credentials & CouchDB

If runtime credentials must be recreated from scratch:

```bash
sudo install -d -m 0700 -o root -g root /var/lib/secrets

# 1. Cloudflare DNS-01 API Token (Zone:DNS:Edit)
printf 'CLOUDFLARE_API_TOKEN=%s\n' '<TOKEN>' | sudo tee /var/lib/secrets/caddy.env > /dev/null
sudo chmod 0400 /var/lib/secrets/caddy.env

# 2. SearXNG secret key
printf 'SEARX_SECRET_KEY=%s\n' "$(openssl rand -hex 32)" | sudo tee /var/lib/secrets/searx.env > /dev/null
sudo chmod 0400 /var/lib/secrets/searx.env

# 3. NUT upsmon password
printf '%s\n' '<PASSWORD>' | sudo tee /var/lib/secrets/upsmon.pass > /dev/null
sudo chown root:nut /var/lib/secrets/upsmon.pass
sudo chmod 0440 /var/lib/secrets/upsmon.pass

# 4. Optional rclone config (empty file disables gdrive-roms cleanly)
sudo touch /var/lib/secrets/rclone.conf
sudo chmod 0400 /var/lib/secrets/rclone.conf
```

### Recreating CouchDB `local.ini` (Obsidian LiveSync)

```bash
sudo tee /var/lib/couchdb/local.ini > /dev/null <<'EOF'
[couchdb]
single_node = true
max_document_size = 50000000

[chttpd]
require_valid_user = true
max_http_request_size = 4294967296

[chttpd_auth]
require_valid_user = true
authentication_redirect = /_utils/session.html

[httpd]
WWW-Authenticate = Basic realm="couchdb"
enable_cors = true

[cors]
origins = app://obsidian.md,capacitor://localhost,http://localhost
credentials = true
headers = accept, authorization, content-type, origin, referer
methods = GET, PUT, POST, HEAD, DELETE
max_age = 3600

[admins]
admin = <SET_NEW_ADMIN_PASSWORD_HERE>
EOF
sudo chown couchdb:couchdb /var/lib/couchdb/local.ini
sudo chmod 0600 /var/lib/couchdb/local.ini
sudo systemctl restart couchdb
```

---

## 4. ZFS Maintenance, Snapshots & Syncoid

### Recommended Dataset Properties

```bash
sudo zfs set atime=off compression=lz4 tank/var-lib
sudo zfs set atime=off compression=lz4 tank/data
zfs get atime,compression,recordsize,mountpoint tank/var-lib tank/data
```

### Manual Pre-Change Snapshot

Snapshot only `tank` (not `backup` with the same tag) so Syncoid does not hit a duplicate snapshot collision:

```bash
sudo zfs snapshot -r "tank@manual-$(date +%Y%m%d-%H%M)"
```

If Syncoid ever reports `destination already exists`:

```bash
sudo zfs rename backup/var-lib@<snap> backup/var-lib@local-<snap>
sudo systemctl start syncoid-state-backup.service
```

---

## 5. Updating Caddy Cloudflare Plugin Hash

When a `nixpkgs` bump updates Caddy or Go dependencies in `modules/homelab/caddy.nix`:

1. Run `nixos-rebuild build --flake .#homelab`.
2. Copy the `got: sha256-...` hash from the fixed-output derivation error into `modules/homelab/caddy.nix`.
3. Re-run `just lint` and `just diff homelab`.

---

## 6. Technitium DNS Policy & MikroTik Fallback

Technitium runs from stable NixOS (`15.6.2+`) with `DynamicUser=yes` (`/var/lib/private/technitium-dns-server`).

- **Local End Points:** `127.0.0.1:53`, `10.10.10.5:53`, `10.10.10.101:53`.
- **Forwarders:** `1.1.1.1`, `1.0.0.1`.
- **MikroTik Fallback:** Set DHCP DNS Servers to `10.10.10.101,10.10.10.1`, enable `Allow Remote Requests` on RouterOS (while dropping WAN TCP/UDP 53), and add static fallback entries for `cockpit`, `home`, and `vault` pointing to `10.10.10.105`.

---

## 7. Immich Database Non-Destructive Restore Drill

Daily SQL dumps are written to `/var/lib/backup/postgresql/immich.sql.gz` at `02:15`.

```bash
sudo ls -lh /var/lib/backup/postgresql/

sudo -u postgres dropdb --if-exists immich_restore_test
sudo -u postgres createdb -O immich immich_restore_test
sudo bash -c 'zcat /var/lib/backup/postgresql/immich.sql.gz | sudo -u postgres psql -v ON_ERROR_STOP=1 -d immich_restore_test > /dev/null'

sudo -u postgres psql -d immich_restore_test -c "SELECT count(*) AS assets FROM assets; SELECT count(*) AS users FROM users;"
sudo -u postgres dropdb immich_restore_test
```

---

## 8. Retiring `netbird-local-route-fix`

Once the external VPS and all NetBird peers target `100.76.70.223` directly instead of LAN alias IPs:

1. Point the external VPS upstream for `kampisellis.com` to `100.76.70.223:8085`.
2. Update NetBird ACLs (TCP/UDP 53, TCP 80/443 for personal peers; TCP 8085 for VPS) and NetBird Nameserver to `100.76.70.223` (adding `100.76.70.223:53` to Technitium Local End Points).
3. Set `homelab.netbird.enableLocalRouteFix = false;` in `hosts/homelab/default.nix`, test over 4G/5G + public internet, then `just switch homelab`.

---

## 9. Controlled UPS Shutdown Test (20% Threshold)

```bash
sudo zfs snapshot -r tank@pre-ups-test
upsc myups@localhost | grep -E 'battery.charge|ups.status|battery.runtime'

# WARNING: triggers a real graceful OS shutdown — run only when ready to power back on
sudo upsmon -c fsd
```

Confirm in BIOS that **Restore on AC Power Loss = Power On**.

---

## 10. Laptop Pre-Migration Backup & Install (`ASUS TUF FX505DY`)

### Before Leaving Arch Linux

```bash
mkdir -p ~/arch-migration-backup
pacman -Qqen > ~/arch-migration-backup/pkglist-native.txt
pacman -Qqem > ~/arch-migration-backup/pkglist-aur.txt
flatpak list --app --columns=application > ~/arch-migration-backup/flatpaks.txt 2>/dev/null || true
sudo cp -a /etc/NetworkManager/system-connections ~/arch-migration-backup/nm-connections
sudo chown -R "$USER:$USER" ~/arch-migration-backup/nm-connections
chmod 0700 ~/arch-migration-backup/nm-connections
id > ~/arch-migration-backup/id.txt
lsblk -f > ~/arch-migration-backup/lsblk.txt
```

### Installing NixOS 26.05 (Preserving `/home` and `/efi`)

1. Boot the NixOS 26.05 ISO.
2. Format **only** the root partition (label `NIXLAPTOP`) — do **not** format `/home` (`HOME`) or `/efi` (`EFI`).
3. Mount under `/mnt`, `/mnt/home`, and `/mnt/efi`.
4. Generate `hosts/laptop/hardware-configuration.nix`, verify `nixos-install --flake .#laptop`, and reboot.
