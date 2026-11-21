{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.homelab;
in
{
  config = lib.mkIf cfg.enable {
    # Bootloader & headless boot safety
    boot = {
      # Prevent Intel OC Watchdog from claiming /dev/watchdog0 over iTCO_wdt
      blacklistedKernelModules = [ "intel_oc_wdt" ];

      loader = {
        systemd-boot = {
          enable = true;
          # Safe generation cap for the 510 MB EFI System Partition
          configurationLimit = 5;
        };
        # Gigabyte B660M DS3H DDR4 NVRAM writes trigger BIOS "Boot failure detected"
        efi.canTouchEfiVariables = false;
      };
    };

    systemd.settings.Manager.RuntimeWatchdogSec = "30s";

    # Hardware & power optimization (Intel Core i3-12100 + UHD Graphics 730)
    hardware = {
      enableRedistributableFirmware = true;
      cpu.intel.updateMicrocode = true;

      graphics = {
        enable = true;
        extraPackages = with pkgs; [
          intel-media-driver
          vpl-gpu-rt
          intel-compute-runtime
        ];
      };
    };

    powerManagement = {
      enable = true;
      cpuFreqGovernor = "powersave";
    };

    # Compressed RAM swap protects against OOM under ZFS ARC + Immich ML + PostgreSQL
    zramSwap = {
      enable = true;
      memoryPercent = 25;
    };

    users.users.${cfg.user} = {
      isNormalUser = true;
      extraGroups = [
        "wheel"
        "video"
        "render"
      ];
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINIDK/Rn5tuPGN1ZqtPWaQSmEUjDzo9V0zqOiK+FCk/a giannis@asusarch"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN31B0TZsVyq8QQoks21K5CLs5agZqZUbNDzSBtbV9NA giannis@laptop"
      ];
    };

    # Passwordless sudo scoped ONLY to the headless server (never on laptop)
    security.sudo.wheelNeedsPassword = false;

    # Hardened SSH: key-only auth, no root login
    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
      };
    };

    # Cockpit bound strictly to loopback behind Caddy TLS reverse proxy
    services.cockpit = {
      enable = true;
      port = cfg.ports.cockpit;
      openFirewall = false;
      settings.WebService = {
        AllowUnencrypted = true;
        ProtocolHeader = "X-Forwarded-Proto";
        Origins = lib.mkForce "https://cockpit.${cfg.domain} wss://cockpit.${cfg.domain}";
      };
    };

    # Empty string resets upstream cockpit.socket ListenStream before binding loopback only
    systemd.sockets.cockpit.listenStreams = lib.mkForce [
      ""
      "127.0.0.1:${toString cfg.ports.cockpit}"
    ];

    homelab.services.cockpit = {
      name = "Cockpit";
      subdomain = "cockpit";
      upstream = "http://127.0.0.1:${toString cfg.ports.cockpit}";
      group = "Infrastructure";
      icon = "cockpit.png";
      description = "NixOS Server UI";
      order = 10;
    };

    # Reusable hardened systemd failure notifier targeting local ntfy-sh
    systemd.services."notify-ntfy@" = {
      description = "Send systemd failure alert to ntfy for %i";
      serviceConfig = {
        Type = "oneshot";
        DynamicUser = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        LockPersonality = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
        ];
        ExecStart = ''
          ${pkgs.curl}/bin/curl \
            --silent \
            --show-error \
            --fail \
            --max-time 10 \
            --retry 3 \
            --retry-delay 2 \
            -H "Title: Homelab Service Failed" \
            -H "Priority: high" \
            -H "Tags: warning" \
            -d "Service %i failed on ${config.networking.hostName}" \
            http://127.0.0.1:${toString cfg.ports.ntfy}/homelab-alerts
        '';
      };
    };

    environment.systemPackages = with pkgs; [
      hdparm
      nut
      smartmontools
      zfs
    ];
  };
}
