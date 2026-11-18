{ config, pkgs, ... }:

{
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.forceImportRoot = true;
  boot.zfs.forceImportAll = true;
  boot.zfs.extraPools = [ "backup" ];

  boot.kernelParams = [ "zfs.zfs_arc_max=12884901888" ];
  services.zfs.autoScrub.enable = true;
  services.fstrim.enable = true;

  # Spin-down στον 1TB SATA HDD (backup pool) μετά από 15 λεπτά αδράνειας
  systemd.services.hdd-spindown = {
    description = "Set spin-down timeout on backup SATA HDD (ST1000LM035)";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.hdparm}/bin/hdparm -B 127 -S 180 /dev/disk/by-id/ata-ST1000LM035-1RK172_WL1LLNEG";
      RemainAfterExit = true;
    };
  };

  fileSystems."/" = {
    device = "/dev/disk/by-label/NIXROOT";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/NIXBOOT";
    fsType = "vfat";
    options = [ "fmask=0022" "dmask=0022" ];
  };

  fileSystems."/var/lib" = {
    device = "tank/var-lib";
    fsType = "zfs";
    neededForBoot = true;
  };

  fileSystems."/mnt/nas-data" = {
    device = "tank/data";
    fsType = "zfs";
  };

  services.postgresqlBackup = {
    enable = true;
    location = "/var/lib/backup/postgresql";
    databases = [ "immich" ];
    startAt = "*-*-* 02:15:00";
  };

  services.sanoid = {
    enable = true;
    datasets = {
      "tank/var-lib" = { hourly = 24; daily = 30; monthly = 3; autosnap = true; autoprune = true; };
      "tank/data"    = { daily = 30; monthly = 6; autosnap = true; autoprune = true; };
    };
  };

  services.syncoid = {
    enable = true;
    commands = {
      "state-backup" = { source = "tank/var-lib"; target = "backup/var-lib"; };
      "data-backup"  = { source = "tank/data";    target = "backup/personal-backup"; };
    };
  };
  systemd.services.syncoid-state-backup.onFailure = [ "notify-ntfy@%n.service" ];
  systemd.services.syncoid-data-backup.onFailure  = [ "notify-ntfy@%n.service" ];

  programs.fuse.userAllowOther = true;
  systemd.services.gdrive-roms = {
    description = "Mount Encrypted Google Drive ROMs via rclone";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "notify";
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p /mnt/roms /var/cache/rclone";
      ExecStart = ''
        ${pkgs.rclone}/bin/rclone mount gdrive-roms-crypt: /mnt/roms \
          --config=/var/lib/secrets/rclone.conf \
          --allow-other \
          --read-only \
          --vfs-cache-mode full \
          --vfs-cache-max-size 40G \
          --vfs-cache-max-age 336h \
          --cache-dir /var/cache/rclone
      '';
      ExecStop = "/run/wrappers/bin/fusermount -u /mnt/roms";
      Restart = "on-failure";
    };
  };

  services.samba = {
    enable = true;
    openFirewall = true;
    settings = {
      global = {
        security = "user";
        "server min protocol" = "SMB3";
      };
      roms = {
        path = "/mnt/roms";
        browseable = "yes";
        "read only" = "yes";
        "valid users" = "gkampisellis";
      };
      data = {
        path = "/mnt/nas-data";
        browseable = "yes";
        "read only" = "no";
        "valid users" = "gkampisellis";
      };
    };
  };
}
