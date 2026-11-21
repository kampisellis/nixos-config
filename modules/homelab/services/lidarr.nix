{ config, lib, ... }:

let
  cfg = config.homelab;
  svcCfg = cfg.lidarr;
in
{
  options.homelab.lidarr = {
    enable = lib.mkEnableOption "Lidarr music library manager";
  };

  config = lib.mkIf (cfg.enable && svcCfg.enable) {
    services.lidarr = {
      enable = true;
      # Keep explicitly set: NixOS module defaults to /var/lib/lidarr/.config/Lidarr,
      # whereas migrated state from Proxmox LXC resides directly in /var/lib/lidarr.
      dataDir = "/var/lib/lidarr";
      # Bind to loopback behind Caddy and follow the shared port registry
      settings.server = {
        port = cfg.ports.lidarr;
        bindaddress = "127.0.0.1";
      };
    };

    homelab.services.lidarr = {
      name = "Lidarr";
      subdomain = "lidarr";
      upstream = "http://127.0.0.1:${toString cfg.ports.lidarr}";
      group = "Core & Media";
      icon = "lidarr.png";
      description = "Music Library";
      order = 50;
    };

    systemd.services.lidarr.onFailure = [ "notify-ntfy@%n.service" ];
  };
}
