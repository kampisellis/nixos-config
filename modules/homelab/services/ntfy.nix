{ config, lib, ... }:

let
  cfg = config.homelab;
  svcCfg = cfg.ntfy;
in
{
  options.homelab.ntfy = {
    enable = lib.mkEnableOption "ntfy-sh push notification server";
  };

  config = lib.mkIf (cfg.enable && svcCfg.enable) {
    # Do not wire onFailure -> notify-ntfy@ here to avoid self-referential failure loops
    services.ntfy-sh = {
      enable = true;
      settings = {
        base-url = "https://ntfy.${cfg.domain}";
        listen-http = "127.0.0.1:${toString cfg.ports.ntfy}";
        cache-file = "/var/lib/ntfy-sh/cache.db";
        behind-proxy = true;
      };
    };

    homelab.services.ntfy = {
      name = "ntfy";
      subdomain = "ntfy";
      upstream = "http://127.0.0.1:${toString cfg.ports.ntfy}";
      group = "Server & Services";
      icon = "sh-ntfy.svg";
      description = "Notifications";
      siteMonitor = "http://127.0.0.1:${toString cfg.ports.ntfy}/v1/health";
      order = 30;
    };
  };
}
