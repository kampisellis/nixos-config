# Εγχειρίδιο Αρχιτεκτονικής, Λειτουργίας & Ανάκαμψης (`homelab` & `laptop`)

> **Κατάσταση:** Canonical Technical Architecture & Day-2 Operations Handbook
> **Ημερομηνία επαλήθευσης:** `2026-11-23`
> **Commit αναφοράς:** `d99488f` (`main`)
> **Εύρος:** Ολόκληρο το repository `/etc/nixos` (`homelab`, `laptop`, shared modules, CI/CD) και η ζωντανή υποδομή του `homelab`
> **Συμπληρωματικό έγγραφο:** [docs/RUNBOOK.md](./RUNBOOK.md) (συνοπτικό runbook επείγουσας επέμβασης)

---

## 1. Επισκόπηση Συστήματος & Κατευθυντήριες Αρχές

Η υποδομή αποτελείται από δύο NixOS hosts (`homelab` και `laptop`) που διαχειρίζονται δηλωτικά (declaratively) από ένα ενιαίο Nix Flake στο `/etc/nixos` (GitHub: `kampisellis/nixos-config`), χρησιμοποιώντας **Lix** (`pkgs.lixPackageSets.stable.lix`) ως Nix implementation.

### Βασικές Αρχές Σχεδιασμού
1. **Single Source of Truth (Δηλωτική Υποδομή):** Κάθε υπηρεσία, firewall rule, mount, backup timer και alert ορίζεται στον κώδικα Nix. Δεν υπάρχουν Docker/Podman containers — **100% native NixOS systemd services** με kernel-level sandboxing (`DynamicUser`, `ProtectSystem`, `NoNewPrivileges`, `PrivateTmp`).
2. **Ενιαίο Μητρώο Υπηρεσιών (`homelab.services`):** Κάθε web εφαρμογή δηλώνεται μία φορά στο `homelab.services`. Από αυτή τη δήλωση παράγονται αυτόματα:
   - τα reverse-proxy `handle` blocks στον Caddy (`modules/homelab/caddy.nix`),
   - τα cards στο Homepage dashboard (`modules/homelab/homepage.nix`),
   - ο πίνακας υπηρεσιών μέσω `just services-table` (`bin/generate-services-table.nix`).
3. **Αυστηρός Διαχωρισμός Ρόλων Αποθήκευσης (4-Tier Isolation):**
   - **OS Boot SSD (`ext4` + `vfat`):** Μόνο λειτουργικό σύστημα, `/nix/store`, kernel/EFI και `/var/cache/rclone`. Αν καεί ο boot SSD, τα δεδομένα και τα ZFS pools παραμένουν άθικτα.
   - **Primary ZFS Pool (`tank` — NVMe Mirror):** Γρήγορη, ανεκτική σε βλάβη 1 δίσκου (RAID1) αποθήκευση για stateful app data (`/var/lib`) και προσωπικά NAS αρχεία (`/mnt/nas-data`).
   - **Local Backup ZFS Pool (`backup` — SATA HDD):** Ανεξάρτητο pool σε μηχανικό δίσκο που μένει σε standby/spindown και ξυπνά μία φορά τη νύχτα για `syncoid` replication + snapshot pruning.
   - **Offsite Cloud (Google Drive):** Κρυπτογραφημένα Restic repos (`system-encrypted`, `other-backups-encrypted`), ημερήσιο `rclone sync` (`media`, `documents`, `site`) με 30ήμερο `_deleted/` safety net, και κρυπτογραφημένη βιβλιοθήκη ROMs (`roms-encrypted`).
4. **Zero-Secrets-in-Git:** Κανένας κωδικός, API token ή passphrase δεν μπαίνει στο Git ή στο `/nix/store`. Όλα τα secrets ζουν εκτός repo στο `/var/lib/secrets` (`0700 root:root`).
5. **Defense-in-Depth & Loopback-First:** Όλα τα internal web apps και οι βάσεις δεδομένων ακούν αποκλειστικά σε `127.0.0.1`. Η πρόσβαση γίνεται μόνο μέσω Caddy TLS (`*.kampisellis.com`) από LAN (`10.10.10.0/24`) ή NetBird VPN (`100.64.0.0/10`).

### Υψηλού Επιπέδου Διάγραμμα Αρχιτεκτονικής

```text
                        ┌────────────────────────────────────┐
                        │     Internet / Remote Clients      │
                        │ (Laptop away, Phone, External VPS) │
                        └──────────┬──────────────┬──────────┘
                                   │              │
                     Cloudflare    │              │ WireGuard Mesh (UDP 51820)
                     DNS-01 ACME   │              │ NetBird VPN (100.64.0.0/10)
                                   │              ▼
┌──────────────────────────────┐   │   ┌───────────────────────────────────────────────┐
│        Home LAN              │   │   │          homelab (NixOS 26.05 / Lix)          │
│     10.10.10.0/24            │   │   │  Intel i3-12100 | 31 GiB RAM | 2.5GbE (nic0)  │
│                              │   │   │                                               │
│  ┌────────────────────────┐  │   │   │  IP Aliases on nic0:                          │
│  │ laptop (ASUS TUF)      │◄─┼───┼──►│   .5   Primary / SSH (22) / Samba SMB3 (445)  │
│  │ KDE Plasma 6 Wayland   │  │   │   │   .101 Technitium DNS (53 TCP/UDP)            │
│  │ SMB 3.1.1 Automounts:  │  │   │   │   .105 Caddy Reverse Proxy (80/443)           │
│  │  /mnt/nas-data (rw)    │  │   │   │   .109 Internal Static Site Alias             │
│  │  /mnt/nas-games (rw)   │  │   │   │   wt0  NetBird VPN (100.76.70.223, :8085)     │
│  │  /mnt/roms (ro)        │  │   │   │                                               │
│  │ ES-DE + PCSX2 + RA     │  │   │   │  Loopback-Only Apps (127.0.0.1):              │
│  └────────────────────────┘  │   │   │   Immich, Vaultwarden, CouchDB, Radicale,     │
│                              │   │   │   Lidarr, ntfy-sh, SearXNG, Homepage,         │
│  LAN Infra (via Caddy):      │   │   │   Cockpit, PostgreSQL, Redis x2, NUT upsd     │
│  MikroTik (.1), Switch (.2), │   │   │                                               │
│  ZTE AP (.3), UPS (.253),    │   │   │  Storage Tiers:                               │
│  ZTE 5G (10.10.20.1)         │   │   │   [sdb] OS Boot SSD (ext4 + vfat ESP)         │
└──────────────────────────────┘   │   │   [nvme0+1] ZFS mirror `tank` (/var/lib, NAS) │
                                   │   │   [sda] ZFS `backup` HDD (nightly syncoid)    │
                                   │   └───────────────────────┬───────────────────────┘
                                   │                           │
                                   ▼                           ▼
                        ┌──────────────────────────────────────────────┐
                        │                Google Drive                  │
                        │  • homelab-backups/system-encrypted (Restic) │
                        │  • homelab-backups/other-backups-encrypted   │
                        │  • homelab-backups/{media,documents,site}    │
                        │  • roms-encrypted (rclone crypt VFS mount)   │
                        └──────────────────────────────────────────────┘
```

---

## 2. Αρχιτεκτονική Repository & NixOS Flake (`/etc/nixos`)

### Flake Inputs & Στρατηγική Pinning (`flake.nix`, `flake.lock`)

| Input | Upstream Ref | Κλειδωμένο Commit (`flake.lock`) | Ρόλος |
| :--- | :--- | :--- | :--- |
| `nixpkgs` | `github:nixos/nixpkgs/nixos-26.05` | `f68407657ad2` | Βασικό σταθερό κανάλι για `homelab` και `laptop`. |
| `nixpkgs-unstable` | `github:nixos/nixpkgs/nixos-unstable` | `04906337b6d5` | Εκτίθεται ως `pkgs-unstable` μέσω `specialArgs` μόνο για επιλεγμένα πακέτα που απαιτούν νεότερες εκδόσεις: **Immich** (DB 3.4.1), **NetBird** (0.80.x), **SearXNG**. |

Ο helper `mkHost` στο `flake.nix` επιβάλλει:
- `homelab`: `allowUnfree = false` (αυστηρά free/open-source server stack).
- `laptop`: `allowUnfree = true` (για desktop/proprietary πακέτα όπως Discord, Viber, Spotify, OnlyOffice, VS Code).
- Κοινό module `./modules/common.nix` και στα δύο hosts.
- Custom flake outputs:
  - `formatter.x86_64-linux`: `pkgs.nixfmt-tree` (RFC-166 formatting).
  - `devShells.x86_64-linux.default`: dev shell με `nixfmt`, `statix`, `deadnix`, `just`, `nvd`, `git`, `openssl`.
  - `packages.x86_64-linux.services-table`: αυτόματα παραγόμενος Markdown πίνακας από το `homelab.services`.
  - `checks.x86_64-linux.{formatting,statix,deadnix}`: CI και τοπικοί έλεγχοι ποιότητας.
- Custom package build: Ο Caddy χτίζεται μέσω `pkgs.caddy.withPlugins` με το `github.com/caddy-dns/cloudflare@v0.2.4` (pinned Go vendor hash στο `modules/homelab/caddy.nix`).

### Πλήρες Δέντρο Αρχείων Repository

