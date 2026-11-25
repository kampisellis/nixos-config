{ config, lib, ... }:

let
  cfg = config.homelab;
  svcCfg = cfg.couchdb;
in
{
  options.homelab.couchdb = {
    enable = lib.mkEnableOption "CouchDB backend for Obsidian LiveSync";
  };

  config = lib.mkIf (cfg.enable && svcCfg.enable) {
    # services.couchdb.configFile defaults to /var/lib/couchdb/local.ini,
    # so extraConfigFiles is intentionally omitted to avoid loading local.ini twice.
    services.couchdb = {
      enable = true;
      bindAddress = "127.0.0.1";
      port = cfg.ports.couchdb;
      databaseDir = "/var/lib/couchdb";
      viewIndexDir = "/var/lib/couchdb";
      # Allow unauthenticated /_up health checks while keeping require_valid_user = true on all DBs/endpoints
      extraConfig.chttpd.require_valid_user_except_for_up = true;
    };

    homelab.services.obsidian = {
      name = "Obsidian LiveSync";
      subdomain = "obsidian";
      path = "/_utils";
      upstream = "http://127.0.0.1:${toString cfg.ports.couchdb}";
      group = "Apps & Data";
      icon = "sh-obsidian.svg";
      description = "CouchDB Notes";
      siteMonitor = "http://127.0.0.1:${toString cfg.ports.couchdb}/_up";
      order = 30;
    };

    systemd.services.couchdb.environment = {
      # epmd is spawned by CouchDB itself; keep it on loopback instead of 0.0.0.0
      ERL_EPMD_ADDRESS = "127.0.0.1";
      # Disable Erlang scheduler busy-wait spinning (prevents ~24% idle CPU burn under powersave governor)
      ERL_ZFLAGS = "+sbwt none +sbwtdcpu none +sbwtdio none";
    };
  };
}
