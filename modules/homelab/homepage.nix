{ config, lib, ... }:

let
  cfg = config.homelab;

  visibleServices = lib.attrValues (
    lib.filterAttrs (_: svc: svc.enable && svc.showInHomepage) cfg.services
  );

  baseGroups = [
    "Core & Media"
    "Infrastructure"
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
      };
      services = homepageSections;
    };

    homelab.services.home = {
      name = "Homepage";
      subdomain = "home";
      upstream = "http://127.0.0.1:${toString cfg.ports.homepage}";
      group = "Infrastructure";
      description = "Homelab Dashboard";
      showInHomepage = false;
    };

    systemd.services.homepage-dashboard.onFailure = [ "notify-ntfy@%n.service" ];
  };
}
