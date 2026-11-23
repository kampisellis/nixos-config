{
  config,
  lib,
  pkgs,
  pkgs-unstable,
  ...
}:

let
  cfg = config.homelab;
  svcCfg = cfg.immich;
in
{
  options.homelab.immich = {
    enable = lib.mkEnableOption "Immich photo & video management";

    useUnstable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Keep Immich on nixpkgs-unstable because the live PostgreSQL DB is already migrated to 3.4.1 (no downgrade supported).";
    };
  };

  config = lib.mkIf (cfg.enable && svcCfg.enable) {
    # Pin PostgreSQL major version explicitly to avoid accidental cluster mismatch on channel upgrades
    services.postgresql.package = pkgs.postgresql_16;

    services.immich = {
      enable = true;
      # Pinned to unstable while live DB runs 3.4.1; compare against 26.05 before disabling useUnstable
      package = if svcCfg.useUnstable then pkgs-unstable.immich else pkgs.immich;
      host = "127.0.0.1";
      port = cfg.ports.immich;
      mediaLocation = "/mnt/nas-data/Giannis/Apps/Immich";
      accelerationDevices = [ "/dev/dri/renderD128" ];
    };

    homelab.services.photos = {
      name = "Immich";
      subdomain = "photos";
      upstream = "http://127.0.0.1:${toString cfg.ports.immich}";
      group = "Core & Media";
      icon = "immich.png";
      description = "Photos & Videos";
      order = 10;
    };

    # Prevent Immich from writing into an unmounted /mnt/nas-data directory on the boot SSD
    systemd.services.immich-server.unitConfig.RequiresMountsFor = "/mnt/nas-data";
  };
}
