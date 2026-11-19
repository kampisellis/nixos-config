{ pkgs, homelabCfg }:

let
  inherit (pkgs) lib;

  enabledServices = lib.filterAttrs (_: svc: svc.enable or true) homelabCfg.services;

  renderRow =
    _: svc:
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

  rows = lib.mapAttrsToList renderRow enabledServices;

  markdown = ''
    # Homelab Services Registry

    Generated automatically from `nixosConfigurations.homelab.config.homelab.services`.

    | Service | URL | Upstream / Target | Group | Description |
    | --- | --- | --- | --- | --- |
    ${lib.concatStringsSep "\n" rows}
  '';
in
pkgs.writeText "services-table.md" markdown
