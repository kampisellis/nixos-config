{ config, lib, ... }:

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
    };
  };
}
