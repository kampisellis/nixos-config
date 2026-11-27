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
    # TCP BBR + fq for 5G WAN / NetBird / rclone throughput and 16 MiB socket buffers for 2.5GbE SMB3 & WireGuard
    boot = {
      kernelModules = [ "tcp_bbr" ];
      kernel.sysctl = {
        "net.core.default_qdisc" = "fq";
        "net.ipv4.tcp_congestion_control" = "bbr";
        "net.core.rmem_max" = 16777216;
        "net.core.wmem_max" = 16777216;
        "net.ipv4.tcp_wmem" = "4096 65536 16777216";
      };
    };

    # Pin Realtek RTL8125 2.5GbE (MAC d8:5e:d3:9c:11:15) to deterministic name "nic0" with Wake-on-LAN
    systemd.network.links."10-nic0" = {
      matchConfig.MACAddress = "d8:5e:d3:9c:11:15";
      linkConfig = {
        Name = "nic0";
        WakeOnLan = "magic";
      };
    };

    networking = {
      hostName = "homelab";
      hostId = "8425e349";
      useDHCP = false;

      interfaces.nic0 = {
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

      # Explicit per-interface firewall: no blanket trustedInterfaces on wt0.
      # DNS (53 TCP/UDP), SSH (22), Caddy (80/443), and Samba SMB3 (445 only; no NetBIOS 137/138/139)
      # are scoped explicitly to nic0 and wt0; NetBird opens UDP 51820 for direct WireGuard P2P.
      firewall = {
        enable = true;
        interfaces = {
          nic0 = {
            allowedTCPPorts = [
              22
              53
              80
              443
              445
            ];
            allowedUDPPorts = [
              53
            ];
          };
          wt0 = {
            allowedTCPPorts = [
              22
              53
              80
              443
              445
              cfg.ports.staticSite
            ];
            allowedUDPPorts = [
              53
            ];
          };
        };
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

    services.netbird = {
      # Pinned to unstable while stable nixpkgs lags behind the self-hosted 0.80.x NetBird stack
      package = if cfg.netbird.useUnstable then pkgs-unstable.netbird else pkgs.netbird;
      useRoutingFeatures = "both";
      clients.wt0 = {
        port = cfg.ports.netbird;
        interface = "wt0";
        openFirewall = true;
        autoStart = true;
      };
    };

    # Workaround: VPN peers and the external VPS reach local alias IPs (.101/.105/.109)
    # hosted on this same machine, so packets traverse INPUT instead of FORWARD.
    # Alerts via ntfy if NetBird ever renames its internal nftables chains.
    # Can be retired once the external VPS and NetBird peers target the NetBird peer IP directly.
    systemd.services.netbird-local-route-fix = lib.mkIf cfg.netbird.enableLocalRouteFix {
      description = "Bridge NetBird route ACLs (netbird-rt-fwd) into INPUT chain for local server alias IPs";
      after = [ "netbird-wt0.service" ];
      bindsTo = [ "netbird-wt0.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.nftables
      ];
      script = ''
        missing_count=0
        alerted_missing=0
        add_fail_count=0
        alerted_add_fail=0

        while true; do
          if nft list chain ip netbird netbird-acl-input-rules >/dev/null 2>&1; then
            missing_count=0
            alerted_missing=0
            if ! nft list chain ip netbird netbird-acl-input-rules | grep -q "jump netbird-rt-fwd"; then
              if nft add rule ip netbird netbird-acl-input-rules jump netbird-rt-fwd; then
                add_fail_count=0
                alerted_add_fail=0
              else
                add_fail_count=$((add_fail_count + 1))
                if [ "$add_fail_count" -ge 6 ] && [ "$alerted_add_fail" -eq 0 ]; then
                  printf '%s\n' "Failed to add jump netbird-rt-fwd rule to ip netbird netbird-acl-input-rules for 30s; VPN access to local alias IPs may be broken." \
                    | ${lib.getExe cfg.notifyScript} "NetBird nftables Rule Add Failed" "high" "warning" || true
                  alerted_add_fail=1
                fi
              fi
            else
              add_fail_count=0
              alerted_add_fail=0
            fi
          else
            missing_count=$((missing_count + 1))
            if [ "$missing_count" -ge 6 ] && [ "$alerted_missing" -eq 0 ]; then
              printf '%s\n' "Chain ip netbird netbird-acl-input-rules not found for 30s; VPN access to local alias IPs may be broken." \
                | ${lib.getExe cfg.notifyScript} "NetBird nftables Chain Missing" "high" "warning" || true
              alerted_missing=1
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
        group = "Server & Services";
        icon = "sh-technitium.svg";
        description = "DNS & Zones";
        siteMonitor = "http://127.0.0.1:${toString cfg.ports.technitiumUi}";
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
        group = "Network & Power";
        icon = "sh-mikrotik-light.svg";
        description = "RouterOS";
        siteMonitor = "http://${cfg.ips.gateway}:80";
        order = 10;
      };

      switch = {
        name = "Ubiquiti Switch";
        subdomain = "switch";
        group = "Network & Power";
        icon = "sh-ubiquiti-unifi-light.svg";
        description = "Core Switch";
        ping = "10.10.10.2";
        order = 20;
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
        group = "Network & Power";
        icon = "mdi-access-point-#38bdf8";
        description = "Wi-Fi Access Point";
        siteMonitor = "http://10.10.10.3";
        order = 30;
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
        group = "Network & Power";
        icon = "mdi-signal-5g-#34d399";
        description = "5G CPE Modem";
        siteMonitor = "http://10.10.20.1";
        order = 40;
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
