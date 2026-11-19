{ pkgs, formatterPkg }:

pkgs.mkShell {
  name = "nixos-config-dev";

  packages = [
    formatterPkg
  ]
  ++ (with pkgs; [
    age
    deadnix
    git
    just
    nvd
    openssl
    sops
    statix
  ]);

  shellHook = ''
    echo "Kampisellis NixOS devShell loaded."
    echo "Run 'just' to list safe validation, diff, test, and switch recipes."
  '';
}
