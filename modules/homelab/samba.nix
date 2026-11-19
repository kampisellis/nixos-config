{ config, lib, ... }:

let
  cfg = config.homelab;
in
{
  config = lib.mkIf cfg.enable {
    services.samba = {
      enable = true;
      openFirewall = true;
      settings = {
        global = {
          security = "user";
          "server min protocol" = "SMB3";
          "hosts allow" = "${cfg.subnets.lan} ${cfg.subnets.netbird} 127.0.0.1";
          "hosts deny" = "0.0.0.0/0";
          "invalid users" = [ "root" ];
        };
        roms = {
          path = "/mnt/roms";
          browseable = "yes";
          "read only" = "yes";
          "valid users" = cfg.user;
        };
        data = {
          path = "/mnt/nas-data";
          browseable = "yes";
          "read only" = "no";
          "valid users" = cfg.user;
        };
      };
    };

    # Prevent smbd from serving an empty directory on the boot SSD if tank/data fails to mount
    systemd.services.samba-smbd = {
      unitConfig.RequiresMountsFor = lib.mkForce "/var/lib/samba /mnt/nas-data";
      onFailure = [ "notify-ntfy@%n.service" ];
    };
  };
}
