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
      body="$(printf 'Storage capacity threshold (>=%s%%) exceeded on ${config.networking.hostName}:\n%s' "$threshold" "$alerts")"
      ${pkgs.curl}/bin/curl \
        --silent \
        --show-error \
        --fail \
        --max-time 10 \
        --retry 3 \
        --retry-delay 2 \
        -H "Title: Disk Capacity Alert on ${config.networking.hostName}" \
        -H "Priority: high" \
        -H "Tags: floppy_disk,warning" \
        --data-binary "$body" \
        "http://127.0.0.1:${toString cfg.ports.ntfy}/homelab-alerts"
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
    systemd.services = {
      smartd.onFailure = [ "notify-ntfy@%n.service" ];
      zfs-scrub.onFailure = [ "notify-ntfy@%n.service" ];

      hdd-spindown = {
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
            --vfs-cache-max-size 80G \
            --vfs-cache-max-age 336h \
            --vfs-read-ahead 256M \
            --buffer-size 64M \
            --cache-dir /var/cache/rclone
        '';
        ExecStop = "/run/wrappers/bin/fusermount3 -u /mnt/roms";
        Restart = "on-failure";
        RestartSec = "15s";
      };
    };
  };
}
