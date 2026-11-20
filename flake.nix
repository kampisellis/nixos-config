{
  description = "Kampisellis NixOS Infrastructure (Homelab Server & ASUS TUF Laptop)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-unstable,
      ...
    }@inputs:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # Format Nix code using the official RFC-166 formatter.
      formatterPkg = pkgs.nixfmt;

      mkHost =
        {
          modules,
          allowUnfree ? false,
        }:
        let
          pkgs-unstable = import nixpkgs-unstable {
            inherit system;
            config.allowUnfree = allowUnfree;
          };
        in
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = {
            inherit inputs pkgs-unstable;
          };
          modules = [
            { nixpkgs.config.allowUnfree = allowUnfree; }
            ./modules/common.nix
          ]
          ++ modules;
        };
    in
    {
      formatter.${system} = pkgs.nixfmt-tree;

      devShells.${system}.default = import ./modules/devshell.nix {
        inherit pkgs formatterPkg;
      };

      packages.${system}.services-table = import ./bin/generate-services-table.nix {
        inherit pkgs;
        homelabCfg = self.nixosConfigurations.homelab.config.homelab;
      };

      checks.${system} = {
        formatting = pkgs.runCommand "check-formatting" { nativeBuildInputs = [ formatterPkg ]; } ''
          find ${self} -name "*.nix" -exec nixfmt --check {} +
          touch $out
        '';

        statix = pkgs.runCommand "check-statix" { nativeBuildInputs = [ pkgs.statix ]; } ''
          statix check -c ${self}/statix.toml ${self}
          touch $out
        '';

        deadnix = pkgs.runCommand "check-deadnix" { nativeBuildInputs = [ pkgs.deadnix ]; } ''
          cd ${self} && deadnix --fail --exclude hosts/homelab/hardware-configuration.nix hosts/laptop/hardware-configuration.nix -- .
          touch $out
        '';
      };

      nixosConfigurations = {
        homelab = mkHost {
          allowUnfree = false;
          modules = [
            ./modules/homelab
            ./hosts/homelab
          ];
        };

        laptop = mkHost {
          allowUnfree = true;
          modules = [
            ./hosts/laptop
          ];
        };
      };
    };
}
