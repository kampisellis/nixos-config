{
  config,
  lib,
  pkgs,
  utils,
  ...
}:

let
  cfg = config.homelab;
  backupHddDevice = "/dev/disk/by-id/ata-ST1000LM035-1RK172_WL1LLNEG";
  backupHddDeviceUnit = "${utils.escapeSystemdPath backupHddDevice}.device";

  zedNtfyScript = pkgs.writeShellScript "zed-notify-ntfy" ''
    set -euo pipefail
    subject="''${*:-ZFS Event on ${config.networking.hostName}}"
    exec ${lib.getExe cfg.notifyScript} "$subject" "high" "floppy_disk,warning"
  '';

  smartdNtfyScript = pkgs.writeShellScript "smartd-notify-ntfy" ''
    set -euo pipefail
    subject="''${SMARTD_SUBJECT:-SMART Alert on ${config.networking.hostName}}"
    message="''${SMARTD_FULLMESSAGE:-SMART event detected on ''${SMARTD_DEVICE:-unknown device}}"
    printf '%s\n' "$message" | ${lib.getExe cfg.notifyScript} "$subject" "high" "warning"
  '';

  diskCapacityAlertScript = pkgs.writeShellScript "disk-capacity-alert" ''
    set -euo pipefail
    threshold=80
    alerts=""

    for mount in / /boot; do
      pct="$(${pkgs.coreutils}/bin/df --output=pcent "$mount" | ${pkgs.coreutils}/bin/tail -n 1 | ${pkgs.coreutils}/bin/tr -dc '0-9')"
      if [ -n "$pct" ] && [ "$pct" -ge "$threshold" ]; then
        alerts="$(printf '%s- Filesystem %s: %s%% used (threshold %s%%)\n' "$alerts" "$mount" "$pct" "$threshold")"
      fi
    done

    for pool in tank backup; do
      pct="$(${pkgs.zfs}/bin/zpool list -H -o capacity "$pool" | ${pkgs.coreutils}/bin/tr -dc '0-9')"
      if [ -n "$pct" ] && [ "$pct" -ge "$threshold" ]; then
        alerts="$(printf '%s- ZFS pool %s: %s%% used (threshold %s%%)\n' "$alerts" "$pool" "$pct" "$threshold")"
      fi
    done

    if [ -n "$alerts" ]; then
      printf 'Storage capacity threshold (>=%s%%) exceeded on ${config.networking.hostName}:\n%s' "$threshold" "$alerts" \
        | ${lib.getExe cfg.notifyScript} "Disk Capacity Alert on ${config.networking.hostName}" "high" "floppy_disk,warning"
    fi
  '';
in
{
  config = lib.mkIf cfg.enable {
    boot = {
      supportedFilesystems = [ "zfs" ];
      # Both tank and backup pools are verified owned by hostId 8425e349 (2217075529);
      # forceImportRoot is cleanly disabled so ZFS protects against accidental foreign imports.
      zfs = {
        forceImportRoot = false;
        requestEncryptionCredentials = false;
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
            ZED_EMAIL_OPTS = "'@SUBJECT@'";
            ZED_NOTIFY_INTERVAL_SECS = 3600;
            ZED_NOTIFY_VERBOSE = false;
          };
        };
      };

      # Disk health monitoring via SMART; -n standby,50,q avoids waking the spun-down backup HDD
      # during normal daily cycles (syncoid wakes it every 24h) while guaranteeing a fallback check
      # after 50 skipped 30-min polls (~25.5h) so the drive never goes unchecked indefinitely.
      smartd = {
        enable = true;
        autodetect = true;
        notifications = {
          mail.enable = false;
          wall.enable = false;
          x11.enable = false;
        };
        defaults.monitored = "-a -o on -S on -n standby,50,q -s (S/../../[1-57]/03|L/../../6/03) -m <nomailer> -M exec ${smartdNtfyScript}";
      };
    };

    # Declarative directories and permissions for out-of-repo secrets and rclone cache
    systemd.tmpfiles.rules = [
      "d ${cfg.secretsDir} 0700 root root -"
      "d /mnt/roms 0755 root root -"
      "d /var/cache/rclone 0700 root root -"
    ];

    # Spin down 1TB SATA backup HDD after 15 minutes of inactivity (triggered once when the device appears)
    systemd.services = {
      hdd-spindown = {
        description = "Set spin-down timeout on backup SATA HDD (ST1000LM035)";
        wantedBy = [ backupHddDeviceUnit ];
        after = [ backupHddDeviceUnit ];
        unitConfig.ConditionPathExists = backupHddDevice;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectHome = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          ExecStart = "${pkgs.hdparm}/bin/hdparm -B 127 -S 180 ${backupHddDevice}";
        };
      };

      disk-capacity-alert = {
        description = "Check filesystem and ZFS pool capacity and alert ntfy if >= 80%";
        startAt = "*-*-* 08:00:00";
        serviceConfig = {
          Type = "oneshot";
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectHome = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          ExecStart = "${diskCapacityAlertScript}";
        };
      };
    };

    systemd.timers.disk-capacity-alert.timerConfig.Persistent = true;

    # Filesystems (labels and ZFS dataset mountpoints preserved unchanged)
    fileSystems."/" = {
      device = "/dev/disk/by-label/NIXROOT";
      fsType = "ext4";
      options = [ "noatime" ];
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
      unitConfig.ConditionFileNotEmpty = "${cfg.secretsDir}/rclone.conf";
      # Include /run/wrappers so rclone can invoke the setuid fusermount3 binary
      path = [ "/run/wrappers" ];
      serviceConfig = {
        Type = "notify";
        ExecStartPre = "-/run/wrappers/bin/fusermount3 -uz /mnt/roms";
        ExecStart = ''
          ${pkgs.rclone}/bin/rclone mount gdrive-roms-crypt: /mnt/roms \
            --config=${cfg.secretsDir}/rclone.conf \
            --allow-other \
            --read-only \
            --vfs-cache-mode full \
            --vfs-cache-max-size 80G \
            --vfs-cache-max-age 336h \
            --vfs-read-ahead 256M \
            --buffer-size 64M \
            --cache-dir /var/cache/rclone
        '';
        ExecStop = "-/run/wrappers/bin/fusermount3 -uz /mnt/roms";
        Restart = "on-failure";
        RestartSec = "15s";
      };
    };
  };
}
