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
        passwordFile = "/var/lib/secrets/restic.pass";
        rcloneConfigFile = "/var/lib/secrets/rclone-backup.conf";
        paths = [
          "/var/lib/backup/postgresql"
          "/var/lib/backup/vaultwarden"
          "/var/lib/radicale"
          "/var/lib/couchdb"
          "/var/lib/lidarr"
          "/var/lib/private/technitium-dns-server"
          "/var/lib/secrets"
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
    };

    systemd.services = {
      sanoid.onFailure = [ "notify-ntfy@%n.service" ];
      syncoid-state-backup.onFailure = [ "notify-ntfy@%n.service" ];
      syncoid-data-backup.onFailure = [ "notify-ntfy@%n.service" ];
      postgresqlBackup-immich.onFailure = [ "notify-ntfy@%n.service" ];

      restic-backups-gdrive-system = {
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        onFailure = [ "notify-ntfy@%n.service" ];
        serviceConfig.ExecStartPre = lib.mkBefore [
          "${pkgs.coreutils}/bin/test -s /var/lib/secrets/restic.pass"
          "${pkgs.coreutils}/bin/test -s /var/lib/secrets/rclone-backup.conf"
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
        onFailure = [ "notify-ntfy@%n.service" ];
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
        ];
        wants = [ "network-online.target" ];
        onFailure = [ "notify-ntfy@%n.service" ];
        unitConfig.RequiresMountsFor = "/mnt/nas-data";
        path = [
          pkgs.coreutils
          pkgs.rclone
        ];
        script = ''
          set -euo pipefail

          TODAY="$(date +%Y-%m-%d)"
          RCLONE_FLAGS=(
            --config=/var/lib/secrets/rclone-backup.conf
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
        '';
        serviceConfig = {
          Type = "oneshot";
          ExecStartPre = lib.mkBefore [
            "${pkgs.coreutils}/bin/test -s /var/lib/secrets/rclone-backup.conf"
          ];
        };
      };
    };
  };
}
