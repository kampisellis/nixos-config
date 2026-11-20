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
          "/var/lib/vaultwarden"
          "/var/lib/radicale"
          "/var/lib/couchdb"
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
        unitConfig.ConditionFileNotEmpty = [
          "/var/lib/secrets/restic.pass"
          "/var/lib/secrets/rclone-backup.conf"
        ];
      };

      # Prune replicated snapshots on backup in the same daily HDD wake window
      backup-snapshot-prune = {
        description = "Prune old replicated snapshots on backup pool";
        startAt = "*-*-* 03:20:00";
        onFailure = [ "notify-ntfy@%n.service" ];
        path = [
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.zfs
        ];
        script = ''
          for ds in backup/var-lib backup/personal-backup; do
            (zfs list -t snapshot -H -o name -S creation "$ds" | grep '@autosnap_' || true) \
              | tail -n +36 \
              | while IFS= read -r snap; do
                  zfs destroy "$snap"
                done
          done
        '';
        serviceConfig.Type = "oneshot";
      };

      # Daily unencrypted sync of Immich originals and Documents to Google Drive
      rclone-gdrive-backup = {
        description = "Sync Immich media and Documents to Google Drive";
        startAt = "*-*-* 04:00:00";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        onFailure = [ "notify-ntfy@%n.service" ];
        unitConfig = {
          RequiresMountsFor = "/mnt/nas-data";
          ConditionFileNotEmpty = "/var/lib/secrets/rclone-backup.conf";
        };
        path = [ pkgs.rclone ];
        script = ''
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
            /mnt/nas-data/Giannis/Apps/Immich/library/admin \
            gdrive:homelab-backups/media

          rclone sync "''${RCLONE_FLAGS[@]}" \
            /mnt/nas-data/Giannis/Library/Documents \
            gdrive:homelab-backups/documents
        '';
        serviceConfig.Type = "oneshot";
      };
    };
  };
}
