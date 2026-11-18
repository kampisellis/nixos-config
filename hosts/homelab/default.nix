{ config, pkgs, lib, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./networking.nix
    ./storage.nix
    ./services.nix
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.systemd-boot.configurationLimit = 10;
  systemd.settings.Manager.RuntimeWatchdogSec = "30s";

  # Hardware & Power Optimization (Intel Core i3-12100 + UHD Graphics 730)
  hardware.cpu.intel.updateMicrocode = true;
  powerManagement = {
    enable = true;
    cpuFreqGovernor = "powersave";
  };

  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver
      vpl-gpu-rt
      intel-compute-runtime
    ];
  };

  # UPS: PowerWalker VFI 1000 ICR IoT (Shutdown στο 20%)
  power.ups = {
    enable = true;
    mode = "standalone";
    ups."myups" = {
      driver = "usbhid-ups";
      port = "auto";
      description = "PowerWalker VFI 1000 ICR IoT";
      directives = [
        "user = root"
        "vendorid = 06DA"
        "productid = FFFF"
        "pollinterval = 10"
        "ignorelb"
        "override.battery.charge.low = 20"
      ];
    };
    users.upsmon = {
      passwordFile = "/var/lib/secrets/upsmon.pass";
      upsmon = "primary";
    };
    upsmon.monitor."myups" = {
      system = "myups@localhost";
      powerValue = 1;
      user = "upsmon";
      passwordFile = "/var/lib/secrets/upsmon.pass";
      type = "primary";
    };
  };

  users.users.gkampisellis = {
    isNormalUser = true;
    extraGroups = [ "wheel" "video" "render" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINIDK/Rn5tuPGN1ZqtPWaQSmEUjDzo9V0zqOiK+FCk/a giannis@asusarch"
    ];
  };

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = true;
  };

  services.cockpit = {
    enable = true;
    port = 9090;
    openFirewall = true;
    settings.WebService = {
      AllowUnencrypted = true;
      ProtocolHeader = "X-Forwarded-Proto";
      Origins = lib.mkForce "https://cockpit.kampisellis.com wss://cockpit.kampisellis.com http://10.10.10.5:9090 ws://10.10.10.5:9090";
    };
  };
  systemd.services."notify-ntfy@" = {
    description = "Send failure alert to ntfy for %i";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = ''
        ${pkgs.curl}/bin/curl -H "Title: Homelab Service Failed" -H "Priority: high" -H "Tags: warning" \
          -d "Service %i failed on homelab" http://127.0.0.1:5055/homelab-alerts
      '';
    };
  };

  environment.systemPackages = with pkgs; [ zfs hdparm nut ];
}
