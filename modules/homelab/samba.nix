{ config, lib, ... }:

let
  cfg = config.homelab;
in
{
  config = lib.mkIf cfg.enable {
    services.samba = {
      enable = true;
      # Keep false so NixOS does not open legacy NetBIOS ports (TCP 139, UDP 137/138);
      # SMB3 TCP 445 is opened explicitly in networking.nix.
      openFirewall = false;
      # SMB3-only: NetBIOS name service (nmbd, UDP 137/138) and TCP 139 are unnecessary;
      # winbindd is also unneeded on a standalone security = "user" server.
      nmbd.enable = false;
      winbindd.enable = false;
      settings = {
        global = {
          security = "user";
          "server min protocol" = "SMB3";
          "disable netbios" = "yes";
          "smb ports" = "445";
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
          "force user" = cfg.user;
          "force group" = "users";
          "create mask" = "0664";
          "directory mask" = "0775";
        };
      };
    };

    # Prevent smbd from serving an empty directory on the boot SSD if tank/data fails to mount
    systemd.services.samba-smbd.unitConfig.RequiresMountsFor =
      lib.mkForce "/var/lib/samba /mnt/nas-data";
  };
}
