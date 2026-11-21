{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.homelab;
  nutGroup = config.power.ups.upsmon.group;

  upsNtfyScript = pkgs.writeShellScript "ups-notify-ntfy" ''
    notify_type="''${NOTIFYTYPE:-EVENT}"
    ups_name="''${UPSNAME:-myups}"
    message="''${1:-UPS event $notify_type on $ups_name}"

    case "$notify_type" in
      LOWBATT|FSD|SHUTDOWN)
        priority="urgent"
        tags="zap,rotating_light"
        ;;
      ONBATT|COMMBAD|NOCOMM|REPLBATT)
        priority="high"
        tags="battery,warning"
        ;;
      ONLINE|COMMOK)
        priority="default"
        tags="electric_plug,white_check_mark"
        ;;
      *)
        priority="default"
        tags="electric_plug"
        ;;
    esac

    ${pkgs.curl}/bin/curl \
      --silent \
      --show-error \
      --max-time 10 \
      -H "Title: UPS [$notify_type] on ${config.networking.hostName}" \
      -H "Priority: $priority" \
      -H "Tags: $tags" \
      -d "$message ($ups_name)" \
      "http://127.0.0.1:${toString cfg.ports.ntfy}/homelab-alerts" || true
  '';
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

      upsmon = {
        monitor."myups" = {
          system = "myups@localhost";
          powerValue = 1;
          user = "upsmon";
          passwordFile = "${cfg.secretsDir}/upsmon.pass";
          type = "primary";
        };

        settings = {
          NOTIFYCMD = "${upsNtfyScript}";
          NOTIFYFLAG = [
            [
              "ONLINE"
              "SYSLOG+EXEC"
            ]
            [
              "ONBATT"
              "SYSLOG+EXEC"
            ]
            [
              "LOWBATT"
              "SYSLOG+EXEC"
            ]
            [
              "FSD"
              "SYSLOG+EXEC"
            ]
            [
              "COMMOK"
              "SYSLOG+EXEC"
            ]
            [
              "COMMBAD"
              "SYSLOG+EXEC"
            ]
            [
              "SHUTDOWN"
              "SYSLOG+EXEC"
            ]
            [
              "REPLBATT"
              "SYSLOG+EXEC"
            ]
            [
              "NOCOMM"
              "SYSLOG+EXEC"
            ]
          ];
        };
      };
    };

    homelab.services.ups = {
      name = "PowerWalker UPS";
      subdomain = "ups";
      group = "Infrastructure";
      icon = "mdi-battery-charging";
      description = "UPS IoT Portal";
      order = 100;
      extraCaddyConfig = ''
        reverse_proxy https://10.10.10.253 {
          header_up Host 10.10.10.253
          header_down Location ^https?://10\.10\.10\.253(.*)$ https://ups.${cfg.domain}$1
          transport http {
            tls_insecure_skip_verify
            versions 1.1
            keepalive off
            dial_timeout 15s
            response_header_timeout 30s
          }
        }
      '';
    };

    systemd.services = {
      upsdrv.onFailure = [ "notify-ntfy@%n.service" ];
      upsd.onFailure = [ "notify-ntfy@%n.service" ];
      upsmon.onFailure = [ "notify-ntfy@%n.service" ];
    };
  };
}
