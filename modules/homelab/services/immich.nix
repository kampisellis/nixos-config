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
    # Pin PostgreSQL major version explicitly and tune conservatively for 32 GiB RAM + NVMe ZFS mirror
    services.postgresql = {
      package = pkgs.postgresql_16;
      settings = {
        shared_buffers = "2GB";
        effective_cache_size = "8GB";
        work_mem = "16MB";
        maintenance_work_mem = "512MB";
        random_page_cost = 1.1;
        effective_io_concurrency = 200;
        checkpoint_completion_target = 0.9;
      };
    };

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
      group = "Apps & Data";
      icon = "sh-immich.svg";
      description = "Photos & Videos";
      siteMonitor = "http://127.0.0.1:${toString cfg.ports.immich}";
      order = 10;
    };

    # Prevent Immich from writing into an unmounted /mnt/nas-data directory on the boot SSD
    systemd.services.immich-server.unitConfig.RequiresMountsFor = "/mnt/nas-data";
  };
}
