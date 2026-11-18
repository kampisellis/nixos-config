{
  description = "Kampisellis NixOS Infrastructure (Homelab Server & ASUS TUF Laptop)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, ... }:
  let
    system = "x86_64-linux";
    pkgs-unstable = import nixpkgs-unstable {
      inherit system;
      config.allowUnfree = true;
    };
  in {
    nixosConfigurations = {
      homelab = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit pkgs-unstable; };
        modules = [
          ./modules/common.nix
          ./hosts/homelab/default.nix
        ];
      };

      laptop = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit pkgs-unstable; };
        modules = [
          ./modules/common.nix
          ./hosts/laptop/default.nix
        ];
      };
    };
  };
}
