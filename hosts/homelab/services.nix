{ config, pkgs, pkgs-unstable, ... }:

{
  # 1. VAULTWARDEN (/var/lib/bitwarden_rs)
  services.vaultwarden = {
    enable = true;
    dbBackend = "sqlite";
    backupDir = "/var/lib/backup/vaultwarden";
    config = {
      DOMAIN = "https://vault.kampisellis.com";
      ROCKET_ADDRESS = "127.0.0.1";
      ROCKET_PORT = 8000;
      SIGNUPS_ALLOWED = false;
    };
  };

  # 2. IMMICH (PostgreSQL 16 + VectorChord + Intel UHD 730 Acceleration)
  services.postgresql.package = pkgs.postgresql_16;

  services.immich = {
    enable = true;
    package = pkgs-unstable.immich;
    host = "127.0.0.1";
    port = 2283;
    mediaLocation = "/mnt/nas-data/Giannis/Apps/Immich";
    accelerationDevices = [ "/dev/dri/renderD128" ];
  };

  # 3. RADICALE (/var/lib/radicale/collections)
  services.radicale = {
    enable = true;
    settings = {
      server.hosts = [ "127.0.0.1:5232" ];
      auth = {
        type = "htpasswd";
        htpasswd_filename = "/var/lib/radicale/users";
        htpasswd_encryption = "bcrypt";
      };
      storage.filesystem_folder = "/var/lib/radicale/collections";
    };
  };

  # 4. OBSIDIAN LIVESYNC (CouchDB - Φορτώνει το υπάρχον local.ini σου)
  services.couchdb = {
    enable = true;
    bindAddress = "127.0.0.1";
    port = 5984;
    databaseDir = "/var/lib/couchdb";
    viewIndexDir = "/var/lib/couchdb";
    extraConfigFiles = [ "/var/lib/couchdb/local.ini" ];
  };

  # 5. LIDARR (/var/lib/lidarr)
  services.lidarr = {
    enable = true;
    dataDir = "/var/lib/lidarr";
  };

  # 6. UPTIME KUMA (/var/lib/private/uptime-kuma)
  services.uptime-kuma = {
    enable = true;
    settings = {
      HOST = "127.0.0.1";
      PORT = "3001";
    };
  };

  # 7. NTFY (/var/lib/private/ntfy-sh)
  services.ntfy-sh = {
    enable = true;
    settings = {
      base-url = "https://ntfy.kampisellis.com";
      listen-http = "127.0.0.1:5055";
      cache-file = "/var/lib/ntfy-sh/cache.db";
      behind-proxy = true;
    };
  };

  # 8. SEARXNG
  services.searx = {
    enable = true;
    package = pkgs.searxng;
    redisCreateLocally = true;
    settings = {
      server = {
        bind_address = "127.0.0.1";
        port = 8888;
        secret_key = "kampisellis-searxng-secret-key";
      };
    };
  };

  # 9. HOMEPAGE DASHBOARD
  services.homepage-dashboard = {
    enable = true;
    listenPort = 3000;
    allowedHosts = "home.kampisellis.com";
    settings = {
      title = "Kampisellis Homelab";
      theme = "dark";
      color = "slate";
    };
    services = [
      {
        "Core & Media" = [
          { "Immich" = { icon = "immich.png"; href = "https://photos.kampisellis.com"; description = "Photos & Videos"; }; }
          { "Vaultwarden" = { icon = "vaultwarden.png"; href = "https://vault.kampisellis.com"; description = "Passwords & 2FA"; }; }
          { "Obsidian LiveSync" = { icon = "obsidian.png"; href = "https://obsidian.kampisellis.com/_utils"; description = "CouchDB Notes"; }; }
          { "Radicale" = { icon = "radicale.png"; href = "https://webdav.kampisellis.com"; description = "CalDAV & CardDAV"; }; }
          { "Lidarr" = { icon = "lidarr.png"; href = "https://lidarr.kampisellis.com"; description = "Music Library"; }; }
        ];
      }
      {
        "Infrastructure" = [
          { "Cockpit" = { icon = "cockpit.png"; href = "https://cockpit.kampisellis.com"; description = "NixOS Server UI"; }; }
          { "Technitium DNS" = { icon = "technitium.png"; href = "https://dns.kampisellis.com"; description = "DNS & Zones"; }; }
          { "Uptime Kuma" = { icon = "uptime-kuma.png"; href = "https://monitor.kampisellis.com"; description = "Monitoring"; }; }
          { "ntfy" = { icon = "ntfy.png"; href = "https://ntfy.kampisellis.com"; description = "Notifications"; }; }
          { "SearXNG" = { icon = "searxng.png"; href = "https://search.kampisellis.com"; description = "Search Engine"; }; }
          { "MikroTik" = { icon = "mikrotik.png"; href = "https://mikrotik.kampisellis.com"; description = "RouterOS"; }; }
        ];
      }
    ];
  };

  # 10. CADDY REVERSE PROXY + HUGO STATIC SITE (:8085)
  services.caddy = {
    enable = true;
    package = pkgs.caddy.withPlugins {
      plugins = [ "github.com/caddy-dns/cloudflare@v0.2.4" ];
      hash = "sha256-Q0lgI8MY90u/5R/xXBVPQWCZBN7dUZ0kcuDxD0xd0fo= ";
    };
    environmentFile = "/var/lib/secrets/caddy.env";

    globalConfig = ''
      email gkampisellis@outlook.com
      admin 127.0.0.1:2019
      servers {
        protocols h1 h2
        trusted_proxies static private_ranges 100.64.0.0/10
      }
    '';

    virtualHosts.":8085" = {
      extraConfig = ''
        encode zstd gzip
        root * /var/lib/kampisellis-site/site
        file_server
      '';
    };

    virtualHosts."kampisellis.com, www.kampisellis.com" = {
      extraConfig = ''
        tls {
          dns cloudflare {env.CLOUDFLARE_API_TOKEN}
          resolvers 1.1.1.1 8.8.8.8
        }
        @www host www.kampisellis.com
        redir @www https://kampisellis.com{uri} permanent
        encode zstd gzip
        root * /var/lib/kampisellis-site/site
        file_server
      '';
    };

    virtualHosts."*.kampisellis.com" = {
      extraConfig = ''
        tls {
          dns cloudflare {env.CLOUDFLARE_API_TOKEN}
          resolvers 1.1.1.1 8.8.8.8
        }

        header X-Robots-Tag "noindex, nofollow, noarchive"

        @blocked {
          not client_ip private_ranges 100.64.0.0/10
        }
        handle @blocked {
          respond "Forbidden" 403
        }

        @cockpit host cockpit.kampisellis.com
        handle @cockpit {
          reverse_proxy http://127.0.0.1:9090
        }

        @mikrotik host mikrotik.kampisellis.com
        handle @mikrotik {
          reverse_proxy http://10.10.10.1:80
        }

        @dns host dns.kampisellis.com
        handle @dns {
          @doh path /dns-query*
          handle @doh {
            reverse_proxy http://127.0.0.1:8053 {
              header_up X-Real-IP {remote_host}
            }
          }
          reverse_proxy http://127.0.0.1:5380
        }

        @home host home.kampisellis.com
        handle @home {
          reverse_proxy http://127.0.0.1:3000
        }

        @search host search.kampisellis.com
        handle @search {
          reverse_proxy http://127.0.0.1:8888
        }

        @vault host vault.kampisellis.com
        handle @vault {
          reverse_proxy http://127.0.0.1:8000
        }

        @photos host photos.kampisellis.com
        handle @photos {
          reverse_proxy http://127.0.0.1:2283
        }

        @webdav host webdav.kampisellis.com
        handle @webdav {
          reverse_proxy http://127.0.0.1:5232
        }

        @obsidian host obsidian.kampisellis.com
        handle @obsidian {
          reverse_proxy http://127.0.0.1:5984
        }

        @lidarr host lidarr.kampisellis.com
        handle @lidarr {
          reverse_proxy http://127.0.0.1:8686
        }

        @monitor host monitor.kampisellis.com
        handle @monitor {
          reverse_proxy http://127.0.0.1:3001
        }

        @ntfy host ntfy.kampisellis.com
        handle @ntfy {
          reverse_proxy http://127.0.0.1:5055
        }

        @cv host cv.kampisellis.com
        handle @cv {
          redir https://kampisellis.com{uri} permanent
        }

        handle {
          respond "Service not configured" 404
        }
      '';
    };
  };
}