```text
/etc/nixos/
├── flake.nix                                   # Inputs, mkHost builder, formatter, devShell, checks, services-table
├── flake.lock                                  # Κλειδωμένα hashes για nixos-26.05 και nixos-unstable
├── justfile                                    # Συνταγές check, lint, fmt, build, diff, test, switch, update, clean
├── statix.toml                                 # Κανόνες linter statix (disabled: repeated_keys)
├── README.md                                   # Συνοπτική εισαγωγή του repository
├── bin/
│   └── generate-services-table.nix             # Γεννήτρια Markdown πίνακα από το homelab.services registry
├── docs/
│   ├── HOMELAB_ARCHITECTURE.md                 # Το παρόν πλήρες εγχειρίδιο αρχιτεκτονικής, λειτουργίας & DR
│   └── RUNBOOK.md                              # Συνοπτικό runbook ανάκαμψης & drills
├── .github/workflows/
│   ├── ci.yml                                  # CI σε push/PR: flake check, fmt/statix/deadnix, custom builds (Node 24)
│   └── update-flake-lock.yml                   # Εβδομαδιαίο PR (Δευτέρα 04:00 UTC) μόνο για stable nixpkgs (Node 24)
├── hosts/
│   ├── homelab/
│   │   ├── default.nix                         # Ενεργοποίηση homelab stack, flags useUnstable, weekly autoUpgrade (Tue 05:30)
│   │   └── hardware-configuration.nix          # Kernel modules (kvm-intel, ahci, nvme, dm-snapshot) & Intel microcode
│   └── laptop/
│       ├── default.nix                         # ASUS TUF FX505DY: Plasma 6, AMD GPU, SMB3 mounts, gaming/desktop apps, autoUpgrade
│       └── hardware-configuration.nix          # UUID mounts για NIXROOT/NIXBOOT, kvm-amd, AMD microcode
└── modules/
    ├── common.nix                              # Lix, flakes, nix.gc/optimise, Europe/Athens, journald 500M/1month, base CLI tools
    ├── devshell.nix                            # Ορισμός `nix develop` shell
    └── homelab/
        ├── default.nix                         # Κεντρικό import όλων των homelab modules & services
        ├── options.nix                         # Schema επιλογών (`homelab.domain`, `ips`, `subnets`, `ports`, `services`)
        ├── base.nix                            # Bootloader/Gigabyte guards, watchdog, logind, Intel GPU, SSH, Cockpit, zram, global ntfy alerts
        ├── networking.nix                      # `nic0` MAC pinning & 4 IPs, WoL, firewall (TCP 445-only SMB3), Technitium, NetBird + route-fix, LAN infra proxies
        ├── storage.nix                         # ZFS pools/mounts, ARC max, smartd, ZED, autoScrub, HDD spindown, disk-capacity-alert, gdrive-roms VFS mount
        ├── backup.nix                          # PostgreSQL dump, sanoid, syncoid, snapshot prune, 2x Restic jobs, weekly restic-check, rclone sync
        ├── samba.nix                           # SMB3-only server (`[data]`, `[roms]`), force user/group, masks, no NetBIOS
        ├── ups.nix                             # PowerWalker NUT (`usbhid-ups`), udev rule, `upsmon` -> ntfy alerts, UPS portal proxy
        ├── caddy.nix                           # Caddy + Cloudflare DNS-01 TLS, auto-generated handles, Hugo site watcher + `:8085`
        ├── homepage.nix                        # Homepage dashboard παραγόμενο αυτόματα από `homelab.services`
        ├── motd.nix                            # `homelab-motd` script σε SSH login (uptime, load, failed units, ZFS, df)
        └── services/
            ├── vaultwarden.nix                 # Vaultwarden (SQLite, loopback :8000, nightly backup-vaultwarden)
            ├── immich.nix                      # Immich (unstable, PostgreSQL 16 + Redis, Intel VAAPI `/dev/dri/renderD128`)
            ├── radicale.nix                    # Radicale CalDAV/CardDAV (loopback :5232, bcrypt htpasswd)
            ├── couchdb.nix                     # CouchDB για Obsidian LiveSync (loopback :5984, `ERL_EPMD_ADDRESS=127.0.0.1`)
            ├── lidarr.nix                      # Lidarr music manager (loopback :8686, dataDir `/var/lib/lidarr`)
            ├── ntfy.nix                        # ntfy-sh push notification server (loopback :5055, cache.db)
            └── searxng.nix                     # SearXNG (unstable, loopback :8888, local Redis, `searx.env`)
```

### Συνταγές `justfile` & Καθημερινή Ροή Εργασίας

| Εντολή | Τι κάνει |
| :--- | :--- |
| `just fmt` | Μορφοποιεί όλα τα `.nix` αρχεία επιτόπου με `nix fmt` (RFC-166). |
| `just check` | Τρέχει `nix flake check --no-build --show-trace` (επαλήθευση evaluation & assertions χωρίς build). |
| `just lint` | Χτίζει τα checks `formatting`, `statix`, `deadnix` (`--no-link`). |
| `just services-table` | Τυπώνει τον παραγόμενο Markdown πίνακα υπηρεσιών από `homelab.services`. |
| `just build [host]` | Κάνει `nixos-rebuild build --flake .#<host>` στο `./result` χωρίς ενεργοποίηση. |
| `just diff [host]` | Κάνει build και συγκρίνει `/run/current-system` με `./result` μέσω `nvd diff`. |
| `just test [host]` | Ενεργοποιεί προσωρινά το config (`sudo nixos-rebuild test`) — αναιρετέο με reboot. |
| `just switch [host]` | Ενεργοποιεί μόνιμα και ενημερώνει το boot menu (`sudo nixos-rebuild switch`). |
| `just update [host]` | Αναβαθμίζει **μόνο** το σταθερό `nixpkgs` και δείχνει `just diff` (ποτέ auto-switch). |
| `just update-unstable [host]` | Αναβαθμίζει ρητά το `nixpkgs-unstable` και δείχνει `just diff` (για προσεκτικό έλεγχο Immich/NetBird). |
| `just clean` | Τρέχει `sudo nix-collect-garbage --delete-older-than 14d`. |

---

## 3. Υλικό, Boot, OS Disk & Αποθήκευση ZFS (`homelab`)

### Προδιαγραφές Host & UPS
- **CPU:** 12th Gen Intel Core i3-12100 (4 cores / 8 threads) με ενσωματωμένη Intel UHD Graphics 730 (hardware transcoding για Immich μέσω `intel-media-driver`, `vpl-gpu-rt`, `intel-compute-runtime`, `/dev/dri/renderD128`).
- **RAM:** `31 GiB` φυσική μνήμη + `7.8 GiB` `zramSwap` (`zstd`, 25% RAM).
- **Motherboard:** Gigabyte B660M DS3H DDR4 (headless).
- **Δίκτυο:** Realtek RTL8125 2.5GbE (MAC `d8:5e:d3:9c:11:15`), pinned ως `nic0` με Wake-on-LAN (`magic`).
- **UPS:** PowerWalker VFI 1000 ICR IoT (`PHOENIXTEC Innova Unity`, USB `06da:ffff`, `usbhid-ups`, NUT `mode = "standalone"`, `ups.load ≈ 18%`, runtime `~77 min` στο 100%).
  - Ρυθμισμένο `ignorelb` + `override.battery.charge.low = 20`: ξεκινά καθαρό τερματισμό (`FSD`) μόλις η μπαταρία πέσει στο 20%.
  - Πρόσβαση USB χωρίς root μέσω udev rule (`MODE="0660", GROUP="nutmon"`).
  - Κάθε συμβάν (`ONLINE`, `ONBATT`, `LOWBATT`, `FSD`, `SHUTDOWN`, `COMMOK`, `COMMBAD`, `REPLBATT`, `NOCOMM`) στέλνει άμεσα ειδοποίηση στο `ntfy`.

### Προστασίες Headless Gigabyte B660M DS3H DDR4 (`modules/homelab/base.nix`)
- **`boot.loader.efi.canTouchEfiVariables = false`:** Υποχρεωτικό στη συγκεκριμένη μητρική — εγγραφές στο EFI NVRAM προκαλούν BIOS `"Boot failure detected"` lockout. Το σύστημα bootάρει μέσω του fallback `UEFI OS` entry. **Ποτέ μην τρέχεις `bootctl` στο `homelab`.**
- **`systemd-boot.configurationLimit = 5`:** Περιορίζει τα boot entries ώστε να μην γεμίσει το `511 MiB` FAT32 `/boot` ESP (τρέχουσα χρήση: `12%` / `58M`).
- **Hardware Watchdog:** `intel_oc_wdt` σε blacklist ώστε ο `iTCO_wdt` να ελέγχει το `/dev/watchdog0` με `RuntimeWatchdogSec = "30s"` (αυτόματο reset σε kernel hang).
- **Logind Key Guard:** `HandlePowerKey`, `HandleSuspendKey`, `HandleHibernateKey = "ignore"` ώστε τυχαίο πάτημα κουμπιού ή αποσύνδεση USB πληκτρολογίου να μην κλείνει τον server.
- **CPU Governor:** `powerManagement.cpuFreqGovernor = "powersave"` (βέλτιστη κατανάλωση idle σε 24/7 server).

### Φυσικοί Δίσκοι & Κατάτμηση

| Device | `/dev/disk/by-id` | Μοντέλο | Μέγεθος | Partitions / FS | Ρόλος |
| :--- | :--- | :--- | ---: | :--- | :--- |
| `/dev/sdb` | `ata-KINGSTON_SA400S37240G_50026B7380F798B3` | Kingston SA400 240G | 223.6 GiB | `sdb1` 511M `vfat` (`NIXBOOT` → `/boot`), `sdb2` 223.1G `ext4` (`NIXROOT` → `/`) | OS Boot SSD + `/nix/store` + `/var/cache/rclone` |
| `/dev/nvme0n1` | `nvme-WD_Blue_SN570_1TB_224146456605` (`eui...bac42`) | WD Blue SN570 1TB | 931.5 GiB | `nvme0n1p1` 929.5G `zfs_member` | Primary ZFS pool `tank` (`mirror-0` μέλος 1) |
| `/dev/nvme1n1` | `nvme-WD_Blue_SN570_1TB_224146456611` (`eui...bac68`) | WD Blue SN570 1TB | 931.5 GiB | `nvme1n1p1` 929.5G `zfs_member` | Primary ZFS pool `tank` (`mirror-0` μέλος 2) |
| `/dev/sda` | `ata-ST1000LM035-1RK172_WL1LLNEG` | Seagate ST1000LM035 1TB | 931.5 GiB | `sda1` 929.5G `zfs_member` | Local ZFS pool `backup` (HDD spindown 15 min: `hdparm -B 127 -S 180`) |

### ZFS Pools, Tuning & Datasets

- **ZFS ARC Cap:** `zfs.zfs_arc_max=12884901888` (**12.00 GiB**, ~38% της RAM) — αφήνει άφθονη μνήμη για Immich ML, PostgreSQL, CouchDB και rclone.
- **Pool Tuning & Health:** Και τα δύο pools είναι `ONLINE` με `0` read/write/cksum errors (`tank` `26%` / `11%` frag, `backup` `26%` / `3%` frag). `forceImportRoot = true` (προσωρινά μέχρι φυσική επαλήθευση hostid reboot) και `extraPools = [ "backup" ]`.
- **Προειδοποίηση Ιστορικού Υγείας Δίσκου `/dev/sda` (`backup` pool):** Παρότι το `backup` pool αναφέρει αυτή τη στιγμή `ONLINE` με `0` νέα ZFS errors και το SMART self-assessment περνά (`PASSED`, `Reallocated_Sector_Ct=0`, `Current_Pending_Sector=0`, `Offline_Uncorrectable=0`), ο Seagate `ST1000LM035-1RK172` (`WL1LLNEG`) φέρει ιστορικούς δείκτες σφαλμάτων από την προηγούμενη χρήση του στο Proxmox (**`Reported_Uncorrect = 93`**, **`ATA Error Count = 65`**, καθώς και ιστορικό ZFS permanent errors). Πρέπει να αντιμετωπίζεται ως **προσωρινό μέσο τοπικού backup** και να είναι ο **πρώτος δίσκος προς αντικατάσταση** όταν είναι εφικτό.

| ZFS Dataset | Used | Refer | Avail | Mountpoint | Compression | `atime` | Recordsize | Ρόλος |
| :--- | ---: | ---: | ---: | :--- | :---: | :---: | :---: | :--- |
| `tank` | 246G | 96K | 653G | `/tank` | `lz4` | `off` | `128K` | Root pool (NVMe mirror) |
| `tank/var-lib` | 2.71G | 1.27G | 653G | `legacy` → `/var/lib` (`neededForBoot`) | `lz4` | `off` | `128K` | Stateful app DBs, secrets, configs, backups staging |
| `tank/data` | 243G | 132G | 653G | `legacy` → `/mnt/nas-data` | `lz4` | `off` | `128K` | Προσωπικά αρχεία NAS, Immich media, Games |
| `backup` | 246G | 112K | 654G | `/backup` | `lz4` | `off` | `128K` | Local replica pool (1TB SATA HDD) |
| `backup/var-lib` | 2.06G | 1.28G | 654G | `/backup/var-lib` | `lz4` | `off` | `128K` | Ημερήσιο `syncoid` αντίγραφο του `tank/var-lib` |
| `backup/personal-backup` | 243G | 132G | 654G | `/backup/personal-backup` | `lz4` | `off` | `128K` | Ημερήσιο `syncoid` αντίγραφο του `tank/data` |

