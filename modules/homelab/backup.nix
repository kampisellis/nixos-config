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
        # Run once daily right after postgresqlBackup so the backup HDD stays spun down
        interval = "*-*-* 02:45:00";
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
    };

    systemd.services = {
      sanoid.onFailure = [ "notify-ntfy@%n.service" ];
      syncoid-state-backup.onFailure = [ "notify-ntfy@%n.service" ];
      syncoid-data-backup.onFailure = [ "notify-ntfy@%n.service" ];
      postgresqlBackup-immich.onFailure = [ "notify-ntfy@%n.service" ];

      # Prune replicated @autosnap_ snapshots on backup right after daily syncoid
      backup-snapshot-prune = {
        description = "Prune old replicated snapshots on backup pool";
        startAt = "*-*-* 03:15:00";
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
    };
  };
}
