{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.homelab;
in
{
  config = lib.mkIf cfg.enable {
    services = {
      postgresqlBackup = {
        enable = true;
        location = "/var/lib/backup/postgresql";
        databases = [ "immich" ];
        startAt = "*-*-* 02:15:00";
      };

      sanoid = {
        enable = true;
        datasets = {
          "tank/var-lib" = {
            hourly = 24;
            daily = 30;
            monthly = 3;
            autosnap = true;
            autoprune = true;
          };
          "tank/data" = {
            # Explicit (sanoid's default template would otherwise apply 48 silently);
            # mirrored by backup-snapshot-prune on backup/personal-backup.
            hourly = 48;
            daily = 30;
            monthly = 6;
            autosnap = true;
            autoprune = true;
          };
        };
      };

      syncoid = {
        enable = true;
        # Run once daily right after the 03:00 sanoid snapshot (which includes the 02:15 DB dump)
        # so the backup HDD spins up only once per day.
        interval = "*-*-* 03:05:00";
        commonArgs = [ "--no-sync-snap" ];
        commands = {
          "state-backup" = {
            source = "tank/var-lib";
            target = "backup/var-lib";
          };
          "data-backup" = {
            source = "tank/data";
            target = "backup/personal-backup";
          };
        };
      };

      restic.backups.gdrive-system = {
        initialize = true;
        repository = "rclone:gdrive:homelab-backups/system-encrypted";
        passwordFile = "${cfg.secretsDir}/restic.pass";
        rcloneConfigFile = "${cfg.secretsDir}/rclone-backup.conf";
        paths = [
          "/var/lib/backup/postgresql"
          "/var/lib/backup/vaultwarden"
          "/var/lib/radicale"
          "/var/lib/couchdb"
          "/var/lib/lidarr"
          "/var/lib/private/technitium-dns-server"
          # Static uid/gid allocations so restored file ownership matches after a full rebuild
          "/var/lib/nixos"
          cfg.secretsDir
        ];
        timerConfig = {
          OnCalendar = "*-*-* 03:45:00";
          Persistent = true;
        };
        pruneOpts = [
          "--keep-daily 7"
          "--keep-weekly 4"
          "--keep-monthly 6"
        ];
      };

      restic.backups.gdrive-other-backups = {
        initialize = true;
        repository = "rclone:gdrive:homelab-backups/other-backups-encrypted";
        passwordFile = "${cfg.secretsDir}/restic.pass";
        rcloneConfigFile = "${cfg.secretsDir}/rclone-backup.conf";
        paths = [
          "/mnt/nas-data/Giannis/Library/Backups"
        ];
        timerConfig = {
          OnCalendar = "*-*-* 03:50:00";
          Persistent = true;
        };
        pruneOpts = [
          "--keep-daily 7"
          "--keep-weekly 4"
          "--keep-monthly 6"
        ];
      };
    };

    # Catch up on missed nightly jobs at the next boot (e.g. after a UPS shutdown)
    systemd.timers =
      lib.genAttrs
        [
          "postgresqlBackup-immich"
          "syncoid-state-backup"
          "syncoid-data-backup"
          "backup-snapshot-prune"
          "rclone-gdrive-backup"
          "restic-check-gdrive"
        ]
        (_: {
          timerConfig.Persistent = true;
        });

    systemd.services = {
      restic-backups-gdrive-system = {
        after = [
          "network-online.target"
          "postgresqlBackup-immich.service"
          "backup-vaultwarden.service"
        ];
        wants = [ "network-online.target" ];
        serviceConfig.ExecStartPre = lib.mkBefore [
          "${pkgs.coreutils}/bin/test -s ${cfg.secretsDir}/restic.pass"
          "${pkgs.coreutils}/bin/test -s ${cfg.secretsDir}/rclone-backup.conf"
        ];
      };

      restic-backups-gdrive-other-backups = {
        after = [
          "network-online.target"
          "restic-backups-gdrive-system.service"
        ];
        wants = [ "network-online.target" ];
        unitConfig.RequiresMountsFor = "/mnt/nas-data";
        serviceConfig.ExecStartPre = lib.mkBefore [
          "${pkgs.coreutils}/bin/test -s ${cfg.secretsDir}/restic.pass"
          "${pkgs.coreutils}/bin/test -s ${cfg.secretsDir}/rclone-backup.conf"
        ];
      };

      # Prune replicated snapshots on backup in the same daily HDD wake window
      backup-snapshot-prune = {
        description = "Prune old replicated snapshots on backup pool";
        startAt = "*-*-* 03:20:00";
        after = [
          "syncoid-state-backup.service"
          "syncoid-data-backup.service"
        ];
        path = [
          pkgs.coreutils
          pkgs.findutils
          pkgs.gnugrep
          pkgs.zfs
        ];
        script = ''
          set -euo pipefail

          prune_class() {
            local ds="$1"
            local class="$2"
            local keep="$3"
            local snaps

            snaps="$(zfs list -t snapshot -H -o name -S creation "$ds")"
            printf '%s\n' "$snaps" \
              | { grep -E "@autosnap_.*_''${class}$" || true; } \
              | tail -n +"$((keep + 1))" \
              | xargs -r -n1 zfs destroy
          }

          prune_class backup/var-lib hourly 24
          prune_class backup/var-lib daily 30
          prune_class backup/var-lib monthly 3

          prune_class backup/personal-backup hourly 48
          prune_class backup/personal-backup daily 30
          prune_class backup/personal-backup monthly 6
        '';
        serviceConfig.Type = "oneshot";
      };

      # Daily unencrypted sync of Immich media, Documents, and Site to Google Drive
      rclone-gdrive-backup = {
        description = "Sync Immich media, Documents, and Site to Google Drive";
        startAt = "*-*-* 04:00:00";
        after = [
          "network-online.target"
          "restic-backups-gdrive-system.service"
          "restic-backups-gdrive-other-backups.service"
        ];
        wants = [ "network-online.target" ];
        unitConfig.RequiresMountsFor = "/mnt/nas-data";
        path = [
          pkgs.coreutils
          pkgs.rclone
        ];
        script = ''
          set -euo pipefail

          TODAY="$(date +%Y-%m-%d)"
          RCLONE_FLAGS=(
            --config=${cfg.secretsDir}/rclone-backup.conf
            --fast-list
            --transfers=4
            --checkers=8
            --max-delete=200
            --stats=30s
            --stats-one-line
            --log-level=INFO
          )

          rclone sync "''${RCLONE_FLAGS[@]}" \
            --backup-dir "gdrive:homelab-backups/_deleted/$TODAY/media" \
            /mnt/nas-data/Giannis/Apps/Immich/library/admin \
            gdrive:homelab-backups/media

          rclone sync "''${RCLONE_FLAGS[@]}" \
            --backup-dir "gdrive:homelab-backups/_deleted/$TODAY/documents" \
            /mnt/nas-data/Giannis/Library/Documents \
            gdrive:homelab-backups/documents

          rclone sync "''${RCLONE_FLAGS[@]}" \
            --backup-dir "gdrive:homelab-backups/_deleted/$TODAY/site" \
            /mnt/nas-data/Giannis/Apps/Site \
            gdrive:homelab-backups/site

          # Expire dated trash folders older than 30 days (by folder name, since moved
          # files keep their original modification times)
          CUTOFF="$(date -d '30 days ago' +%Y-%m-%d)"
          { rclone lsf --config=${cfg.secretsDir}/rclone-backup.conf --dirs-only \
              gdrive:homelab-backups/_deleted 2>/dev/null || true; } \
            | while IFS= read -r dir; do
                dir="''${dir%/}"
                if [[ "$dir" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ && "$dir" < "$CUTOFF" ]]; then
                  echo "Purging expired trash folder: $dir"
                  rclone purge --config=${cfg.secretsDir}/rclone-backup.conf \
                    "gdrive:homelab-backups/_deleted/$dir"
                fi
              done
        '';
        serviceConfig = {
          Type = "oneshot";
          ExecStartPre = lib.mkBefore [
            "${pkgs.coreutils}/bin/test -s ${cfg.secretsDir}/rclone-backup.conf"
          ];
        };
      };

      # Weekly Restic repository integrity check (5% data read-back) on Google Drive
      restic-check-gdrive = {
        description = "Weekly Restic integrity check for Google Drive backups";
        startAt = "Sun *-*-* 04:30:00";
        after = [
          "network-online.target"
          "restic-backups-gdrive-system.service"
          "restic-backups-gdrive-other-backups.service"
          "rclone-gdrive-backup.service"
        ];
        wants = [ "network-online.target" ];
        unitConfig.RequiresMountsFor = cfg.secretsDir;
        script = ''
          set -euo pipefail
          /run/current-system/sw/bin/restic-gdrive-system check --read-data-subset=5%
          /run/current-system/sw/bin/restic-gdrive-other-backups check --read-data-subset=5%
        '';
        serviceConfig = {
          Type = "oneshot";
          ExecStartPre = lib.mkBefore [
            "${pkgs.coreutils}/bin/test -s ${cfg.secretsDir}/restic.pass"
            "${pkgs.coreutils}/bin/test -s ${cfg.secretsDir}/rclone-backup.conf"
          ];
        };
      };
    };
  };
}