### Δομή & Ιδιοκτησία `/mnt/nas-data` (`tank/data`)

```text
/mnt/nas-data/                             (gkampisellis:users, 0777)
├── Games/                                 (gkampisellis:users, 0755)  ~2.7 GiB on-disk ZFS (~4.1 GiB logical)
│   ├── bios/                              # Shared emulator BIOSes (RetroArch & PCSX2)
│   ├── saves/                             # Shared emulator savefiles / PS2 MemoryCards
│   └── states/                            # Shared emulator savestates
└── Giannis/                               (gkampisellis:users, 0777)
    ├── Apps/                              (gkampisellis:users, 0777)
    │   ├── Immich/                        (immich:immich 999:999, 0777)  ~122 GiB — ΜΗΝ κάνεις chown!
    │   │   ├── library/admin/             # Πρωτότυπες φωτό/βίντεο (~115 GiB, sync σε Google Drive)
    │   │   ├── thumbs/, encoded-video/    # Παράγωγα Immich (αναδημιουργούνται)
    │   │   ├── backups/                   # Εσωτερικά Immich DB dumps (0600 immich:immich)
    │   │   └── upload/, profile/          # Uploads / avatars
    │   └── Site/                          (gkampisellis:users, 0755)  ~6.2M — Hugo source για kampisellis.com
    └── Library/                           (gkampisellis:users, 0777)
        ├── Documents/                     (gkampisellis:users, 0775)  ~7.2G — Προσωπικά έγγραφα (sync σε Drive)
        ├── Backups/                       (gkampisellis:users, 0775)  ~345 MiB on-disk ZFS (~483 MiB logical, περιλαμβάνει `migration/`)
        ├── Audio/                         (gkampisellis:users, 0755)  ~63M  — Ηχητικά αρχεία
        └── Notes/                         (gkampisellis:users, 0755)  ~7.1M — Vault σημειώσεων (sync μέσω CouchDB)
```

**Γιατί χωρίζονται οι ιδιοκτησίες:** Όλοι οι προσωπικοί φάκελοι και το `Games/` ανήκουν στον `gkampisellis:users` (`1000:100`) ώστε η Samba (`force user = gkampisellis`) να διαβάζει και να γράφει απρόσκοπτα από Linux & Android. Αντίθετα, το `Apps/Immich/` ανήκει στον system user `immich:immich` (`999:999`) που τρέχει το `immich-server.service` — ένα τυφλό `chown -R` σε όλο το `/mnt/nas-data` θα έσπαγε το Immich.

---

## 4. Δίκτυο, DNS, VPN, Reverse Proxy, TLS & Ασφάλεια

### Διαχωρισμός IPv4 Aliases στο `nic0`
Το `homelab` χρησιμοποιεί στατική δικτύωση (`useDHCP = false`, gateway MikroTik `10.10.10.1`) με τέσσερις IPv4 διευθύνσεις στο `nic0`, επιτρέποντας καθαρό διαχωρισμό ρόλων:
- **`10.10.10.5` (`ips.primary`):** Host management, SSH (`22/tcp`), Samba SMB 3.1.1 (`445/tcp`).
- **`10.10.10.101` (`ips.dns`):** Technitium DNS (`53/tcp+udp`) — εξυπηρετεί Split DNS για το LAN.
- **`10.10.10.105` (`ips.caddy`):** Caddy reverse proxy (`80/tcp`, `443/tcp`) — στόχος για `*.kampisellis.com` στο Split DNS.
- **`10.10.10.109` (`ips.site`):** Δευτερεύουσα διεύθυνση για το static site backend.
- **`100.76.70.223` (`wt0`):** NetBird WireGuard mesh VPN interface (`100.64.0.0/10`, UDP `51820`).

### Ροή Κυκλοφορίας (Home LAN vs. Remote VPN vs. Public Site)

```text
1) HOME LAN (10.10.10.0/24):
   Client ──► Technitium DNS (10.10.10.101:53) ──► *.kampisellis.com = 10.10.10.105
          ──► Caddy (10.10.10.105:443, TLS via Cloudflare DNS-01)
          ──► ACL check: client_ip ∈ private_ranges ∪ 100.64.0.0/10 (PASS)
          ──► reverse_proxy 127.0.0.1:<app-port> (ή LAN infra IP)

2) REMOTE VIA NETBIRD VPN (100.64.0.0/10):
   Mobile/Laptop ──► WireGuard tunnel (wt0) ──► Technitium DNS (100.76.70.223:53)
                 ──► netbird-local-route-fix bridges netbird-rt-fwd → INPUT (για .101/.105/.109)
                 ──► Caddy (443) ──► ACL PASS ──► 127.0.0.1:<app-port>

3) PUBLIC STATIC SITE (https://kampisellis.com):
   Hugo source (/mnt/nas-data/Giannis/Apps/Site)
     ──► kampisellis-site-hugo (--watch --minify)
     ──► /var/lib/kampisellis-site/site
     ──► Caddy plain HTTP :8085 (ανοιχτό ΜΟΝΟ στο wt0)
     ──► External VPS over NetBird ──► Public Internet
```

### Βασικά Στοιχεία Δικτύου & Ασφάλειας
- **Technitium DNS (`networking.nix`):** Split DNS ώστε τα `*.kampisellis.com` να επιλύονται τοπικά σε `10.10.10.105` χωρίς hairpin NAT. Παρέχει DNS-over-HTTPS (`/dns-query*` μέσω `https://dns.kampisellis.com` → `127.0.0.1:8053`) και admin UI μέσω Caddy (`127.0.0.1:5380`). Το `openFirewall = false` εμποδίζει άμεση πρόσβαση στο `:5380` (μπλοκαρισμένο από `nixos-fw`).
- **NetBird & `netbird-local-route-fix`:** Το `netbird-wt0` τρέχει από `nixpkgs-unstable` (`0.80.x`) με `useRoutingFeatures = "both"` και χωρίς blanket `trustedInterfaces`. Επειδή οι VPN peers και ο εξωτερικός VPS χτυπούν τις τοπικές alias IPs (`.101/.105/.109`) που ανήκουν στον ίδιο host, τα πακέτα περνούν από `INPUT` αντί `FORWARD`. Το `netbird-local-route-fix.service` προσθέτει αυτόματα `jump netbird-rt-fwd` στο `ip netbird netbird-acl-input-rules` και ειδοποιεί το `ntfy` αν λείπει το chain για >30s.
- **Caddy & TLS (`caddy.nix`):** Εκδίδει αυτόματα wildcard πιστοποιητικά (`kampisellis.com`, `www.kampisellis.com`, `*.kampisellis.com`) μέσω **Cloudflare DNS-01** (`CLOUDFLARE_API_TOKEN` από `/var/lib/secrets/caddy.env`, resolvers `1.1.1.1 8.8.8.8`), χωρίς να χρειάζεται έκθεση των θυρών 80/443 στο public internet. Όλα τα `*.kampisellis.com` επιβάλλουν `@blocked` (`403 Forbidden` εκτός `private_ranges` & `100.64.0.0/10`) και security headers (`X-Robots-Tag: noindex`, `X-Content-Type-Options: nosniff`, `Referrer-Policy`).
- **Firewall (`iptables nixos-fw`):**
  - Default policy: **Refuse & Log** (`nixos-fw-log-refuse`).
  - Ανοιχτές θύρες: TCP `22` (SSH), `53` (DNS), `80`/`443` (Caddy), `445` (Samba SMB3 μόνο — **μηδέν** legacy NetBIOS rules `137`/`138`/`139`), UDP `53` (DNS).
  - Αποκλειστικά στο `wt0`: TCP `8085` (Hugo static site για VPS), UDP `5353`, `22054`.
- **SSH Hardening (`base.nix`):** `PasswordAuthentication = false`, `KbdInteractiveAuthentication = false`, `PermitRootLogin = "no"`. Μόνο Ed25519 keys για τον `gkampisellis`.
- **Loopback-Only Bindings:** Όλα τα app daemons (`vaultwarden`, `immich`, `couchdb` + `epmd` με `ERL_EPMD_ADDRESS=127.0.0.1`, `radicale`, `lidarr`, `ntfy-sh`, `searx`, `homepage`, `cockpit`, `postgresql`, `redis-*`, `upsd`, `caddy admin`) ακούν αποκλειστικά σε `127.0.0.1`/`::1`.

---

## 5. Πλήρες Μητρώο Υπηρεσιών & Stateful Δεδομένων (`homelab`)

Δεν εκτελείται κανένα Docker/Podman container — όλες οι υπηρεσίες είναι native NixOS systemd units (35 ενεργές running services συνολικά).

### Α. Εγγεγραμμένες Web Υπηρεσίες (`homelab.services` — 16 entries)

