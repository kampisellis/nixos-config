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
      default = false;
      description = "Use Vaultwarden from nixpkgs-unstable instead of stable nixpkgs.";
    };
  };

  config = lib.mkIf (cfg.enable && svcCfg.enable) {
    # State directory is /var/lib/vaultwarden (module default); backup-vaultwarden writes
    # a consistent SQLite copy plus RSA keys to backupDir nightly for Restic.
    services.vaultwarden = {
      enable = true;
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

    systemd.services = {
      vaultwarden.onFailure = [ "notify-ntfy@%n.service" ];
      backup-vaultwarden.onFailure = [ "notify-ntfy@%n.service" ];
    };
  };
}
