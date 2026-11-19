{
  config,
  lib,
  pkgs,
  pkgs-unstable,
  ...
}:

let
  cfg = config.homelab;
  svcCfg = cfg.vaultwarden;
in
{
  options.homelab.vaultwarden = {
    enable = lib.mkEnableOption "Vaultwarden password manager";

    useUnstable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Keep Vaultwarden on nixpkgs-unstable until stable 26.05 is verified >= running DB schema version.";
    };
  };

  config = lib.mkIf (cfg.enable && svcCfg.enable) {
    # State directory remains /var/lib/bitwarden_rs (module default)
    services.vaultwarden = {
      enable = true;
      # Pinned to unstable to prevent SQLite schema downgrade; compare versions in Phase 2 before switching to stable
      package = if svcCfg.useUnstable then pkgs-unstable.vaultwarden else pkgs.vaultwarden;
      dbBackend = "sqlite";
      backupDir = "/var/lib/backup/vaultwarden";
      config = {
        DOMAIN = "https://vault.${cfg.domain}";
        ROCKET_ADDRESS = "127.0.0.1";
        ROCKET_PORT = cfg.ports.vaultwarden;
        SIGNUPS_ALLOWED = false;
      };
    };

    homelab.services.vault = {
      name = "Vaultwarden";
      subdomain = "vault";
      upstream = "http://127.0.0.1:${toString cfg.ports.vaultwarden}";
      group = "Core & Media";
      icon = "vaultwarden.png";
      description = "Passwords & 2FA";
      order = 20;
    };

    systemd.services.vaultwarden.onFailure = [ "notify-ntfy@%n.service" ];
  };
}