| Υπηρεσία | Nix Module | Port / Binding | URL / Πρόσβαση | Data / DB Path | Backup Coverage | Σκοπός |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Immich** | `services/immich.nix` | `127.0.0.1:2283` (API), `:3003` (ML) | `https://photos.kampisellis.com` | Media: `/mnt/nas-data/Giannis/Apps/Immich`, DB: PostgreSQL `immich`, Redis: `redis-immich` | DB: Restic (`system-encrypted`) · Media: `rclone` (`media`) · Local: `syncoid` | Διαχείριση φωτογραφιών & βίντεο (`pkgs-unstable`) |
| **Vaultwarden** | `services/vaultwarden.nix` | `127.0.0.1:8000` | `https://vault.kampisellis.com` | `/var/lib/vaultwarden` (SQLite + RSA keys) → nightly dump `/var/lib/backup/vaultwarden` | Restic (`system-encrypted`) · Local: `syncoid` | Password & 2FA manager (`SIGNUPS_ALLOWED = false`) |
| **Obsidian LiveSync** | `services/couchdb.nix` | `127.0.0.1:5984` (`epmd`: `127.0.0.1:4369`) | `https://obsidian.kampisellis.com/_utils` | `/var/lib/couchdb` | Restic (`system-encrypted`) · Local: `syncoid` | CouchDB backend για συγχρονισμό σημειώσεων Obsidian |
| **Radicale** | `services/radicale.nix` | `127.0.0.1:5232` | `https://webdav.kampisellis.com` | `/var/lib/radicale/collections` & `/var/lib/radicale/users` | Restic (`system-encrypted`) · Local: `syncoid` | CalDAV & CardDAV (επαφές & ημερολόγιο) |
| **Lidarr** | `services/lidarr.nix` | `127.0.0.1:8686` | `https://lidarr.kampisellis.com` | `/var/lib/lidarr` (SQLite + config) | Restic (`system-encrypted`) · Local: `syncoid` | Διαχείριση μουσικής βιβλιοθήκης |
| **Cockpit** | `base.nix` | `127.0.0.1:9090` (socket) | `https://cockpit.kampisellis.com` | Stateless (διαβάζει systemd/host) | N/A (δηλωτικό NixOS) | Web UI διαχείρισης NixOS server |
| **Technitium DNS** | `networking.nix` | `53` (LAN/VPN/lo), `*:5380` (firewalled), `lo:8053` (DoH) | `https://dns.kampisellis.com` | `/var/lib/private/technitium-dns-server` | Restic (`system-encrypted`) · Local: `syncoid` | Split DNS, local zones, blocklists & DoH |
| **ntfy** | `services/ntfy.nix` | `127.0.0.1:5055` | `https://ntfy.kampisellis.com` | `/var/lib/ntfy-sh/cache.db` | Local: `syncoid` (cache, αναλώσιμο) | Self-hosted push notifications (`homelab-alerts`) |
| **SearXNG** | `services/searxng.nix` | `127.0.0.1:8888` (+ `redis-searx`) | `https://search.kampisellis.com` | Stateless (config από Nix + `/var/lib/secrets/searx.env`) | Secret στο Restic (`system-encrypted`) | Metasearch engine (`pkgs-unstable`, Bing/DDG/Brave/Wiki) |
| **Homepage** | `homepage.nix` | `127.0.0.1:3000` | `https://home.kampisellis.com` | Stateless (παράγεται από `homelab.services`) | N/A (δηλωτικό NixOS) | Κεντρικό dashboard υπηρεσιών |
| **CV Redirect** | `caddy.nix` | Caddy handle | `https://cv.kampisellis.com` | N/A | N/A | Μόνιμο redirect `301` → `https://kampisellis.com{uri}` |
| **MikroTik** | `networking.nix` | Proxy → `10.10.10.1:80` | `https://mikrotik.kampisellis.com` | Εξωτερική συσκευή (RouterOS) | N/A | LAN/VPN HTTPS proxy προς router |
| **Ubiquiti Switch** | `networking.nix` | Proxy → `https://10.10.10.2` | `https://switch.kampisellis.com` | Εξωτερική συσκευή | N/A | LAN/VPN HTTPS proxy προς core switch |
| **ZTE AP** | `networking.nix` | Proxy → `http://10.10.10.3` | `https://ap.kampisellis.com` | Εξωτερική συσκευή | N/A | LAN/VPN HTTPS proxy προς Wi-Fi AP |
| **ZTE 5G** | `networking.nix` | Proxy → `http://10.10.20.1` | `https://5g.kampisellis.com` | Εξωτερική συσκευή | N/A | LAN/VPN HTTPS proxy προς 5G CPE modem |
| **PowerWalker UPS** | `ups.nix` | Proxy → `https://10.10.10.253` | `https://ups.kampisellis.com` | Εξωτερική κάρτα UPS IoT | N/A | LAN/VPN HTTPS proxy προς UPS portal |

### Β. Υπηρεσίες Υποδομής, Αποθήκευσης & Συστήματος (`homelab`)

| Υπηρεσία (systemd) | Nix Module | Binding / Πόρος | Data / State Path | Backup Coverage | Σκοπός |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `caddy.service` | `caddy.nix` | `*:80`, `*:443`, `*:8085`, `127.0.0.1:2019` | `/var/lib/caddy` (ACME certs), `/var/lib/kampisellis-site/site` | Local: `syncoid` (certs ανανεώνονται αυτόματα) | Reverse proxy, TLS DNS-01 & static site HTTP server |
| `kampisellis-site-hugo.service` | `caddy.nix` | File watcher (`hugo --watch`) | Source: `/mnt/nas-data/Giannis/Apps/Site` → Out: `/var/lib/kampisellis-site/site` | Source στο `rclone` (`site`) + `syncoid` | Αυτόματο build (με `dart-sass` & `--minify`) του `kampisellis.com` |
| `postgresql.service` | `services/immich.nix`, `backup.nix` | `127.0.0.1:5432` | `/var/lib/postgresql` (PG 16) → dump `/var/lib/backup/postgresql/immich.sql.gz` | Dump στο Restic (`system-encrypted`) + `syncoid` | Βάση δεδομένων Immich (pinned σε `postgresql_16`) |
| `redis-immich` / `redis-searx` | `immich.nix`, `searxng.nix` | Local sockets | Cache / queues | Εφήμερο | Caching & job queues για Immich & SearXNG |
| `samba-smbd` / `samba-winbindd` | `samba.nix` | `0.0.0.0:445`, `[::]:445` | `/var/lib/samba` (tdbsam DB), shares `/mnt/nas-data` & `/mnt/roms` | Local: `syncoid` | SMB 3.1.1 file sharing σε LAN & NetBird VPN |
| `gdrive-roms.service` | `storage.nix` | FUSE mount `/mnt/roms` | Cache: `/var/cache/rclone` (80G cap) → `gdrive-roms-crypt:` | Source είναι ήδη στο Google Drive (`roms-encrypted`) | Read-only κρυπτογραφημένο cloud mount για ROMs |
| `netbird-wt0` + `netbird-local-route-fix` | `networking.nix` | `wt0` (`100.76.70.223`), UDP `51820` | `/var/lib/netbird-wt0` | Local: `syncoid` | WireGuard mesh VPN & INPUT ACL routing fix |
| `upsdrv` / `upsd` / `upsmon` | `ups.nix` | `127.0.0.1:3493`, USB `06da:ffff` | `/var/lib/secrets/upsmon.pass` | Secret στο Restic (`system-encrypted`) | Παρακολούθηση UPS & ασφαλές shutdown στο 20% |
| `smartd.service` | `storage.nix` | Block devices (`sda,sdb,nvme0,nvme1`) | N/A | N/A | SMART monitoring & alerts στο `ntfy` |
| `zfs-zed.service` | `storage.nix` | ZFS kernel events | N/A | N/A | ZFS Event Daemon alerts στο `ntfy` |
| `sshd.service` | `base.nix` | `0.0.0.0:22`, `[::]:22` | `/etc/ssh` | N/A | Key-only απομακρυσμένη διαχείριση |
| `systemd-oomd`, `nix-daemon`, `journald`, `timesyncd`, `logind`, `nscd`, `dbus-broker`, `udevd` | `base.nix`, `common.nix` | System daemons | `/var/log/journal` (≤500M) | N/A | Βασικές υπηρεσίες λειτουργικού & OOM protection |

### Σημειώσεις Ασφαλούς Επίμονης Αποθήκευσης (Stateful Persistence)
- **Immich + PostgreSQL 16:** Η live βάση δεδομένων δεν αντιγράφεται ωμά από τον δίσκο στο Restic. Στις `02:15` το `postgresqlBackup-immich.service` παράγει συνεπές logical dump (`/var/lib/backup/postgresql/immich.sql.gz`), το οποίο καταγράφεται στο ZFS snapshot των `03:00` και ανεβαίνει κρυπτογραφημένο στο Restic στις `03:45`.
- **Vaultwarden:** Χρησιμοποιεί SQLite (`/var/lib/vaultwarden`). Στις `23:00` το `backup-vaultwarden.service` εκτελεί online SQLite backup + αντιγραφή RSA keys στο `/var/lib/backup/vaultwarden`, εξασφαλίζοντας συνεπή ανάκτηση χωρίς corruption από ανοιχτά WAL files.
- **CouchDB / Radicale / Lidarr / Technitium:** Αποθηκεύουν τη μόνιμη κατάστασή τους στο `tank/var-lib` (`/var/lib/{couchdb,radicale,lidarr,private/technitium-dns-server}`) και καλύπτονται τόσο από ZFS snapshots/Syncoid όσο και από το ημερήσιο Restic `gdrive-system`.
- **Static UID/GID Consistency:** Το `/var/lib/nixos` περιλαμβάνεται στο Restic ώστε μετά από πλήρες bare-metal rebuild τα δυναμικά allocated UIDs/GIDs (π.χ. `immich=999`) να ταιριάζουν με την ιδιοκτησία των αρχείων στο ZFS.

---

## 6. Κοινή Χρήση Αρχείων (SMB 3.1.1), Cloud VFS & Αρχιτεκτονική `laptop`

### Samba SMB 3.1.1 (`modules/homelab/samba.nix`)
- **Πρωτόκολλο & Ασφάλεια:** `security = "user"`, `server min protocol = "SMB3"`, `disable netbios = "yes"`, `smb ports = "445"`, `nmbd.enable = false`, `openFirewall = false` (ανοίγει ρητά μόνο TCP `445` στο `networking.nix`), `invalid users = [ "root" ]`, `hosts allow = "10.10.10.0/24 100.64.0.0/10 127.0.0.1"`.

| Share | Local Path (`homelab`) | Access | Ownership / Masks | Χρήση |
| :--- | :--- | :--- | :--- | :--- |
| `[data]` | `/mnt/nas-data` | Read/Write (`valid users = gkampisellis`) | `force user = gkampisellis`, `force group = users`, `create mask = 0664`, `directory mask = 0775` | Προσωπικά αρχεία NAS (Dolphin, Android Material Files) + subpath `//10.10.10.5/data/Games` για `/mnt/nas-games` |
| `[roms]` | `/mnt/roms` | Read-Only (`valid users = gkampisellis`) | Read-only FUSE mount | Streaming βιβλιοθήκης ROMs από Google Drive |

### Cloud VFS Mount (`gdrive-roms.service` στο `modules/homelab/storage.nix`)
- Εντολή mount:
  ```text
  rclone mount gdrive-roms-crypt: /mnt/roms \
    --config=/var/lib/secrets/rclone.conf --allow-other --read-only \
    --vfs-cache-mode full --vfs-cache-max-size 80G --vfs-cache-max-age 336h \
    --vfs-read-ahead 256M --buffer-size 64M --cache-dir /var/cache/rclone
  ```
- **Γιατί αυτές οι ρυθμίσεις:** Το `--vfs-cache-mode full` με όριο `80G` στον OS SSD (`/dev/sdb2`, 161G ελεύθερα) κρατά τοπικά τα ενεργά PS2/Dreamcast `.chd` chunks, ενώ τα `--vfs-read-ahead 256M` και `--buffer-size 64M` εξαλείφουν τα κολλήματα 1–2 δευτερολέπτων σε open-world streaming παιχνίδια. Με `ConditionFileNotEmpty = "/var/lib/secrets/rclone.conf"` η υπηρεσία παραλείπεται καθαρά αν δεν έχει ρυθμιστεί το `rclone.conf`.

### Αρχιτεκτονική `laptop` (`hosts/laptop/default.nix`)
- **Υλικό:** ASUS TUF FX505DY — AMD Ryzen 5 3550H (Vega 8 iGPU) + διακριτή AMD Radeon RX 560X (`DRI_PRIME=1`, Vulkan RADV Polaris 11), `zramSwap` 50%, `power-profiles-daemon`, `switcherooControl`, `amdgpu` initrd module, `bluetooth.powerOnBoot = true`.
- **Desktop & Περιβάλλον:** KDE Plasma 6 + SDDM (Wayland), PipeWire (ALSA 32-bit + Pulse + JACK), US/GR keyboard (`Alt+Shift`), `allowUnfree = true`, AppImage `binfmt`, `pkgs.game-devices-udev-rules` (υποστήριξη hidraw/uaccess για διπλά 8BitDo Pro 3 Bluetooth/USB), `system.autoUpgrade` (Τρίτη `12:00` `operation = "boot"`, `allowReboot = false`, `ConditionACPower = true`).
- **Μόνιμα SMB 3.1.1 Automounts (`hosts/laptop/default.nix`):**

