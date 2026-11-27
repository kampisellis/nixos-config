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
          secret_key = "$SEARX_SECRET_KEY";
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
      group = "Server & Services";
      icon = "sh-searxng.svg";
      description = "Search Engine";
      siteMonitor = "http://127.0.0.1:${toString cfg.ports.searxng}";
      order = 40;
    };

    # Harden searx.service natively on nixos-26.05 without importing the unstable searx module
    # (searx-init.service writes /run/searx/settings.yml separately; searx.service only reads it).
    systemd.services.searx.serviceConfig = {
      CacheDirectory = "searx";
      CacheDirectoryMode = "0700";
      CapabilityBoundingSet = "";
      LockPersonality = true;
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateTmp = true;
      ProtectControlGroups = true;
      ProtectHome = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectSystem = "strict";
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
      ];
      RestrictNamespaces = true;
    };
  };
}
