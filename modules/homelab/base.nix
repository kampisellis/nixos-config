{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.homelab;

  homelabNotify = pkgs.writeShellScriptBin "homelab-notify" ''
    set -euo pipefail
    title="''${1:-Homelab Alert on ${config.networking.hostName}}"
    priority="''${2:-default}"
    tags="''${3:-bell}"
    body="$(${pkgs.coreutils}/bin/cat)"

    ${pkgs.curl}/bin/curl \
      --fail \
      --silent \
      --show-error \
      --max-time 5 \
      --retry 2 \
      --retry-delay 1 \
      --retry-connrefused \
      -H "Title: $title" \
      -H "Priority: $priority" \
      -H "Tags: $tags" \
      --data-binary "$body" \
      "http://127.0.0.1:${toString cfg.ports.ntfy}/homelab-alerts" \
      >/dev/null
  '';

  notifyNtfyScript = pkgs.writeShellScript "notify-ntfy" ''
    set -euo pipefail
    unit="''${1:-unknown}"
    host="${config.networking.hostName}"
    ts="$(${pkgs.coreutils}/bin/date -Iseconds)"
    logs="$(${pkgs.systemd}/bin/journalctl -u "$unit" -n 15 --no-pager --output=short-iso 2>/dev/null || echo '(journal unavailable)')"

    printf 'Unit: %s\nHost: %s\nTime: %s\n\nLast 15 journal lines:\n%s\n' "$unit" "$host" "$ts" "$logs" \
      | ${lib.getExe homelabNotify} "Homelab Service Failed: $unit" "high" "warning"
  '';
in
{
  config = lib.mkIf cfg.enable {
    homelab.notifyScript = homelabNotify;

    # Keep background Nix builds from starving Immich, DNS, or Samba
    nix = {
      daemonCPUSchedPolicy = "idle";
      daemonIOSchedClass = "idle";
    };

    # Bootloader & headless boot safety
    boot = {
      # Prevent Intel OC Watchdog from claiming /dev/watchdog0 over iTCO_wdt
      blacklistedKernelModules = [ "intel_oc_wdt" ];

      # Clean disk-backed /tmp on boot
      tmp.cleanOnBoot = true;

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

    systemd = {
      settings.Manager.RuntimeWatchdogSec = "30s";

      # Protect headless server slices from RAM-exhaustion freezes under ZFS ARC + Immich ML
      oomd = {
        enableRootSlice = true;
        enableSystemSlice = true;
      };
    };

    # Distribute 2.5GbE, dual-NVMe, and SATA interrupts across i3-12100 cores
    services.irqbalance.enable = true;

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
      allowed-origins = [
        "https://cockpit.${cfg.domain}"
        "wss://cockpit.${cfg.domain}"
      ];
      settings.WebService = {
        AllowUnencrypted = true;
        ProtocolHeader = "X-Forwarded-Proto";
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
      group = "Server & Services";
      icon = "sh-cockpit-light.svg";
      description = "NixOS Server UI";
      siteMonitor = "http://127.0.0.1:${toString cfg.ports.cockpit}";
      order = 10;
    };

    # Reusable hardened systemd failure notifier targeting local ntfy-sh
    systemd.services."notify-ntfy@" = {
      description = "Send systemd failure alert to ntfy for %i";
      after = [ "ntfy-sh.service" ];
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
      homelabNotify
      nut
      smartmontools
      zfs
    ];
  };
}