| Mountpoint (`laptop`) | SMB Device | Mode | Ownership (`laptop`) | Κοινές επιλογές |
| :--- | :--- | :---: | :--- | :--- |
| `/mnt/nas-data` | `//10.10.10.5/data` | `rw` | `uid=1000,gid=1000` (`0644`/`0755`) | `x-systemd.automount`, `noauto`, `x-systemd.device-timeout=5s`, `x-systemd.mount-timeout=5s`, `nofail`, `_netdev`, `soft`, `vers=3.1.1`, `credentials=/var/lib/secrets/smb-homelab.cred` |
| `/mnt/nas-games` | `//10.10.10.5/data/Games` | `rw` | `uid=1000,gid=1000` (`0644`/`0755`) | Ίδιες επιλογές (shared BIOS, saves, states) |
| `/mnt/roms` | `//10.10.10.5/roms` | `ro` | `uid=1000,gid=100` (`0444`/`0555`) | Ίδιες επιλογές (read-only ROMs library) |

- **Γιατί λείπει σκόπιμα το `x-systemd.idle-timeout`:** Ένα μικρό `idle-timeout` (π.χ. 60s) προκαλούσε αυτόματο unmount ενώ το Dolphin έμενε ανοιχτό σε φάκελο του NAS (`is no longer accessible`). Χωρίς `idle-timeout` και με `x-systemd.automount` + `noauto` + `soft` + `nofail` + 5s timeouts, τα shares δεν μπλοκάρουν ποτέ το boot/suspend εκτός σπιτιού και δεν αποσυνδέονται ποτέ από το Dolphin.
- **Gaming / Emulation Stack (`laptop`):**
  - Declarative πακέτα: `pcsx2` (standalone 2.8.2) και `retroarch.withCores` (`beetle-psx-hw`, `bsnes`, `dolphin`, `fbneo`, `flycast`, `genesis-plus-gx`, `melonds`, `mgba`, `mupen64plus`, `ppsspp`, `snes9x`).
  - Frontend: ES-DE AppImage (`~/.local/share/applications/es-de.desktop`), εκκινεί με `powerprofilesctl launch -p performance -r "ES-DE Gaming" -- env DRI_PRIME=1 ...` ώστε να ενεργοποιείται αυτόματα το `performance` profile και η RX 560X και να επανέρχεται το προηγούμενο profile στην έξοδο.
  - Διαδρομές δεδομένων: ROMs από `/mnt/roms` (ro), BIOS από `/mnt/nas-games/bios`, saves από `/mnt/nas-games/saves` (PS2 memory cards στο `/mnt/nas-games/saves/ps2`), savestates από `/mnt/nas-games/states`, τοπικό scraped artwork/videos στο `~/ES-DE/downloaded_media` (χωρίς manuals).

---

## 7. Αρχιτεκτονική Αντιγράφων Ασφαλείας (Στρατηγική 3-2-1)

### Διάγραμμα Ροής 3 Επιπέδων

```text
TIER 1: Primary NVMe Mirror (`tank`)         TIER 2: Local SATA HDD (`backup`)        TIER 3: Offsite Google Drive
────────────────────────────────────         ─────────────────────────────────        ────────────────────────────
/var/lib/vaultwarden ──(23:00)──► /var/lib/backup/vaultwarden ─┐
Immich PostgreSQL    ──(02:15)──► /var/lib/backup/postgresql  ─┤
                                                               │
tank/var-lib  ──(hourly sanoid)──► snapshots ──(03:05 syncoid)─┼─► backup/var-lib
tank/data     ──(hourly sanoid)──► snapshots ──(03:05 syncoid)─┼─► backup/personal-backup
                                                (03:20 prune)  │
                                                               │
  [03:45] restic-backups-gdrive-system (encrypted) ────────────┼────────────────────► gdrive:homelab-backups/system-encrypted
  [03:50] restic-backups-gdrive-other-backups (encrypted) ─────┼────────────────────► gdrive:homelab-backups/other-backups-encrypted
  [04:00] rclone-gdrive-backup (unencrypted sync + _deleted/) ─┼────────────────────► gdrive:homelab-backups/{media,documents,site}
  [Sun 04:30] restic-check-gdrive (--read-data-subset=5%) ◄────┼────────────────────► Επαλήθευση ακεραιότητας & data packs
```

### Αναλυτική Περιγραφή Κάθε Εργασίας Backup (`modules/homelab/backup.nix`)

1. **Pre-Backup Database Dumps:**
   - `backup-vaultwarden` (`23:00` καθημερινά): Συνεπές SQLite backup + RSA keys → `/var/lib/backup/vaultwarden`.
   - `postgresqlBackup-immich` (`02:15` καθημερινά): `pg_dump` συμπιεσμένο (`gzip`) → `/var/lib/backup/postgresql/immich.sql.gz`.
2. **Τοπικά ZFS Snapshots (`sanoid`) & Replication (`syncoid`):**
   - `sanoid` (κάθε ώρα):
     - `tank/var-lib`: `24` hourly, `30` daily, `3` monthly.
     - `tank/data`: `48` hourly, `30` daily, `6` monthly.
   - `syncoid` (`03:05` καθημερινά, `--no-sync-snap`): Κάνει incremental ZFS send/receive από `tank/var-lib` → `backup/var-lib` και `tank/data` → `backup/personal-backup`.
   - `backup-snapshot-prune` (`03:20` καθημερινά): Εφαρμόζει ακριβώς την ίδια διατήρηση snapshots στο pool `backup` μέσα στο ίδιο παράθυρο αφύπνισης του HDD.
   - **Γιατί snapshots ≠ backups:** Τα snapshots στο `tank` προστατεύουν από τυχαία διαγραφή/ransomware, αλλά χάνονται αν καταστραφεί όλο το pool ή το μηχάνημα. Το `backup` προστατεύει από απώλεια του `tank`, ενώ μόνο το Google Drive (Tier 3) προστατεύει από φωτιά, κλοπή ή ταυτόχρονη βλάβη υλικού.
3. **`restic-backups-gdrive-system` (`03:45` καθημερινά, `Persistent=true`):**
   - Προορισμός: `rclone:gdrive:homelab-backups/system-encrypted` (AES-256 κρυπτογράφηση, κλειδί `/var/lib/secrets/restic.pass`).
   - Διαδρομές: `/var/lib/backup/postgresql`, `/var/lib/backup/vaultwarden`, `/var/lib/radicale`, `/var/lib/couchdb`, `/var/lib/lidarr`, `/var/lib/private/technitium-dns-server`, `/var/lib/nixos`, `/var/lib/secrets`.
   - Διατήρηση: `--keep-daily 7 --keep-weekly 4 --keep-monthly 6`.
4. **`restic-backups-gdrive-other-backups` (`03:50` καθημερινά, `Persistent=true`, `RequiresMountsFor=/mnt/nas-data`):**
   - Προορισμός: `rclone:gdrive:homelab-backups/other-backups-encrypted` (ίδιο `restic.pass` & `rclone-backup.conf`).
   - Διαδρομή: `/mnt/nas-data/Giannis/Library/Backups`.
   - Διατήρηση: `--keep-daily 7 --keep-weekly 4 --keep-monthly 6`.
   - **Γιατί ξεχωριστό Restic repository:** Απομονώνει τα κρίσιμα system/DB restores από τα προσωπικά αρχεία recovery (μικρότερο index, ανεξάρτητο locking, καθαρότερη επαναφορά).
   - **Γιατί στο Google Drive φαίνονται φάκελοι `config`, `data`, `index`, `keys`, `locks`, `snapshots`:** Αυτή είναι η τυπική δομή ενός κρυπτογραφημένου Restic repository — τα αρχεία τεμαχίζονται (content-defined chunking), αποδιπλασιάζονται (deduplication) και κρυπτογραφούνται πριν ανέβουν. Η ανάγνωση γίνεται αποκλειστικά μέσω `restic` (ποτέ απευθείας από το web UI του Drive).
5. **`rclone-gdrive-backup` (`04:00` καθημερινά, `Persistent=true`, `RequiresMountsFor=/mnt/nas-data`):**
   - Εκτελεί **`rclone sync`** (αμφίδρομη αντιστοίχιση προορισμού με την πηγή) με flags `--fast-list --transfers=4 --checkers=8 --max-delete=200`:
     - `/mnt/nas-data/Giannis/Apps/Immich/library/admin` → `gdrive:homelab-backups/media`
     - `/mnt/nas-data/Giannis/Library/Documents` → `gdrive:homelab-backups/documents`
     - `/mnt/nas-data/Giannis/Apps/Site` → `gdrive:homelab-backups/site`
   - **Προστασία από διαγραφές:** Αν ένα αρχείο διαγραφεί ή τροποποιηθεί τοπικά, το `rclone sync` **δεν** το καταστρέφει άμεσα — το μετακινεί στο `gdrive:homelab-backups/_deleted/YYYY-MM-DD/{media,documents,site}`! Επιπλέον, το `--max-delete=200` ματαιώνει το sync αν εξαφανιστούν μαζικά >200 αρχεία. Οι φάκελοι `_deleted/YYYY-MM-DD` καθαρίζονται αυτόματα μετά από **30 ημέρες**.
6. **Εβδομαδιαία Επαλήθευση Ακεραιότητας (`restic-check-gdrive`, Κυριακή `04:30` EET):**
   - Τρέχει διαδοχικά `restic-gdrive-system check --read-data-subset=5%` και `restic-gdrive-other-backups check --read-data-subset=5%`. Επαληθεύει indexes, snapshots και διαβάζει τυχαίο 5% των data packs κάθε εβδομάδα (πλήρης σάρωση κάθε ~20 εβδομάδες χωρίς υπερβολικό egress).

### Πίνακας Κάλυψης Δεδομένων (Προστατευμένα vs. Σκόπιμα Εκτός Cloud)

