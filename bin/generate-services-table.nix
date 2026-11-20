{ pkgs, homelabCfg }:

let
  inherit (pkgs) lib;

  enabledServices = lib.attrValues (lib.filterAttrs (_: svc: svc.enable or true) homelabCfg.services);

  baseGroups = [
    "Core & Media"
    "Infrastructure"
  ];

  extraGroups = lib.sort (a: b: a < b) (
    lib.unique (lib.filter (g: !(lib.elem g baseGroups)) (map (svc: svc.group) enabledServices))
  );

  orderedGroups = baseGroups ++ extraGroups;

  sortedServices = lib.concatMap (
    groupName:
    lib.sort (a: b: if a.order != b.order then a.order < b.order else a.name < b.name) (
      lib.filter (svc: svc.group == groupName) enabledServices
    )
  ) orderedGroups;

  renderRow =
    svc:
    let
      url = "https://${svc.subdomain}.${homelabCfg.domain}${svc.path or ""}";
      target =
        if svc.upstream != null then
          svc.upstream
        else if svc.redirect != null then
          "Redirect -> ${svc.redirect}"
        else
          "Custom";
    in
    "| ${svc.name} | `${url}` | `${target}` | ${svc.group} | ${svc.description} |";

  rows = map renderRow sortedServices;

  markdown = ''
    # Homelab Services Registry

    Generated automatically from `nixosConfigurations.homelab.config.homelab.services`.

    | Service | URL | Upstream / Target | Group | Description |
    | --- | --- | --- | --- | --- |
    ${lib.concatStringsSep "\n" rows}
  '';
in
pkgs.writeText "services-table.md" markdown
