{ config, lib, ... }:

let
  cfg = config.homelab;
  svcCfg = cfg.radicale;
in
{
  options.homelab.radicale = {
    enable = lib.mkEnableOption "Radicale CalDAV/CardDAV server";
  };

  config = lib.mkIf (cfg.enable && svcCfg.enable) {
    services.radicale = {
      enable = true;
      settings = {
        server.hosts = [ "127.0.0.1:${toString cfg.ports.radicale}" ];
        auth = {
          type = "htpasswd";
          htpasswd_filename = "/var/lib/radicale/users";
          htpasswd_encryption = "bcrypt";
        };
        storage.filesystem_folder = "/var/lib/radicale/collections";
      };
    };

    homelab.services.webdav = {
      name = "Radicale";
      subdomain = "webdav";
      upstream = "http://127.0.0.1:${toString cfg.ports.radicale}";
      group = "Apps & Data";
      icon = "sh-radicale.svg";
      description = "CalDAV & CardDAV";
      siteMonitor = "http://127.0.0.1:${toString cfg.ports.radicale}/.web/";
      order = 40;
    };
  };
}