| Διαδρομή (`homelab`) | Τοπικά Snapshots (`tank`) | Local Replica (`backup`) | Offsite Cloud (Google Drive) | Σχόλιο |
| :--- | :---: | :---: | :---: | :--- |
| `/var/lib/backup/{postgresql,vaultwarden}` | ✅ | ✅ | ✅ Restic `system-encrypted` | Συνεπή νυχτερινά DB dumps |
| `/var/lib/{radicale,couchdb,lidarr,private/technitium-dns-server,nixos}` | ✅ | ✅ | ✅ Restic `system-encrypted` | Όλες οι κρίσιμες stateful υπηρεσίες + UID/GID map |
| `/var/lib/secrets` | ✅ | ✅ | ✅ Restic `system-encrypted` | Κρυπτογραφημένο (απαιτεί offline αντίγραφο του `restic.pass`) |
| `/mnt/nas-data/Giannis/Apps/Immich/library/admin` | ✅ | ✅ | ✅ rclone `homelab-backups/media` | Πρωτότυπες φωτό/βίντεο (~115 GiB) |
| `/mnt/nas-data/Giannis/Library/Documents` | ✅ | ✅ | ✅ rclone `homelab-backups/documents` | Προσωπικά έγγραφα (~7.2 GiB) |
| `/mnt/nas-data/Giannis/Apps/Site` | ✅ | ✅ | ✅ rclone `homelab-backups/site` | Hugo πηγαίος κώδικας `kampisellis.com` |
| `/mnt/nas-data/Giannis/Library/Backups` | ✅ | ✅ | ✅ Restic `other-backups-encrypted` | Προσωπικά recovery archives & αρχειοθετημένο `migration/` (~345 MiB ZFS / ~483 MiB logical) |
| `/mnt/nas-data/Giannis/Apps/Immich/{thumbs,encoded-video,backups}` | ✅ | ✅ | ❌ Εκτός (σκόπιμα) | Αναδημιουργούνται από Immich (DB backup ήδη στο Restic) |
| `/mnt/nas-data/Giannis/Library/Notes` | ✅ | ✅ | ⚠️ Μέσω CouchDB στο Restic | Το ενεργό vault συγχρονίζεται μέσω CouchDB (`system-encrypted`) |
| `/mnt/nas-data/Giannis/Library/Audio` | ✅ | ✅ | ❌ Εκτός cloud | Μόνο τοπική ZFS προστασία (63 MiB) |
| `/mnt/nas-data/Games` (`bios`, `saves`, `states`) | ✅ | ✅ | ❌ Εκτός cloud | Μόνο τοπική ZFS προστασία (~2.7 GiB ZFS / ~4.1 GiB logical) |
| `/var/lib/{caddy,ntfy-sh,samba,netbird-wt0,kampisellis-site}` | ✅ | ✅ | ❌ Εκτός cloud | Αναγεννώνται ή επαναρρυθμίζονται εύκολα |
| `/mnt/roms` | N/A | N/A | ✅ Πηγή είναι το `gdrive:roms-encrypted` | Κρυπτογραφημένο cloud-native mount |

---

## 8. Παρακολούθηση, Ειδοποιήσεις & SRE Guardrails

### Κεντρικό Κανάλι Ειδοποιήσεων (`ntfy-sh` + Global `OnFailure`)
- **Push Server:** `ntfy-sh` σε `127.0.0.1:5055` (topic `homelab-alerts`, URL `https://ntfy.kampisellis.com`).
- **Αναβαθμισμένο Template `notify-ntfy@.service` (`modules/homelab/base.nix`):**
  - Εκτελεί το hardened script `notify-ntfy %i` (`DynamicUser=true`, `SupplementaryGroups = [ "systemd-journal" ]`, `ProtectSystem = "strict"`).
  - Στέλνει τίτλο `Homelab Service Failed: <unit>`, hostname, ISO-8601 timestamp και τις **τελευταίες 15 γραμμές** του `journalctl -u <unit>` με `Priority: high`.
- **Καθολικό Systemd Drop-In (`systemd.units` στο `base.nix`):**
  - `/etc/systemd/system/service.d/10-onfailure.conf` → `OnFailure=notify-ntfy@%n.service`. Καλύπτει **κάθε** systemd service, timer-triggered job και backup στο `homelab` χωρίς να απαιτείται χειροκίνητη δήλωση σε κάθε unit.
  - **Αποφυγή βρόχου αναδρομής (Recursion Prevention):** Επειδή η οδηγία `OnFailure=` του systemd είναι αθροιστική και δεν καθαρίζει με κενή τιμή, υπάρχουν ομώνυμα masking drop-in αρχεία (`notify-ntfy@.service.d/10-onfailure.conf` και `ntfy-sh.service.d/10-onfailure.conf`) που παρακάμπτουν πλήρως το `service.d/10-onfailure.conf` ώστε τα `notify-ntfy@` και `ntfy-sh` να έχουν κενό `OnFailure=[]`.

### Ειδοποιήσεις Υλικού, ZFS, Ρεύματος & Χωρητικότητας
- **`smartd.service`:** Καθημερινά short tests (`02:00`), εβδομαδιαία long tests (Σάββατο `03:00`), `-n standby,q` (δεν ξυπνά τον backup HDD), στέλνει σφάλματα στο `ntfy`.
- **`zfs-zed.service`:** Προωθεί συμβάντα ZFS (scrub, checksum/IO errors, degraded pool) στο `ntfy` μέσω `zed-notify-ntfy`.
- **`zfs-scrub.timer`:** Μηνιαίο scrub σε `tank` και `backup` (`Persistent=yes`).
- **`upsmon` (NUT):** Στέλνει `ONBATT`, `ONLINE`, `LOWBATT`, `FSD`, `SHUTDOWN`, `COMMBAD`, `REPLBATT` στο `ntfy`.
- **`disk-capacity-alert.service` (`08:00` καθημερινά):** Ελέγχει `/` (`df`), `/boot` (`df`), `tank` (`zpool`) και `backup` (`zpool`). Αν οποιοδήποτε φτάσει ή ξεπεράσει το **80%**, στέλνει high-priority alert στο `ntfy`.
- **`homelab-motd` (`modules/homelab/motd.nix`):** Σε κάθε διαδραστικό SSH login εμφανίζει kernel, uptime, load, failed units, υγεία ZFS pools και χρήση mounts.

### Υγιεινή Μνήμης, Logs & Nix Store (`modules/common.nix`, `modules/homelab/base.nix`)
- **Μνήμη / OOM:** `zramSwap` (`25%` / `7.8 GiB` zstd στο `homelab`, `50%` στο `laptop`) + ενεργό `systemd-oomd.service`.
- **Logs (`journald`):** `SystemMaxUse=500M`, `MaxRetentionSec=1month` (τρέχουσα χρήση `homelab`: `222.9M`).
- **Nix Store:** `nix.gc` (Κυριακή `05:00`, `--delete-older-than 14d`) + `nix.optimise` (Κυριακή `06:00`, hardlink deduplication).
- **SSD TRIM:** `services.fstrim.enable = true` + `zpool-trim.timer` (εβδομαδιαία Δευτέρα `~00:30`).

---

## 9. Μητρώο Secrets (Μόνο Διαδρομές — Ποτέ Περιεχόμενα)

Όλα τα runtime credentials αποθηκεύονται εκτός Git σε root-only φακέλους (`0700 root:root`).

| Διαδρομή Αρχείου | Host | Ιδιοκτήτης / Δικαιώματα | Καταναλωτής | Σκοπός | Απαιτείται Offline Backup; |
| :--- | :--- | :--- | :--- | :--- | :---: |
| `/var/lib/secrets/restic.pass` | `homelab` | `root:root` `0400` | `restic-backups-gdrive-system`, `restic-backups-gdrive-other-backups`, `restic-check-gdrive` | Master passphrase κρυπτογράφησης των 2 Restic repositories | **ΝΑΙ (ΚΡΙΣΙΜΟ)** — Χωρίς αυτό τα cloud backups είναι μη ανακτήσιμα |
| `/var/lib/secrets/rclone-backup.conf` | `homelab` | `root:root` `0600` | `rclone-gdrive-backup`, `restic-*` | OAuth config για το remote `gdrive:` | Συνιστάται (ή αναδημιουργία μέσω `rclone config`) |
| `/var/lib/secrets/rclone.conf` | `homelab` | `root:root` `0600` | `gdrive-roms.service` | OAuth + crypt config για `gdrive:` & `gdrive-roms-crypt:` | **ΝΑΙ (ΚΡΙΣΙΜΟ)** — Περιέχει τα crypt keys των ROMs |
| `/var/lib/secrets/caddy.env` | `homelab` | `root:root` `0400` | `caddy.service` | `CLOUDFLARE_API_TOKEN` για έκδοση wildcard TLS DNS-01 | Όχι (αναδημιουργείται από Cloudflare dashboard) |
| `/var/lib/secrets/searx.env` | `homelab` | `root:root` `0400` | `searx.service` | `SEARX_SECRET_KEY` (64-hex τυχαίο κλειδί) | Όχι (`openssl rand -hex 32`) |
| `/var/lib/secrets/upsmon.pass` | `homelab` | `root:nutmon` `0440` | `upsd`, `upsmon` | Κωδικός επικοινωνίας NUT monitor | Όχι (οποιοδήποτε τυχαίο string) |
| `/var/lib/radicale/users` | `homelab` | `radicale` | `radicale.service` | `htpasswd` bcrypt credentials για CalDAV/CardDAV | Καλύπτεται από Restic `system-encrypted` |
| `/var/lib/samba/private/passdb.tdb` | `homelab` | `root` | `samba-smbd.service` | Samba `tdbsam` κωδικός για `gkampisellis` | Όχι (επαναδημιουργείται με `sudo smbpasswd -a gkampisellis`) |
| `/var/lib/secrets/smb-homelab.cred` | `laptop` | `root:root` `0600` | Kernel CIFS automounts (`/mnt/nas-data`, `/mnt/nas-games`, `/mnt/roms`) | `username`/`password` για SMB 3.1.1 σύνδεση στο `10.10.10.5` | Όχι (ίδιος κωδικός με Samba user `gkampisellis`) |

---

## 10. Ενοποιημένο Χρονοδιάγραμμα Αυτοματισμών (Ώρα EET/EEST — `Europe/Athens`)

Επαληθευμένο από τα 19 ενεργά timers του `homelab` (`systemctl list-timers --all`), το `smartd`, το `laptop` και τα GitHub Actions:

```text
ΚΑΘΕ ΩΡΑ (Hourly)
├── :00  sanoid.timer                              → ZFS snapshots σε tank/var-lib & tank/data
└── :00  logrotate.timer                           → Περιστροφή logs

ΚΑΘΗΜΕΡΙΝΑ (Daily — homelab)
├── 02:00  smartd (short self-test)                → Γρήγορος SMART έλεγχος δίσκων (-n standby,q)
├── 02:15  postgresqlBackup-immich.timer           → pg_dump immich → /var/lib/backup/postgresql/
├── 03:00  sanoid (hourly/daily/monthly snapshot)  → Καταγράφει και το φρέσκο PG + Vaultwarden dump
├── 03:05  syncoid-state-backup.timer              → tank/var-lib → backup/var-lib (ξυπνά HDD)
├── 03:05  syncoid-data-backup.timer               → tank/data → backup/personal-backup
├── 03:20  backup-snapshot-prune.timer             → Καθαρισμός παλαιών snapshots στο pool backup
├── 03:45  restic-backups-gdrive-system.timer      → Encrypted backup DBs, app state & secrets → Drive
├── 03:50  restic-backups-gdrive-other-backups     → Encrypted backup Library/Backups → Drive
├── 04:00  rclone-gdrive-backup.timer              → rclone sync media, documents, site + purge _deleted (>30d)
├── 08:00  disk-capacity-alert.timer               → Έλεγχος /, /boot, tank, backup (alert ntfy αν ≥80%)
├── ~14:55 systemd-tmpfiles-clean.timer            → Καθαρισμός προσωρινών αρχείων
└── 23:00  backup-vaultwarden.timer                → Online SQLite backup + RSA keys → /var/lib/backup/vaultwarden

ΕΒΔΟΜΑΔΙΑΙΑ (Weekly)
├── Σάββατο  03:00       smartd (long self-test)   → Πλήρης SMART έλεγχος δίσκων (-n standby,q)
├── Κυριακή  04:30       restic-check-gdrive.timer → Restic check --read-data-subset=5% (και τα 2 repos)
├── Κυριακή  05:00       nix-gc.timer              → Διαγραφή Nix store garbage >14 ημερών (homelab & laptop)
├── Κυριακή  06:00       nix-optimise.timer        → Deduplication του /nix/store (homelab & laptop)
├── Δευτέρα  ~00:30      zpool-trim.timer          → TRIM στα NVMe SSDs του ZFS pool tank
├── Δευτέρα  ~00:35      fstrim.timer              → TRIM στο ext4 boot SSD
├── Δευτέρα  04:00 UTC   GitHub Actions            → `Update Stable Flake Input` (PR μόνο για stable nixpkgs)
├── Τρίτη    05:30 (+15m) nixos-upgrade.timer      → `homelab` autoUpgrade (switch, allowReboot=false)
└── Τρίτη    12:00 (+30m) nixos-upgrade.timer      → `laptop` autoUpgrade (boot only, AC power, allowReboot=false)

ΜΗΝΙΑΙΑ (Monthly)
└── 1η του μήνα ~02:00   zfs-scrub.timer           → Πλήρες ZFS scrub ακεραιότητας σε tank & backup
```

