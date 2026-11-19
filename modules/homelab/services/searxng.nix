{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.homelab;
  svcCfg = cfg.searxng;
in
{
  options.homelab.searxng = {
    enable = lib.mkEnableOption "SearXNG privacy-respecting metasearch engine";
  };

  config = lib.mkIf (cfg.enable && svcCfg.enable) {
    services.searx = {
      enable = true;
      package = pkgs.searxng;
      redisCreateLocally = true;
      # Out-of-repo secret file containing SEARX_SECRET_KEY=<64-hex-chars>
      environmentFile = "${cfg.secretsDir}/searx.env";
      settings = {
        server = {
          bind_address = "127.0.0.1";
          port = cfg.ports.searxng;
          secret_key = "@SEARX_SECRET_KEY@";
        };
      };
    };

    homelab.services.search = {
      name = "SearXNG";
      subdomain = "search";
      upstream = "http://127.0.0.1:${toString cfg.ports.searxng}";
      group = "Infrastructure";
      icon = "searxng.png";
      description = "Search Engine";
      order = 50;
    };

    systemd.services.searx.onFailure = [ "notify-ntfy@%n.service" ];
  };
}
