{
  config,
  lib,
  pkgs-unstable,
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
      package = pkgs-unstable.searxng;
      # Redis is only required when SearXNG's rate limiter / bot protection is enabled
      redisCreateLocally = false;
      # Out-of-repo secret file containing SEARX_SECRET_KEY=<64-hex-chars>
      environmentFile = "${cfg.secretsDir}/searx.env";
      settings = {
        server = {
          bind_address = "127.0.0.1";
          port = cfg.ports.searxng;
          secret_key = "@SEARX_SECRET_KEY@";
          base_url = "https://search.${cfg.domain}/";
          limiter = false;
        };

        engines = [
          {
            name = "bing";
            disabled = false;
          }
          {
            name = "duckduckgo";
            disabled = false;
          }
          {
            name = "brave";
            disabled = false;
          }
          {
            name = "wikipedia";
            disabled = false;
          }
          {
            name = "google";
            disabled = true;
          }
          {
            name = "qwant";
            disabled = true;
          }
          {
            name = "wikidata";
            disabled = true;
          }
          {
            name = "ahmia";
            disabled = true;
          }
          {
            name = "torch";
            disabled = true;
          }
        ];
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
  };
}