---

## 11. Ενημερώσεις & Ροή CI/CD

### GitHub Actions (`.github/workflows/`)
- **`ci.yml` (`CI`):** Τρέχει σε κάθε push στη `main` και σε κάθε PR με `actions/checkout@v7` (Node 24) & `cachix/install-nix-action@v31`. Εκτελεί `nix flake check --no-build --show-trace`, χτίζει `formatting`, `statix`, `deadnix`, `services-table` και το custom `caddy` package.
- **`update-flake-lock.yml` (`Update Stable Flake Input`):** Κάθε Δευτέρα `04:00 UTC` (και χειροκίνητα με `workflow_dispatch`) τρέχει `nix flake update nixpkgs` (εξαιρώντας σκόπιμα το `nixpkgs-unstable`), περνά όλα τα checks και ανοίγει PR στο branch `chore/update-nixpkgs` μέσω `peter-evans/create-pull-request@v8` (Node 24).
  - *Προϋπόθεση GitHub UI:* Στο `kampisellis/nixos-config` → **Settings → Actions → General → Workflow permissions** πρέπει να είναι ενεργό το **"Allow GitHub Actions to create and approve pull requests"**.

### Ασφαλής Διαδικασία Αλλαγής & Rollback
```bash
# 1. Τοπική επεξεργασία & έλεγχοι (στο /etc/nixos)
cd /etc/nixos
just fmt && just check && just lint && just services-table

# 2. Προεπισκόπηση αλλαγών πακέτων & ασφαλής δοκιμή
just diff homelab
just test homelab     # Προσωρινή ενεργοποίηση (αναιρείται με reboot)

# 3. Commit, push & μόνιμη ενεργοποίηση
git add -A && git commit -m "feat(homelab): ..." && git push origin main
ssh homelab 'cd /etc/nixos && git pull --ff-only && sudo nixos-rebuild switch --flake /etc/nixos#homelab'
# Αντίστοιχα στο laptop:
just switch laptop

# Rollback χωρίς reboot (άμεσο):
sudo nixos-rebuild switch --rollback
```
- **Ενημέρωση Caddy plugin hash:** Όταν μια αναβάθμιση `nixpkgs` αλλάξει το Go vendor hash του `caddy-dns/cloudflare`, βάλε προσωρινά `hash = lib.fakeHash;` στο `modules/homelab/caddy.nix`, τρέξε `just build homelab`, αντέγραψε το `got: sha256-...` πίσω στο αρχείο και επανάλαβε `just lint`.

---

## 12. Playbooks Ανάκαμψης Καταστροφών (Disaster Recovery)

### Playbook 1: Τυχαία Διαγραφή Αρχείου στο NAS
**Δέντρο απόφασης (από το ταχύτερο στο πιο απομακρυσμένο):**
1. **ZFS Snapshot στο `tank` (ακαριαία, έως 48 ώρες / 30 ημέρες / 6 μήνες πίσω):**
   ```bash
   ls /mnt/nas-data/.zfs/snapshot/
   cp -a "/mnt/nas-data/.zfs/snapshot/<SNAP>/Giannis/Library/Documents/<FILE>" \
         "/mnt/nas-data/Giannis/Library/Documents/"
   ```
2. **Local Backup Pool (`backup/personal-backup`):**
   ```bash
   ls /backup/personal-backup/.zfs/snapshot/
   cp -a "/backup/personal-backup/.zfs/snapshot/<SNAP>/Giannis/..." /mnt/nas-data/...
   ```
3. **Google Drive `_deleted/` Trash (έως 30 ημέρες για `media`, `documents`, `site`):**
   ```bash
   sudo rclone --config=/var/lib/secrets/rclone-backup.conf ls "gdrive:homelab-backups/_deleted"
   sudo rclone --config=/var/lib/secrets/rclone-backup.conf copy \
     "gdrive:homelab-backups/_deleted/<YYYY-MM-DD>/documents/<FILE>" \
     "/mnt/nas-data/Giannis/Library/Documents/"
   ```
4. **Restic Cloud Snapshot** (για DBs, app state, `Library/Backups`): βλ. Playbook 3.

---

### Playbook 2: Κακό NixOS Upgrade ή Σπασμένο Config
1. **Αν υπάρχει SSH πρόσβαση:**
   ```bash
   sudo nixos-rebuild switch --rollback
   systemctl --failed
   ```
2. **Αν το σύστημα δεν bootάρει / δεν απαντά:**
   - Με φυσική πρόσβαση (οθόνη/πληκτρολόγιο), διάλεξε την προηγούμενη γενιά στο μενού του `systemd-boot` (κρατούνται 5 γενιές στο `homelab`, 10 στο `laptop`).
   - Αν ο `homelab` είναι κλειστός (π.χ. μετά από διακοπή ρεύματος), ξύπνησέ τον με Wake-on-LAN από τον MikroTik:
     ```routeros
     /tool wol interface=bridge mac=D8:5E:D3:9C:11:15
     ```

---

