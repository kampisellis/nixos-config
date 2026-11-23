{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.homelab;

  enabledServices = lib.filterAttrs (_: svc: svc.enable) cfg.services;

  renderHandle =
    key: svc:
    let
      body =
        if svc.extraCaddyConfig != null then
          svc.extraCaddyConfig
        else if svc.redirect != null then
          "redir ${svc.redirect} permanent"
        else
          "reverse_proxy ${svc.upstream}";
    in
    ''
      @${key} host ${svc.subdomain}.${cfg.domain}
      handle @${key} {
        ${body}
      }
    '';

  generatedHandles = lib.concatStringsSep "\n\n" (lib.mapAttrsToList renderHandle enabledServices);

  invalidServices = lib.attrNames (
    lib.filterAttrs (
      _: svc: svc.upstream == null && svc.redirect == null && svc.extraCaddyConfig == null
    ) enabledServices
  );

  enabledSubdomains = lib.mapAttrsToList (_: svc: svc.subdomain) enabledServices;

  duplicateSubdomains = lib.unique (
    lib.filter (sub: lib.count (s: s == sub) enabledSubdomains > 1) enabledSubdomains
  );
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = invalidServices == [ ];
        message = "homelab.services entries must set at least one of upstream, redirect, or extraCaddyConfig: ${lib.concatStringsSep ", " invalidServices}";
      }
      {
        assertion = duplicateSubdomains == [ ];
        message = "homelab.services has duplicate subdomains among enabled services: ${lib.concatStringsSep ", " duplicateSubdomains}";
      }
    ];
    # Legacy CV subdomain redirect registered in the same single source of truth
    homelab.services.cv = {
      name = "CV Redirect";
      subdomain = "cv";
      redirect = "https://${cfg.domain}{uri}";
      description = "Permanent redirect to apex domain";
      showInHomepage = false;
    };

    services.caddy = {
      enable = true;

      # To update this hash after bumping nixpkgs or the Cloudflare plugin tag:
      # 1. Set hash = lib.fakeHash;
      # 2. Run `just build homelab` and copy the `got: sha256-...` value here.
      package = pkgs.caddy.withPlugins {
        plugins = [ "github.com/caddy-dns/cloudflare@v0.2.4" ];
        hash = "sha256-tubXIDCJnO2mvdnPlZclwDhNGaeeYLSt7lnni3+pXDo=";
      };

      environmentFile = "${cfg.secretsDir}/caddy.env";

      globalConfig = ''
        email ${cfg.email}
        admin 127.0.0.1:${toString cfg.ports.caddyAdmin}
        servers {
          protocols h1 h2
        }
      '';

      # Plain HTTP listener for the Hugo static site consumed by the external VPS over NetBird
      virtualHosts.":${toString cfg.ports.staticSite}" = {
        extraConfig = ''
          encode zstd gzip
          root * /var/lib/kampisellis-site/site
          file_server
        '';
      };

      virtualHosts."${cfg.domain}, www.${cfg.domain}" = {
        extraConfig = ''
          tls {
            dns cloudflare {env.CLOUDFLARE_API_TOKEN}
            resolvers 1.1.1.1 8.8.8.8
          }
          header {
            X-Content-Type-Options "nosniff"
            Referrer-Policy "strict-origin-when-cross-origin"
          }
          @www host www.${cfg.domain}
          redir @www https://${cfg.domain}{uri} permanent
          encode zstd gzip
          root * /var/lib/kampisellis-site/site
          file_server
        '';
      };

      virtualHosts."*.${cfg.domain}" = {
        extraConfig = ''
          tls {
            dns cloudflare {env.CLOUDFLARE_API_TOKEN}
            resolvers 1.1.1.1 8.8.8.8
          }

          # "?" only sets a header when the upstream did not already send it (avoids duplicates)
          header {
            X-Robots-Tag "noindex, nofollow, noarchive"
            ?X-Content-Type-Options "nosniff"
            ?Referrer-Policy "strict-origin-when-cross-origin"
          }

          @blocked {
            not client_ip private_ranges ${cfg.subnets.netbird}
          }
          handle @blocked {
            respond "Forbidden" 403
          }

          ${generatedHandles}

          handle {
            respond "Service not configured" 404
          }
        '';
      };
    };

    systemd = {
      tmpfiles.rules = [
        "d /var/lib/kampisellis-site 0755 caddy caddy -"
        "d /var/lib/kampisellis-site/site 0755 ${cfg.user} users -"
      ];

      services = {
        kampisellis-site-hugo = {
          description = "Watch and build kampisellis.com Hugo site from NAS";
          wantedBy = [ "multi-user.target" ];
          after = [ "local-fs.target" ];
          unitConfig = {
            RequiresMountsFor = "/mnt/nas-data";
            ConditionPathExists = "/mnt/nas-data/Giannis/Apps/Site/hugo.toml";
          };
          path = [ pkgs.dart-sass ];
          serviceConfig = {
            Type = "simple";
            User = cfg.user;
            Group = "users";
            UMask = "0022";
            CacheDirectory = "kampisellis-hugo";
            Restart = "on-failure";
            RestartSec = "5s";
            NoNewPrivileges = true;
            PrivateTmp = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectControlGroups = true;
            CapabilityBoundingSet = "";
            ReadWritePaths = [
              "/var/lib/kampisellis-site/site"
              "/mnt/nas-data/Giannis/Apps/Site/resources"
            ];
            ExecStart = lib.concatStringsSep " " [
              (lib.getExe pkgs.hugo)
              "--watch"
              "--noBuildLock"
              "--source /mnt/nas-data/Giannis/Apps/Site"
              "--destination /var/lib/kampisellis-site/site"
              "--cacheDir /var/cache/kampisellis-hugo"
              "--cleanDestinationDir"
              "--minify"
            ];
          };
        };
      };
    };
  };
}
