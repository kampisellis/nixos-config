{
  config,
  lib,
  pkgs,
  pkgs-unstable,
  ...
}:

let
  cfg = config.homelab;
in
{
  options.homelab = {
    technitium.useUnstable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Use technitium-dns-server from nixpkgs-unstable instead of stable nixpkgs.";
    };

    netbird = {
      useUnstable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Use netbird from nixpkgs-unstable to match management server/mobile client version (0.80.x).";
      };

      enableLocalRouteFix = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Bridge NetBird netbird-rt-fwd ACL chain into INPUT for local LAN alias IPs.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Pin Realtek RTL8125 2.5GbE (MAC d8:5e:d3:9c:11:15) to deterministic name "nic0"
    systemd.network.links."10-nic0" = {
      matchConfig.MACAddress = "d8:5e:d3:9c:11:15";
      linkConfig.Name = "nic0";
    };

    networking = {
      hostName = "homelab";
      hostId = "8425e349";
      useDHCP = false;

      interfaces.nic0 = {
        wakeOnLan.enable = true;
        ipv4.addresses = [
          {
            address = cfg.ips.primary;
            prefixLength = 24;
          }
          {
            address = cfg.ips.dns;
            prefixLength = 24;
          }
          {
            address = cfg.ips.caddy;
            prefixLength = 24;
          }
          {
            address = cfg.ips.site;
            prefixLength = 24;
          }
        ];
      };

      defaultGateway = cfg.ips.gateway;
      nameservers = [
        "1.1.1.1"
        "1.0.0.1"
      ];

      # Explicit firewall: no blanket trustedInterfaces on wt0.
      # DNS (53 TCP/UDP) is open explicitly (Technitium UI is Caddy-only); NetBird opens 51820 (UDP); Samba opens 445/139 (TCP).
      firewall = {
        enable = true;
        allowedTCPPorts = [
          22
          53
          80
          443
        ];
        allowedUDPPorts = [
          53
        ];
        interfaces.wt0.allowedTCPPorts = [
          cfg.ports.staticSite
        ];
      };
    };

    services.technitium-dns-server = {
      enable = true;
      package =
        if cfg.technitium.useUnstable then
          pkgs-unstable.technitium-dns-server
        else
          pkgs.technitium-dns-server;
      openFirewall = false;
    };

    systemd.services.technitium-dns-server.onFailure = [ "notify-ntfy@%n.service" ];

    services.netbird = {
      # Pinned to unstable while stable nixpkgs lags behind the self-hosted 0.80.x NetBird stack
      package = if cfg.netbird.useUnstable then pkgs-unstable.netbird else pkgs.netbird;
      useRoutingFeatures = "both";
      clients.wt0 = {
        port = cfg.ports.netbird;
        interface = "wt0";
        openFirewall = false;
        autoStart = true;
      };
    };

    systemd.services.netbird-wt0.onFailure = [ "notify-ntfy@%n.service" ];

    # Workaround: VPN peers and the external VPS reach local alias IPs (.101/.105/.109)
    # hosted on this same machine, so packets traverse INPUT instead of FORWARD.
    # Alerts via ntfy if NetBird ever renames its internal nftables chain.
    # Can be retired once the external VPS and NetBird peers target the NetBird peer IP directly.
    systemd.services.netbird-local-route-fix = lib.mkIf cfg.netbird.enableLocalRouteFix {
      description = "Bridge NetBird route ACLs (netbird-rt-fwd) into INPUT chain for local server alias IPs";
      after = [ "netbird-wt0.service" ];
      bindsTo = [ "netbird-wt0.service" ];
      wantedBy = [ "multi-user.target" ];
      onFailure = [ "notify-ntfy@%n.service" ];
      path = [
        pkgs.coreutils
        pkgs.curl
        pkgs.gnugrep
        pkgs.nftables
      ];
      script = ''
        missing_count=0
        alerted=0

        while true; do
          if nft list chain ip netbird netbird-acl-input-rules >/dev/null 2>&1; then
            missing_count=0
            alerted=0
            if ! nft list chain ip netbird netbird-acl-input-rules | grep -q "jump netbird-rt-fwd"; then
              nft add rule ip netbird netbird-acl-input-rules jump netbird-rt-fwd || true
            fi
          else
            missing_count=$((missing_count + 1))
            if [ "$missing_count" -ge 6 ] && [ "$alerted" -eq 0 ]; then
              curl --silent --max-time 10 \
                -H "Title: NetBird nftables Chain Missing" \
                -H "Priority: high" \
                -H "Tags: warning" \
                -d "Chain ip netbird netbird-acl-input-rules not found for 30s; VPN access to local alias IPs may be broken." \
                "http://127.0.0.1:${toString cfg.ports.ntfy}/homelab-alerts" || true
              alerted=1
            fi
          fi
          sleep 5
        done
      '';
      serviceConfig = {
        Restart = "always";
        RestartSec = "5s";
        CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        LockPersonality = true;
      };
    };

    # Registry entries for network infrastructure UIs
    homelab.services = {
      dns = {
        name = "Technitium DNS";
        subdomain = "dns";
        group = "Infrastructure";
        icon = "technitium.png";
        description = "DNS & Zones";
        order = 20;
        extraCaddyConfig = ''
          @doh path /dns-query*
          handle @doh {
            reverse_proxy http://127.0.0.1:${toString cfg.ports.technitiumDoh} {
              header_up X-Real-IP {remote_host}
            }
          }
          reverse_proxy http://127.0.0.1:${toString cfg.ports.technitiumUi}
        '';
      };

      mikrotik = {
        name = "MikroTik";
        subdomain = "mikrotik";
        upstream = "http://${cfg.ips.gateway}:80";
        group = "Infrastructure";
        icon = "mikrotik.png";
        description = "RouterOS";
        order = 60;
      };

      switch = {
        name = "Ubiquiti Switch";
        subdomain = "switch";
        group = "Infrastructure";
        icon = "ubiquiti.png";
        description = "Core Switch";
        order = 70;
        extraCaddyConfig = ''
          reverse_proxy https://10.10.10.2 {
            header_down Location ^https?://10\.10\.10\.2(?::443)?(.*)$ https://switch.${cfg.domain}$1
            transport http {
              tls_insecure_skip_verify
            }
          }
        '';
      };

      ap = {
        name = "ZTE AP";
        subdomain = "ap";
        group = "Infrastructure";
        icon = "mdi-access-point";
        description = "Wi-Fi Access Point";
        order = 80;
        extraCaddyConfig = ''
          reverse_proxy http://10.10.10.3 {
            header_up Host 10.10.10.3
            header_up Origin http://10.10.10.3
            header_up Referer http://10.10.10.3/
            header_down Location ^http://10\.10\.10\.3(.*)$ https://ap.${cfg.domain}$1
          }
        '';
      };

      zte5g = {
        name = "ZTE 5G";
        subdomain = "5g";
        group = "Infrastructure";
        icon = "mdi-signal-5g";
        description = "5G CPE Modem";
        order = 90;
        extraCaddyConfig = ''
          reverse_proxy http://10.10.20.1 {
            header_up Host 10.10.20.1
            header_up Origin http://10.10.20.1
            header_up Referer http://10.10.20.1/
            header_down Location ^http://10\.10\.20\.1(.*)$ https://5g.${cfg.domain}$1
          }
        '';
      };
    };
  };
}
