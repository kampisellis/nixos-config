{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.homelab;

  notifyNtfyScript = pkgs.writeShellScript "notify-ntfy" ''
    set -euo pipefail
    unit="''${1:-unknown}"
    host="${config.networking.hostName}"
    ts="$(${pkgs.coreutils}/bin/date -Iseconds)"
    logs="$(${pkgs.systemd}/bin/journalctl -u "$unit" -n 15 --no-pager --output=short-iso 2>/dev/null || echo '(journal unavailable)')"

    body="$(printf 'Unit: %s\nHost: %s\nTime: %s\n\nLast 15 journal lines:\n%s\n' "$unit" "$host" "$ts" "$logs")"

    ${pkgs.curl}/bin/curl \
      --silent \
      --show-error \
      --fail \
      --max-time 10 \
      --retry 3 \
      --retry-delay 2 \
      -H "Title: Homelab Service Failed: $unit" \
      -H "Priority: high" \
      -H "Tags: warning" \
      --data-binary "$body" \
      "http://127.0.0.1:${toString cfg.ports.ntfy}/homelab-alerts"
  '';
in
{
  config = lib.mkIf cfg.enable {
    # Bootloader & headless boot safety
    boot = {
      # Prevent Intel OC Watchdog from claiming /dev/watchdog0 over iTCO_wdt
      blacklistedKernelModules = [ "intel_oc_wdt" ];

      # Explicit systemd stage-1 initrd (default in 26.05, required in 26.11)
      initrd.systemd.enable = true;

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

    # Prevent accidental physical bumps or USB keyboard unplug events from powering off the headless server
    services.logind.settings.Login = {
      HandlePowerKey = "ignore";
      HandleSuspendKey = "ignore";
      HandleHibernateKey = "ignore";
    };

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
        SupplementaryGroups = [ "systemd-journal" ];
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
          "AF_UNIX"
        ];
        ExecStart = "${notifyNtfyScript} %i";
      };
    };

    # Global systemd OnFailure drop-in so every failing service/backup/timer alerts ntfy-sh;
    # same-named per-unit drop-ins mask service.d/10-onfailure.conf on notify-ntfy@ and ntfy-sh
    # to prevent self-referential failure loops (OnFailure= cannot be cleared with an empty value).
    systemd.units = lib.mkIf cfg.ntfy.enable {
      "service.d/10-onfailure.conf".text = ''
        [Unit]
        OnFailure=notify-ntfy@%n.service
      '';
      "notify-ntfy@.service.d/10-onfailure.conf".text = ''
        # Masks service.d/10-onfailure.conf to prevent self-referential failure loops
      '';
      "ntfy-sh.service.d/10-onfailure.conf".text = ''
        # Masks service.d/10-onfailure.conf to prevent self-referential failure loops
      '';
    };

    environment.systemPackages = with pkgs; [
      hdparm
      nut
      smartmontools
      zfs
    ];
  };
}
