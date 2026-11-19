{ config, lib, ... }:

let
  cfg = config.homelab;
  svcCfg = cfg.uptime-kuma;
in
{
  options.homelab.uptime-kuma = {
    enable = lib.mkEnableOption "Uptime Kuma service monitoring";
  };

  config = lib.mkIf (cfg.enable && svcCfg.enable) {
    services.uptime-kuma = {
      enable = true;
      settings = {
        HOST = "127.0.0.1";
        PORT = toString cfg.ports.uptimeKuma;
      };
    };

    homelab.services.monitor = {
      name = "Uptime Kuma";
      subdomain = "monitor";
      upstream = "http://127.0.0.1:${toString cfg.ports.uptimeKuma}";
      group = "Infrastructure";
      icon = "uptime-kuma.png";
      description = "Monitoring";
      order = 30;
    };

    systemd.services.uptime-kuma.onFailure = [ "notify-ntfy@%n.service" ];
  };
}
