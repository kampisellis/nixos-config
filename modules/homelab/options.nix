{ lib, ... }:

let
  inherit (lib) mkEnableOption mkOption types;

  serviceSubmodule = types.submodule {
    options = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Whether this service entry is active in Caddy and Homepage.";
      };

      name = mkOption {
        type = types.str;
        description = "Human-readable service name shown in Homepage and generated tables.";
      };

      subdomain = mkOption {
        type = types.str;
        description = "Subdomain prefix under homelab.domain.";
      };

      path = mkOption {
        type = types.str;
        default = "";
        description = "Optional URL path suffix appended to the Homepage link.";
      };

      upstream = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Reverse-proxy target URL for Caddy (for example, http://127.0.0.1:2283).";
      };

      redirect = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Permanent redirect target for Caddy when upstream is null.";
      };

      extraCaddyConfig = mkOption {
        type = types.nullOr types.lines;
        default = null;
        description = "Custom Caddy directives placed inside the subdomain handle block.";
      };

      group = mkOption {
        type = types.str;
        default = "Infrastructure";
        description = "Homepage section group name.";
      };

      icon = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Homepage icon filename (for example, immich.png).";
      };

      description = mkOption {
        type = types.str;
        default = "";
        description = "Short service description shown in Homepage and generated docs.";
      };

      showInHomepage = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to display this service on the Homepage dashboard.";
      };

      order = mkOption {
        type = types.int;
        default = 50;
        description = "Sort order within the Homepage group (lower values appear first).";
      };
    };
  };
in
{
  options.homelab = {
    enable = mkEnableOption "Kampisellis self-hosted homelab stack";

    domain = mkOption {
      type = types.str;
      default = "kampisellis.com";
      description = "Primary domain for all homelab virtual hosts.";
    };

    email = mkOption {
      type = types.str;
      default = "gkampisellis@outlook.com";
      description = "ACME/TLS contact email used by Caddy.";
    };

    user = mkOption {
      type = types.str;
      default = "gkampisellis";
      description = "Primary administrative Linux user on the homelab server.";
    };

    secretsDir = mkOption {
      type = types.str;
      default = "/var/lib/secrets";
      description = "Directory containing out-of-repo secret files.";
    };

    ips = {
      primary = mkOption {
        type = types.str;
        default = "10.10.10.5";
        description = "Primary host IPv4 address on nic0 (SSH and host management).";
      };

      dns = mkOption {
        type = types.str;
        default = "10.10.10.101";
        description = "Secondary IPv4 alias for Technitium DNS.";
      };

      caddy = mkOption {
        type = types.str;
        default = "10.10.10.105";
        description = "Secondary IPv4 alias for Caddy reverse proxy.";
      };

      site = mkOption {
        type = types.str;
        default = "10.10.10.109";
        description = "Secondary IPv4 alias for the Hugo static site consumed by external VPS.";
      };

      gateway = mkOption {
        type = types.str;
        default = "10.10.10.1";
        description = "MikroTik LAN default gateway IPv4 address.";
      };
    };

    subnets = {
      lan = mkOption {
        type = types.str;
        default = "10.10.10.0/24";
        description = "Local LAN CIDR.";
      };

      netbird = mkOption {
        type = types.str;
        default = "100.64.0.0/10";
        description = "NetBird CGNAT VPN CIDR.";
      };
    };

    ports = {
      vaultwarden = mkOption {
        type = types.port;
        default = 8000;
        description = "Internal loopback port for Vaultwarden.";
      };

      immich = mkOption {
        type = types.port;
        default = 2283;
        description = "Internal loopback port for Immich.";
      };

      radicale = mkOption {
        type = types.port;
        default = 5232;
        description = "Internal loopback port for Radicale.";
      };

      couchdb = mkOption {
        type = types.port;
        default = 5984;
        description = "Internal loopback port for CouchDB.";
      };

      lidarr = mkOption {
        type = types.port;
        default = 8686;
        description = "Internal loopback port for Lidarr.";
      };

      ntfy = mkOption {
        type = types.port;
        default = 5055;
        description = "Internal loopback port for ntfy-sh.";
      };

      searxng = mkOption {
        type = types.port;
        default = 8888;
        description = "Internal loopback port for SearXNG.";
      };

      homepage = mkOption {
        type = types.port;
        default = 3000;
        description = "Internal port for Homepage dashboard.";
      };

      cockpit = mkOption {
        type = types.port;
        default = 9090;
        description = "Internal loopback port for Cockpit.";
      };

      technitiumUi = mkOption {
        type = types.port;
        default = 5380;
        description = "Technitium DNS web administration port.";
      };

      technitiumDoh = mkOption {
        type = types.port;
        default = 8053;
        description = "Technitium DNS-over-HTTPS loopback backend port.";
      };

      staticSite = mkOption {
        type = types.port;
        default = 8085;
        description = "HTTP port serving the Hugo static site for the external VPS.";
      };

      caddyAdmin = mkOption {
        type = types.port;
        default = 2019;
        description = "Caddy loopback admin API port.";
      };

      netbird = mkOption {
        type = types.port;
        default = 51820;
        description = "WireGuard UDP port for NetBird client wt0.";
      };
    };

    services = mkOption {
      type = types.attrsOf serviceSubmodule;
      default = { };
      description = "Single-source-of-truth service registry powering Caddy virtualHosts, Homepage, and docs.";
    };
  };
}