### Playbook 3: Ανάκτηση Μεμονωμένου Αρχείου ή Πλήρους Snapshot από Restic
```bash
# 1. Προβολή διαθέσιμων snapshots (system ή other-backups)
sudo restic-gdrive-system snapshots
sudo restic-gdrive-other-backups snapshots

# 2. Εύρεση διαδρομής αρχείου μέσα σε snapshot
sudo restic-gdrive-system ls latest | grep -i vaultwarden
sudo restic-gdrive-other-backups ls latest

# 3. Ανάκτηση μεμονωμένου αρχείου/φακέλου σε προσωρινό φάκελο (/tmp/restore)
sudo mkdir -p /tmp/restore
sudo restic-gdrive-system restore latest --target /tmp/restore --include /var/lib/backup/vaultwarden
sudo restic-gdrive-other-backups restore latest --target /tmp/restore --include /mnt/nas-data/Giannis/Library/Backups

# 4. Έλεγχος & μεταφορά στον τελικό προορισμό (διατηρώντας σωστό owner!), μετά καθαρισμός /tmp/restore
sudo rm -rf /tmp/restore
```
*(Για μη-καταστροφικό restore drill της PostgreSQL βάσης του Immich και integrity check του Vaultwarden SQLite, δες τις έτοιμες εντολές στο [docs/RUNBOOK.md](./RUNBOOK.md#6-backup-verification--restore-drills).)*

---

### Playbook 4: Βλάβη Ενός Δίσκου στο `tank` Mirror ή στον Δίσκο `backup`

#### Περίπτωση Α — Αστοχία ενός NVMe στο `tank` (`DEGRADED` mirror)
1. Εντόπισε τον χαλασμένο δίσκο από το `zpool status tank` (π.χ. `nvme-WD_Blue_SN570_...`).
2. Σβήσε καθαρά τον server (`sudo systemctl poweroff`), αντικατέστησε το χαλασμένο NVMe με δίσκο ίσης ή μεγαλύτερης χωρητικότητας και εκκίνησε.
3. Βρες το `/dev/disk/by-id/` του νέου NVMe (`ls -l /dev/disk/by-id/`) — **έλεγξε 2 φορές** να μην αγγίξεις τον υγιή δίσκο!
4. Δημιούργησε GPT partition 1 (όπως στο υγιές μέλος) και τρέξε `zpool replace`:
   ```bash
   NEW="/dev/disk/by-id/<NEW_NVME_ID>"
   sudo parted "$NEW" -- mklabel gpt mkpart primary 1MiB 100%
   sudo zpool replace tank <OLD_FAULTED_DEVICE_ID> "${NEW}-part1"
   watch -n 5 zpool status tank   # Περίμενε να ολοκληρωθεί το resilver με 0 errors
   ```

#### Περίπτωση Β — Αστοχία του 1TB SATA HDD (`backup` pool)
Επειδή το `backup` είναι δευτερεύον replica pool (όλα τα ζωντανά δεδομένα βρίσκονται στο `tank` mirror), αντικαθιστάς τον SATA δίσκο, ενημερώνεις το `ata-...` ID στο `hdd-spindown` (`modules/homelab/storage.nix`), δημιουργείς νέο pool `backup` (`compression=lz4`, `atime=off`) και τρέχεις `sudo systemctl start syncoid-state-backup.service syncoid-data-backup.service`.

---

### Playbook 5: Πλήρης Bare-Metal Ανακατασκευή του `homelab` από το Μηδέν
*(Σενάριο ολικής απώλειας boot SSD + ZFS pools — ανάκτηση από GitHub Flake + offline secrets + Google Drive)*

1. **Boot από NixOS 26.05 Live ISO** (σε UEFI mode).
2. **Κατάτμηση OS Boot SSD** (`NIXBOOT` 512 MiB FAT32 + `NIXROOT` ext4) — αναλυτικές εντολές στο [docs/RUNBOOK.md](./RUNBOOK.md#2-bare-metal-boot-ssd-recovery-homelab).
3. **Δημιουργία ZFS Pools** (αν χάθηκαν και οι δίσκοι δεδομένων, αλλιώς απλό `zpool import -f -R /mnt tank` & `backup`):
   ```bash
   sudo zpool create -o ashift=12 -O compression=lz4 -O atime=off -O xattr=sa -O mountpoint=none -R /mnt \
     tank mirror /dev/disk/by-id/<NVME1>-part1 /dev/disk/by-id/<NVME2>-part1
   sudo zfs create -o mountpoint=legacy tank/var-lib
   sudo zfs create -o mountpoint=legacy tank/data
   sudo zpool create -o ashift=12 -O compression=lz4 -O atime=off -R /mnt backup /dev/disk/by-id/<HDD>-part1
   ```
4. **Προσάρτηση & Clone του Flake:**
   ```bash
   sudo mount /dev/disk/by-label/NIXROOT /mnt
   sudo mkdir -p /mnt/boot /mnt/var/lib /mnt/mnt/nas-data
   sudo mount -o fmask=0077,dmask=0077 /dev/disk/by-label/NIXBOOT /mnt/boot
   sudo mount -t zfs tank/var-lib /mnt/var/lib
   sudo mount -t zfs tank/data /mnt/mnt/nas-data
   sudo git clone https://github.com/kampisellis/nixos-config.git /mnt/etc/nixos
   sudo nixos-generate-config --no-filesystems --root /mnt --show-hardware-config \
     | sudo tee /mnt/etc/nixos/hosts/homelab/hardware-configuration.nix >/dev/null
   ```
5. **Επαναφορά Offline Secrets** στο `/mnt/var/lib/secrets` (`restic.pass`, `rclone-backup.conf`, `rclone.conf`, `caddy.env`, `searx.env`, `upsmon.pass` με τα ακριβή permissions της Ενότητας 9).
6. **Επαναφορά `/var/lib` από Restic (`system-encrypted`) ΠΡΙΝ το πρώτο boot** (ώστε να επανέλθει το `/var/lib/nixos` με τα ακριβή UIDs/GIDs, οι βάσεις και τα app configs):
   ```bash
   nix-shell -p restic rclone --run '
     export RESTIC_PASSWORD_FILE=/mnt/var/lib/secrets/restic.pass
     export RCLONE_CONFIG=/mnt/var/lib/secrets/rclone-backup.conf
     sudo -E restic -r rclone:gdrive:homelab-backups/system-encrypted restore latest --target /mnt
   '
   ```
7. **Εγκατάσταση NixOS & Πρώτο Boot:**
   ```bash
   sudo nixos-install --root /mnt --flake /mnt/etc/nixos#homelab --no-root-passwd
   # Reboot (μετά το boot όρισε passwd & smbpasswd για gkampisellis)
   ```
8. **Επαναφορά NAS Δεδομένων, Vaultwarden & Immich DB από Google Drive** (μετά το boot, με σταματημένες τις υπηρεσίες κατά την επαναφορά των βάσεων):
   ```bash
   sudo systemctl stop immich-server.service immich-machine-learning.service vaultwarden.service

   # 1. Restore Vaultwarden από /var/lib/backup/vaultwarden (το Restic κρατά το online SQLite dump + RSA key, όχι το live /var/lib/vaultwarden)
   sudo rm -f /var/lib/vaultwarden/db.sqlite3-wal /var/lib/vaultwarden/db.sqlite3-shm
   sudo cp -a /var/lib/backup/vaultwarden/db.sqlite3 /var/lib/backup/vaultwarden/rsa_key.pem /var/lib/vaultwarden/
   sudo cp -a /var/lib/backup/vaultwarden/icon_cache /var/lib/vaultwarden/ 2>/dev/null || true
   sudo chown -R vaultwarden:vaultwarden /var/lib/vaultwarden
   sudo chmod 600 /var/lib/vaultwarden/rsa_key.pem
   sudo systemctl start vaultwarden.service

   # 2. Restore Immich media, Documents & Site
   sudo rclone --config=/var/lib/secrets/rclone-backup.conf copy gdrive:homelab-backups/media /mnt/nas-data/Giannis/Apps/Immich/library/admin
   sudo rclone --config=/var/lib/secrets/rclone-backup.conf copy gdrive:homelab-backups/documents /mnt/nas-data/Giannis/Library/Documents
   sudo rclone --config=/var/lib/secrets/rclone-backup.conf copy gdrive:homelab-backups/site /mnt/nas-data/Giannis/Apps/Site

   # 3. Restore Library/Backups από Restic
   sudo restic-gdrive-other-backups restore latest --target /

   # 4. Διόρθωση ιδιοκτησιών (Immich = immich:immich, υπόλοιπα = gkampisellis:users)
   sudo chown -R immich:immich /mnt/nas-data/Giannis/Apps/Immich
   sudo chown -R gkampisellis:users /mnt/nas-data/Giannis/Library /mnt/nas-data/Giannis/Apps/Site

   # 5. Import Immich PostgreSQL dump από /var/lib/backup/postgresql/immich.sql.gz & εκκίνηση Immich
   sudo systemctl start immich-server.service immich-machine-learning.service
   ```

---

## 13. Απαράβατοι Κανόνες & Λειτουργικές Προειδοποιήσεις

1. **Offline αντίγραφο του `restic.pass` & `rclone.conf`:** Διατήρησε πάντα ένα ασφαλές offline αντίγραφο εκτός `homelab` (π.χ. σε password manager / encrypted USB). Χωρίς το `restic.pass`, τα `system-encrypted` και `other-backups-encrypted` δεν αποκρυπτογραφούνται.
2. **Ποτέ `bootctl` ή EFI NVRAM writes στο `homelab`:** Η Gigabyte B660M DS3H DDR4 κλειδώνει το BIOS (`"Boot failure detected"`). Κράτα πάντα `boot.loader.efi.canTouchEfiVariables = false`.
3. **Ποτέ `chown -R` στο `/mnt/nas-data` ή στο `Apps/Immich`:** Το `Apps/Immich` πρέπει να παραμένει `immich:immich` (`999:999`). Τα `chown` περιορίζονται αποκλειστικά σε `Library/`, `Apps/Site`, `Games/`.
4. **Κράτα τα ZFS pools κάτω από 80% χωρητικότητα:** Πάνω από 80% η απόδοση του ZFS (copy-on-write fragmentation) πέφτει απότομα. Το `disk-capacity-alert.timer` σε ειδοποιεί αυτόματα στο `80%`.
5. **Μη μεταβάλλεις το `system.stateVersion`:** Παραμένει κλειδωμένο σε `"25.11"` στο `homelab` και `"26.05"` στο `laptop` για αποφυγή σπασμένων schemas σε DBs/services.
6. **Προσοχή στο `nixpkgs-unstable`:** Μην τρέχεις τυφλά `just update-unstable` χωρίς `just diff homelab` και φρέσκο ZFS snapshot (`sudo zfs snapshot -r tank@pre-unstable`) — επηρεάζει Immich (PostgreSQL migrations) και NetBird.
7. **Snapshots ≠ Backups:** Κάνε τουλάχιστον ένα ετήσιο restore drill (PostgreSQL Immich, Vaultwarden SQLite, Restic restore) για επιβεβαίωση ότι τα backups ανακτώνται πραγματικά.
8. **Μη δημιουργείς χειροκίνητα snapshots με ίδιο όνομα στο `backup`:** Τα χειροκίνητα snapshots γίνονται μόνο στο `tank` ώστε να μην συγκρούονται με το `syncoid`.
9. **Αντιμετώπισε τον δίσκο `backup` (`/dev/sda`, `ST1000LM035-1RK172`) ως προσωρινό & προτεραιότητα αντικατάστασης:** Παρότι είναι `ONLINE` με `0` νέα ZFS errors, έχει ιστορικό `Reported_Uncorrect = 93`, `ATA Error Count = 65` και παλαιά ZFS permanent errors από το Proxmox — αντικατέστησέ τον πρώτον μόλις είναι πρακτικό (Playbook 4, Περίπτωση Β).

---

## 14. Quick-Reference Cheat Sheet (Εντολές Ημέρας-2)

```bash
# ── Υγεία Συστήματος & Υπηρεσιών (homelab) ──
homelab-motd                                        # Πλήρης σύνοψη (uptime, failed, ZFS, df)
systemctl --failed                                  # Πρέπει να είναι 0 loaded units
systemctl list-timers --all                         # Όλα τα 19 προγραμματισμένα timers
journalctl -u <unit> -n 50 --no-pager               # Τελευταία logs υπηρεσίας

# ── ZFS & Δίσκοι ──
zpool status && zpool list                          # Κατάσταση pools, errors, % χρήσης
zfs list -t snapshot | tail -n 20                   # Πρόσφατα snapshots
sudo smartctl -H /dev/sda /dev/sdb /dev/nvme0 /dev/nvme1
upsc myups@localhost | grep -E 'ups\.status|ups\.load|battery\.'

# ── Backups (Restic & rclone) ──
sudo restic-gdrive-system snapshots                 # Snapshots συστήματος/DBs
sudo restic-gdrive-other-backups snapshots          # Snapshots Library/Backups
sudo systemctl start restic-check-gdrive.service    # Χειροκίνητος έλεγχος 5% ακεραιότητας
sudo systemctl start disk-capacity-alert.service    # Χειροκίνητος έλεγχος χωρητικότητας (≥80%)
sudo rclone --config=/var/lib/secrets/rclone-backup.conf size --fast-list gdrive:homelab-backups

# ── Samba & Δίκτυο ──
testparm -s                                         # Ενεργό Samba config
sudo iptables -S nixos-fw                           # Ενεργοί κανόνες firewall (μόνο TCP 445 για SMB3)
sudo ss -tulpn                                      # Όλες οι θύρες σε LISTEN

# ── Δοκιμή Ειδοποιήσεων ntfy ──
curl -H "Title: Manual Test" -d "Hello from homelab" http://127.0.0.1:5055/homelab-alerts
sudo systemctl start notify-ntfy@manual-test.service

# ── Deployment από laptop ──
cd /etc/nixos && just fmt && just check && just lint && just diff homelab
ssh homelab 'cd /etc/nixos && git pull --ff-only && sudo nixos-rebuild switch --flake /etc/nixos#homelab'
```

---

## 15. Τρέχουσα Κατάσταση Επαλήθευσης (Commit `d99488f`)

| Υποσύστημα | Κατάσταση | Σημειώσεις Επαλήθευσης |
| :--- | :---: | :--- |
| Nix Flake (`just check`, `lint`, `services-table`) | ✅ Verified | Περνά χωρίς errors/warnings σε `homelab` & `laptop`. |
| GitHub Actions `CI` (Node 24) | ✅ Verified | Run `45209204921` στο `d99488f`: `success`, `0` annotations. |
| GitHub Actions `Update Stable Flake Input` | ⚠️ Manual UI Toggle | Τα actions αναβαθμίστηκαν σε Node 24 (`checkout@v7`, `create-pull-request@v8`). Ενεργοποίησε στο GitHub UI το *"Allow GitHub Actions to create and approve pull requests"* αν δεν έχει ήδη γίνει. |
| ZFS Pools (`tank`, `backup`) & SMART (4 drives) | ✅ Verified | `ONLINE`, `0` errors, `26%` capacity, `smartd` & `zfs-zed` → `ntfy`. |
| UPS / NUT (`myups` PowerWalker) | ✅ Verified | `OL`, `100%` charge, `18%` load, graceful shutdown στο `20%`. |
| Samba SMB 3.1.1 & Firewall (TCP `445` only) | ✅ Verified | `0` NetBIOS rules (`137/138/139`), ownership fixed (`gkampisellis:users`, `Immich` άθικτο `999:999`). |
| `laptop` SMB 3.1.1 Automounts (χωρίς idle-timeout) | ⚠️ Pending Switch | Έτοιμο στο `hosts/laptop/default.nix` — τρέξε `just switch laptop` αν δεν το έχεις ήδη εφαρμόσει μετά το commit `ae679d0`. |
| Cloud Backups (`system-encrypted`, `other-backups-encrypted`, `rclone`) | ✅ Verified | Όλα ενεργά, live run & `restic-check-gdrive` (`--read-data-subset=5%`) πέρασαν με `no errors were found`. |
| Global Failure Alerting (`service.d/10-onfailure.conf` → `ntfy`) | ✅ Verified | Επαληθευμένο live με journal output & masking drop-ins σε `ntfy-sh` / `notify-ntfy@` (`0` failed units). |
| `disk-capacity-alert` (≥80%) & `gdrive-roms` VFS (80G / 256M) | ✅ Verified | Ενεργά timers, `0` false alerts, `gdrive-roms` ενεργό με 80G cache & 256M read-ahead. |
