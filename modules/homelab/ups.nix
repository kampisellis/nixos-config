{ config, lib, ... }:

let
  cfg = config.homelab;
  nutGroup = config.power.ups.upsmon.group;
in
{
  config = lib.mkIf cfg.enable {
    # Grant the NUT group (nutmon by default on NixOS) access to the PowerWalker USB HID device,
    # replacing the previous "user = root" directive workaround.
    services.udev.extraRules = ''
      SUBSYSTEM=="usb", ATTR{idVendor}=="06da", ATTR{idProduct}=="ffff", MODE="0660", GROUP="${nutGroup}"
    '';

    # PowerWalker VFI 1000 ICR IoT (graceful shutdown at 20% battery charge)
    power.ups = {
      enable = true;
      mode = "standalone";

      ups."myups" = {
        driver = "usbhid-ups";
        port = "auto";
        description = "PowerWalker VFI 1000 ICR IoT";
        directives = [
          "vendorid = 06DA"
          "productid = FFFF"
          "pollinterval = 10"
          "ignorelb"
          "override.battery.charge.low = 20"
        ];
      };

      users.upsmon = {
        passwordFile = "${cfg.secretsDir}/upsmon.pass";
        upsmon = "primary";
      };

      upsmon.monitor."myups" = {
        system = "myups@localhost";
        powerValue = 1;
        user = "upsmon";
        passwordFile = "${cfg.secretsDir}/upsmon.pass";
        type = "primary";
      };
    };

    systemd.services = {
      upsdrv.onFailure = [ "notify-ntfy@%n.service" ];
      upsd.onFailure = [ "notify-ntfy@%n.service" ];
      upsmon.onFailure = [ "notify-ntfy@%n.service" ];
    };
  };
}
