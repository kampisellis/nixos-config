{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.homelab;

  visibleServices = lib.attrValues (
    lib.filterAttrs (_: svc: svc.enable && svc.showInHomepage) cfg.services
  );

  baseGroups = [
    "Apps & Data"
    "Server & Services"
    "Network & Power"
  ];

  extraGroups = lib.unique (
    lib.filter (g: !(lib.elem g baseGroups)) (map (svc: svc.group) visibleServices)
  );

  orderedGroups = baseGroups ++ extraGroups;

  toHomepageEntry = svc: {
    ${svc.name} = {
      href = "https://${svc.subdomain}.${cfg.domain}${svc.path}";
      inherit (svc) description;
    }
    // lib.optionalAttrs (svc.icon != null) {
      inherit (svc) icon;
    }
    // lib.optionalAttrs (svc.siteMonitor != null) {
      inherit (svc) siteMonitor;
    }
    // lib.optionalAttrs (svc.ping != null) {
      inherit (svc) ping;
    };
  };

  mkGroupSection =
    groupName:
    let
      items = lib.sort (a: b: a.order < b.order) (
        lib.filter (svc: svc.group == groupName) visibleServices
      );
    in
    {
      ${groupName} = map toHomepageEntry items;
    };

  homepageSections = lib.filter (section: (lib.head (lib.attrValues section)) != [ ]) (
    map mkGroupSection orderedGroups
  );
in
{
  config = lib.mkIf cfg.enable {
    services.homepage-dashboard = {
      enable = true;
      listenPort = cfg.ports.homepage;
      allowedHosts = "home.${cfg.domain}";
      settings = {
        title = "Kampisellis Homelab";
        theme = "dark";
        color = "slate";
        headerStyle = "clean";
        statusStyle = "dot";
        useEqualHeights = true;
        layout = {
          "Apps & Data" = {
            style = "column";
          };
          "Server & Services" = {
            style = "column";
          };
          "Network & Power" = {
            style = "column";
          };
        };
      };
      widgets = [
        {
          resources = {
            label = "homelab";
            cpu = true;
            memory = true;
            cputemp = true;
            uptime = true;
            units = "metric";
            disk = [
              "/"
              "/mnt/nas-data"
            ];
            diskUnits = "bytes";
            expanded = true;
          };
        }
        {
          datetime = {
            text_size = "lg";
            locale = "en-GB";
            format = {
              dateStyle = "medium";
              timeStyle = "short";
              hour12 = false;
            };
          };
        }
      ];
      services = homepageSections;
    };

    homelab.services.home = {
      name = "Homepage";
      subdomain = "home";
      upstream = "http://127.0.0.1:${toString cfg.ports.homepage}";
      group = "Server & Services";
      description = "Homelab Dashboard";
      showInHomepage = false;
    };

    systemd.services.homepage-dashboard = {
      environment.HOSTNAME = "127.0.0.1";
      # Unprivileged ICMP ping via net.ipv4.ping_group_range (no CAP_NET_RAW needed)
      path = [ pkgs.iputils ];
      unitConfig.RequiresMountsFor = "/mnt/nas-data";
      serviceConfig.ReadOnlyPaths = [ "/mnt/nas-data" ];
    };
  };
}
