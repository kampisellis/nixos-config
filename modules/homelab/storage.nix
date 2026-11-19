{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.homelab;

  zedNtfyScript = pkgs.writeShellScript "zed-notify-ntfy" ''
    subject="''${1:-ZFS Event on ${config.networking.hostName}}"
    body="$(${pkgs.coreutils}/bin/cat)"
    ${pkgs.curl}/bin/curl \
      --silent \
      --show-error \
      --max-time 10 \
      -H "Title: $subject" \
      -H "Priority: high" \
      -H "Tags: floppy_disk,warning" \
      --data-binary "$body" \
      "http://127.0.0.1:${toString cfg.ports.ntfy}/homelab-alerts" || true
  '';

  smartdNtfyScript = pkgs.writeShellScript "smartd-notify-ntfy" ''
    subject="''${SMARTD_SUBJECT:-SMART Alert on ${config.networking.hostName}}"
    message="''${SMARTD_FULLMESSAGE:-SMART event detected on ''${SMARTD_DEVICE:-unknown device}}"
    ${pkgs.curl}/bin/curl \
      --silent \
      --show-error \
      --max-time 10 \
      -H "Title: $subject" \
      -H "Priority: high" \
      -H "Tags: warning" \
      --data-binary "$message" \
      "http://127.0.0.1:${toString cfg.ports.ntfy}/homelab-alerts" || true
  '';
in
{
  config = lib.mkIf cfg.enable {
    boot = {
      supportedFilesystems = [ "zfs" ];
      # Kept explicitly true until a clean physical-access reboot verifies hostid import;
      # forceImportAll has been removed as pools are cleanly owned by this host.
      zfs = {
        forceImportRoot = true;
        extraPools = [ "backup" ];
      };
      kernelParams = [ "zfs.zfs_arc_max=12884901888" ];
    };

    services = {
      fstrim.enable = true;

      zfs = {
        autoScrub.enable = true;

        # Route ZFS Event Daemon alerts to local ntfy without requiring an MTA
        zed = {
          enableMail = false;
          settings = {
            ZED_EMAIL_ADDR = [ "ntfy" ];
            ZED_EMAIL_PROG = "${zedNtfyScript}";
            ZED_EMAIL_OPTS = "@SUBJECT@";
            ZED_NOTIFY_INTERVAL_SECS = 3600;
            ZED_NOTIFY_VERBOSE = false;
          };
        };
      };

      # Disk health monitoring via SMART; -n standby,q avoids waking the spun-down backup HDD
      smartd = {
        enable = true;
        autodetect = true;
        notifications = {
          mail.enable = false;
          wall.enable = false;
          x11.enable = false;
        };
        defaults.monitored = "-a -o on -S on -n standby,q -s (S/../.././02|L/../../6/03) -m <nomailer> -M exec ${smartdNtfyScript}";
      };
    };

    # Declarative directories and permissions for out-of-repo secrets and rclone cache
    systemd.tmpfiles.rules = [
      "d ${cfg.secretsDir} 0700 root root -"
      "d /mnt/roms 0755 root root -"
      "d /var/cache/rclone 0700 root root -"
    ];

    # Spin down 1TB SATA backup HDD after 15 minutes of inactivity
    systemd.services.hdd-spindown = {
      description = "Set spin-down timeout on backup SATA HDD (ST1000LM035)";
      wantedBy = [ "multi-user.target" ];
      onFailure = [ "notify-ntfy@%n.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        ExecStart = "${pkgs.hdparm}/bin/hdparm -B 127 -S 180 /dev/disk/by-id/ata-ST1000LM035-1RK172_WL1LLNEG";
      };
    };

    # Filesystems (labels and ZFS dataset mountpoints preserved unchanged)
    fileSystems."/" = {
      device = "/dev/disk/by-label/NIXROOT";
      fsType = "ext4";
    };

    fileSystems."/boot" = {
      device = "/dev/disk/by-label/NIXBOOT";
      fsType = "vfat";
      options = [
        "fmask=0077"
        "dmask=0077"
      ];
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

    # Encrypted Google Drive ROMs mount via rclone (skipped cleanly when rclone.conf is empty)
    programs.fuse.userAllowOther = true;

    systemd.services.gdrive-roms = {
      description = "Mount Encrypted Google Drive ROMs via rclone";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      onFailure = [ "notify-ntfy@%n.service" ];
      unitConfig.ConditionFileNotEmpty = "${cfg.secretsDir}/rclone.conf";
      # Include /run/wrappers so rclone can invoke the setuid fusermount3 binary
      path = [ "/run/wrappers" ];
      serviceConfig = {
        Type = "notify";
        ExecStart = ''
          ${pkgs.rclone}/bin/rclone mount gdrive-roms-crypt: /mnt/roms \
            --config=${cfg.secretsDir}/rclone.conf \
            --allow-other \
            --read-only \
            --vfs-cache-mode full \
            --vfs-cache-max-size 40G \
            --vfs-cache-max-age 336h \
            --cache-dir /var/cache/rclone
        '';
        ExecStop = "/run/wrappers/bin/fusermount3 -u /mnt/roms";
        Restart = "on-failure";
        RestartSec = "15s";
      };
    };
  };
}
